import AVFoundation
import Speech

/// Turn-based, subscription-only voice: Apple recognition -> Mac CLI -> Apple voice.
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
    private let capture: VoiceCapture
    private let client: BrainClient
    private let provider: String
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

    init(capture: VoiceCapture, pairing: Pairing, provider: String, language: String, history: [Turn]) {
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
        let frames = capture.conversationFrames()
        listen()
        reader = Task { [weak self] in
            for await pcm in frames {
                guard !Task.isCancelled, let self else { return }
                guard let request = self.request,
                      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
                      let destination = buffer.int16ChannelData?[0] else { continue }
                buffer.frameLength = buffer.frameCapacity
                pcm.withUnsafeBytes { if let base = $0.baseAddress { memcpy(destination, base, pcm.count) } }
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

    private func listen() {
        finishRecognition()
        guard !stopped, let recognizer else { return }
        latest = ""
        onHeard?(""); onSaid?("")
        onStatus?("Listening · \(provider == "codex" ? "Codex" : "Claude Code") · say “bye” to finish")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        let generation = generation
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.stopped, self.generation == generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.failures = 0
                        if text != self.latest {
                            self.latest = text
                            self.onHeard?(text)
                            self.silence?.cancel()
                            self.silence = Task { [weak self] in
                                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                                guard let self, self.generation == generation else { return }
                                self.submit()
                            }
                        }
                    }
                    if result.isFinal { self.submit(); return }
                }
                if error != nil {
                    self.failures += 1
                    if self.failures >= 3 { self.onFailure?("Speech recognition stopped. Tap Talk to reconnect.") }
                    else {
                        self.finishRecognition()
                        self.rotation = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(1)) } catch { return }
                            self?.listen()
                        }
                    }
                }
            }
        }
        rotation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.generation == generation else { return }
            if self.latest.isEmpty { self.listen() } else { self.submit() }
        }
    }

    private func submit() {
        guard !stopped, request != nil else { return }
        let question = latest.replacingOccurrences(of: "(?i)^(?:hey[ ,]+)?(?:c[ .]*j|see jay|c jay)\\b[ ,.!?:]*", with: "", options: .regularExpression)
        finishRecognition()
        guard !question.isEmpty else { listen(); return }
        let normalized = question.lowercased().filter { !$0.isPunctuation }.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["bye", "goodbye", "bye cj", "goodbye cj", "end conversation", "stop listening"].contains(normalized) {
            onEnd?(); return
        }
        onHeard?(question)
        onStatus?("\(provider == "codex" ? "Codex" : "Claude Code") is working on your Mac…")
        answer = Task { [weak self] in
            guard let self else { return }
            do {
                var image: Data?
                if question.range(of: "(?i)\\b(look|see|camera|photo|picture|read this|what is this|what's this)\\b", options: .regularExpression) != nil {
                    image = try? await self.photo?()
                }
                try Task.checkCancellation()
                let reply = try await self.client.ask(question, history: self.history, image: image, assistant: self.provider)
                try Task.checkCancellation()
                self.onSaid?(reply.spoken)
                self.onTurn?(question, reply.spoken)
                self.history += [Turn(role: "user", text: question), Turn(role: "assistant", text: reply.spoken)]
                self.history = Array(self.history.suffix(8))
                self.onStatus?("CJ is speaking")
                try await self.speak(reply.spoken)
                // Keep the assistant's acoustic tail out of the next question.
                try await Task.sleep(for: .milliseconds(350))
                self.listen()
            } catch {
                guard !Task.isCancelled, !self.stopped else { return }
                self.onFailure?(error.localizedDescription)
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
        finishRecognition()
        reader?.cancel(); reader = nil
        answer?.cancel(); answer = nil
        speech.stopSpeaking(at: .immediate)
        capture.audio.interrupt()
    }
}
