import AVFoundation
import Speech

/// On-device recognition and playback for assistants served by the Mac bridge.
/// Reuses the live audio engine so Bluetooth and wake-word handoff stay connected.
@MainActor
final class SubscriptionConversation {
    var onHeard: ((String) -> Void)?
    var onSaid: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onTurn: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var photo: (() async throws -> Data)?
    var onPhone: ((PhoneAction) -> Void)?
    private let commandsEnabled: Bool
    private let heartbeatEnabled: Bool
    private let feedback: VoiceFeedback
    private var phase: VoicePhase = .listening
    private var muted = false
    private var control: Task<Void, Never>?
    private let gemini: GeminiVoiceTurns?
    private var questionAudio = Data()
    private var speechStart: TimeInterval = 0
    private var turnID = UUID()
    private var takesQuestions: Bool { phase == .listening && !muted }
    private let capture: VoiceCapture
    private let client: BrainClient
    private let conversationID: UUID
    private let provider: String
    private var assistantName: String {
        switch provider {
        case "codex": return "Codex"
        case "muse": return "Muse"
        case "gemini": return "Gemini"
        default: return "Claude Code"
        }
    }
    private let language: String
    private var history: [Turn]
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private let speech = AVSpeechSynthesizer()
    private var reader: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var answer: Task<Void, Never>?
    private var generation = UUID()
    private var latest = ""
    private var failures = 0
    private var stopped = false

    init(capture: VoiceCapture, pairing: Pairing, provider: String, language: String, history: [Turn], conversationID: UUID,
         commands: Bool, heartbeat: Bool, feedback: VoiceFeedback) {
        commandsEnabled = commands
        heartbeatEnabled = heartbeat
        self.feedback = feedback
        gemini = provider == "gemini" ? GeminiVoiceTurns(pairing: pairing, language: language) : nil
        self.conversationID = conversationID
        self.capture = capture
        self.client = BrainClient(pairing: pairing)
        self.provider = provider
        self.language = language.isEmpty ? Locale.current.identifier : language
        self.history = history
    }

    func start() async throws {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard authorization == .authorized else {
            throw CJError("Allow Speech Recognition for CJ in Settings to talk with your Mac assistant.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.supportsOnDeviceRecognition else {
            throw CJError("On-device recognition isn’t available for this speech language. Choose another language in Setup, or type your question.")
        }
        self.recognizer = recognizer
        try await capture.start()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        if let gemini {
            gemini.photo = photo
            gemini.onPhone = onPhone
            gemini.onSaid = onSaid
            gemini.onAudio = { [weak self] data in
                guard let self else { throw CancellationError() }
                self.beginSpeaking()
                // Backpressure keeps long answers and confirmations within the playback budget.
                while self.capture.audio.bufferedPlaybackSeconds > 2 {
                    try await Task.sleep(for: .milliseconds(40))
                }
                try Task.checkCancellation()
                try self.capture.audio.play(data)
            }
            try await gemini.connect(history: history)
            try Task.checkCancellation()
        }
        let frames = capture.conversationFrames()
        readyToListen()
        reader = Task { [weak self] in
            for await pcm in frames {
                guard !Task.isCancelled, let self else { return }
                guard let request = self.request,
                      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
                      let destination = buffer.int16ChannelData?[0] else { continue }
                buffer.frameLength = buffer.frameCapacity
                pcm.withUnsafeBytes { if let base = $0.baseAddress { memcpy(destination, base, pcm.count) } }
                if self.gemini != nil, self.takesQuestions { self.questionAudio.append(pcm) }
                request.append(buffer)
            }
        }
    }

    private func finishRecognition() {
        generation = UUID()
        silence?.cancel(); silence = nil
        rotation?.cancel(); rotation = nil
        recognition?.cancel(); recognition = nil
        request?.endAudio(); request = nil
    }

    private func readyToListen() {
        phase = .listening
        feedback.thinking(false)
        guard control == nil, !stopped else { return }
        if !muted { feedback.listening(true) }
        onHeard?(""); onSaid?("")
        updateStatus()
        armRecognition()
    }

    private func updateStatus() {
        if muted {
            onStatus?("Muted · say “Unmute” to ask another question")
            return
        }
        switch phase {
        case .listening: onStatus?("Listening · \(assistantName) · say “bye” to finish")
        case .thinking: onStatus?("\(assistantName) is answering…")
        case .speaking: onStatus?("CJ is speaking")
        case .standby: break
        }
    }

    private func armRecognition() {
        finishRecognition()
        questionAudio = Data()
        speechStart = 0
        latest = ""
        guard !stopped, control == nil, let recognizer, takesQuestions || commandsEnabled else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = takesQuestions ? .dictation : .confirmation
        if commandsEnabled { request.contextualStrings = VoiceCommand.allCases.map(\.rawValue) }
        self.request = request
        let generation = self.generation
        let started = ContinuousClock.now
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.stopped, self.generation == generation else { return }
                if let result {
                    self.speechStart = result.bestTranscription.segments.first?.timestamp ?? 0
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { self.failures = 0 }
                    if text != self.latest {
                        self.latest = text
                        if self.takesQuestions { self.onHeard?(text) }
                        self.silence?.cancel()
                        self.silence = Task { [weak self] in
                            guard let self else { return }
                            do { try await Task.sleep(for: .milliseconds(self.takesQuestions ? 1200 : 650)) } catch { return }
                            guard self.generation == generation else { return }
                            self.submit()
                        }
                    }
                    if result.isFinal { self.submit(); return }
                }
                if error != nil {
                    if started.duration(to: .now) < .seconds(2) { self.failures += 1 }
                    else { self.failures = 0 }
                    self.finishRecognition()
                    if self.failures >= 3 { self.onFailure?("Speech recognition stopped. Tap Talk to reconnect."); return }
                    self.rotation = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                        self?.armRecognition()
                    }
                }
            }
        }
        rotation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.generation == generation else { return }
            self.submit()
        }
    }

    private func submit() {
        guard !stopped, request != nil else { return }
        if commandsEnabled, let command = VoiceCommandPolicy.command(in: latest),
           phase.accepts(command, muted: muted) {
            handle(command)
            return
        }
        guard takesQuestions else { armRecognition(); return }
        let question = latest.replacingOccurrences(of: "(?i)^(?:hey[ ,]+)?(?:c[ .]*j|see jay|c jay)\\b[ ,.!?:]*", with: "", options: .regularExpression)
        guard !question.isEmpty else { armRecognition(); return }
        let normalized = question.lowercased().filter { !$0.isPunctuation }.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["bye", "goodbye", "bye cj", "goodbye cj", "end conversation", "stop listening"].contains(normalized) {
            onEnd?(); return
        }
        // Apple timestamps are relative to this request's PCM. Keep a short
        // lead-in so an idle microphone never adds a long silence to Gemini's turn.
        let startByte = min(questionAudio.count, max(0, Int((speechStart - 0.3) * 16_000)) * 2)
        let audio = Data(questionAudio.dropFirst(startByte))
        phase = .thinking
        updateStatus()
        armRecognition()
        onHeard?(question)
        feedback.listening(false)
        let id = UUID()
        turnID = id
        answer = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                if self.control == nil { self.feedback.thinking(self.heartbeatEnabled) }
                let response: String
                var ending = false
                if let gemini = self.gemini {
                    (response, ending) = try await gemini.reply(to: audio, history: self.history)
                } else {
                    var image: Data?
                    if self.provider != "muse", question.range(of: "(?i)\\b(look|see|camera|photo|picture|read this|what is this|what's this)\\b", options: .regularExpression) != nil {
                        image = try? await self.photo?()
                    }
                    try Task.checkCancellation()
                    let reply = try await self.client.ask(question, history: self.history, image: image, assistant: self.provider, conversationID: self.conversationID)
                    response = reply.spoken
                }
                try Task.checkCancellation()
                guard self.turnID == id else { return }
                self.beginSpeaking()
                self.onSaid?(response)
                self.onTurn?(question, response)
                self.history += [Turn(role: "user", text: question), Turn(role: "assistant", text: response)]
                self.history = Array(self.history.suffix(8))
                if self.gemini == nil { try await self.speak(response) }
                while self.capture.audio.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
                try await Task.sleep(for: .milliseconds(350))
                if ending { self.onEnd?() } else { self.readyToListen() }
            } catch {
                guard !Task.isCancelled, !self.stopped, self.turnID == id else { return }
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    private func beginSpeaking() {
        if phase == .speaking { return }
        phase = .speaking
        feedback.thinking(false)
        if control == nil { updateStatus() }
    }

    private func handle(_ command: VoiceCommand) {
        guard control == nil else { return }
        finishRecognition()
        let message: String
        switch command {
        case .start: return // Handled by the foreground standby listener.
        case .stop, .cancel:
            turnID = UUID()
            answer?.cancel(); answer = nil
            speech.stopSpeaking(at: .immediate)
            capture.audio.interrupt()
            gemini?.close()
            phase = .listening
            message = command == .stop ? "Stopping" : "Cancelling"
        case .mute, .unmute:
            muted = command == .mute
            capture.audio.pauseAnswer(true)
            message = muted ? "Muted" : "Unmuted"
        }
        onStatus?(message)
        control = Task { [weak self] in
            guard let self else { return }
            await self.feedback.confirm(message + ".")
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled, !self.stopped else { return }
            self.control = nil
            if command == .stop { self.onEnd?(); return }
            self.capture.audio.pauseAnswer(false)
            if self.phase == .listening { self.readyToListen() }
            else {
                self.updateStatus()
                self.feedback.thinking(self.phase == .thinking && self.heartbeatEnabled)
                self.armRecognition()
            }
        }
    }

    private func speak(_ text: String) async throws {
        let pair = AsyncStream<Data>.makeStream()
        let utterance = AVSpeechUtterance(string: String(text.prefix(6000)))
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        speech.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { pair.continuation.finish(); return }
            if let bytes = Self.playbackPCM(pcm) { pair.continuation.yield(bytes) }
        }
        defer { pair.continuation.finish(); speech.stopSpeaking(at: .immediate) }
        for await bytes in pair.stream {
            try Task.checkCancellation()
            while capture.audio.bufferedPlaybackSeconds > 2 {
                try await Task.sleep(for: .milliseconds(50))
            }
            try capture.audio.play(bytes)
        }
        while capture.audio.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
    }

    nonisolated private static func playbackPCM(_ input: AVAudioPCMBuffer) -> Data? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate)) + 32) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil, let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    func stop() {
        stopped = true
        turnID = UUID()
        control?.cancel(); control = nil
        feedback.stop()
        gemini?.close()
        finishRecognition()
        reader?.cancel(); reader = nil
        answer?.cancel(); answer = nil
        speech.stopSpeaking(at: .immediate)
        capture.audio.interrupt()
    }
}
