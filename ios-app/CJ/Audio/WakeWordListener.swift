import AVFoundation
import Speech
import UIKit

@MainActor
final class WakeWordListener {
    var onWake: ((VoiceCapture) -> Void)?
    var onState: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private var capture: VoiceCapture?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var startup: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private var confirmation: Task<Void, Never>?
    private var generation = UUID()
    private var recognitionGeneration = UUID()
    private var pendingWakeSample: Int?
    private var failures = 0

    func start(using existing: VoiceCapture? = nil) {
        stop()
        let generation = UUID()
        self.generation = generation
        capture = existing
        failures = 0
        onState?("Enabling on-device wake listening…")
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                var authorization = SFSpeechRecognizer.authorizationStatus()
                if authorization == .notDetermined {
                    guard UIApplication.shared.applicationState == .active else {
                        throw CJError("Open CJ to enable Listen for CJ and grant speech recognition permission.")
                    }
                    authorization = await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                    }
                }
                try self.check(generation)
                guard authorization == .authorized else {
                    throw CJError("Allow Speech Recognition for CJ in Settings to use the wake word. Tap Talk still works without it.")
                }
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                      recognizer.supportsOnDeviceRecognition else {
                    throw CJError("On-device English recognition is unavailable on this iPhone. Use Talk to CJ for now; wake listening will not send audio to a speech server.")
                }
                guard recognizer.isAvailable else {
                    throw CJError("On-device speech recognition is temporarily unavailable. Try Listen for CJ again shortly.")
                }
                self.recognizer = recognizer
                let capture = existing ?? VoiceCapture()
                self.capture = capture
                capture.onFailure = { [weak self] message in self?.fail(message) }
                if !capture.started {
                    // Permission callbacks can precede the app becoming active.
                    for _ in 0..<20 {
                        if UIApplication.shared.applicationState != .inactive { break }
                        try await Task.sleep(for: .milliseconds(100))
                        try self.check(generation)
                    }
                    guard UIApplication.shared.applicationState == .active else {
                        throw CJError("Open CJ to resume wake listening after the microphone stops.")
                    }
                    try await capture.start()
                } else {
                    // Let the previous reply finish acoustically before rearming.
                    try await Task.sleep(for: .milliseconds(500))
                }
                try self.check(generation)
                capture.prepareForWakeWord()
                self.beginRecognition()
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func beginRecognition() {
        finishRecognition()
        guard let recognizer, let capture, capture.started else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["CJ", "Hey CJ", "C J"]
        self.request = request
        let recognitionGeneration = UUID()
        self.recognitionGeneration = recognitionGeneration
        let firstSample = capture.totalSamples
        capture.onFrame = { [weak self, weak request] pcm in
            guard let self, self.recognitionGeneration == recognitionGeneration,
                  let request,
                  let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
                  let destination = buffer.int16ChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
            pcm.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { memcpy(destination, base, pcm.count) }
            }
            request.append(buffer)
        }
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionGeneration == recognitionGeneration else { return }
                if let result {
                    if !result.bestTranscription.segments.isEmpty { self.failures = 0 }
                    self.inspect(result, firstSample: firstSample)
                    if result.isFinal, self.pendingWakeSample == nil { self.scheduleRestart(afterError: false) }
                }
                if error != nil, self.pendingWakeSample == nil { self.scheduleRestart(afterError: true) }
            }
        }
        onState?("Listening for “CJ” · \(capture.audio.route)")
        rotation = Task { [weak self] in
            // Speech tasks have bounded lifetimes. Renew recognition without
            // reopening the microphone or connecting to the Mac.
            do { try await Task.sleep(for: .seconds(50)) } catch { return }
            guard let self, self.recognitionGeneration == recognitionGeneration else { return }
            if self.pendingWakeSample == nil { self.beginRecognition() }
        }
    }

    private func inspect(_ result: SFSpeechRecognitionResult, firstSample: Int) {
        let segments = result.bestTranscription.segments
        guard let range = WakeWordMatcher.match(segments.map(\.substring)), let capture else {
            confirmation?.cancel(); confirmation = nil; pendingWakeSample = nil
            return
        }
        let start = firstSample + Int(segments[range.lowerBound].timestamp * 16_000)
        let last = segments[range.upperBound - 1]
        let end = firstSample + Int((last.timestamp + last.duration) * 16_000)
        guard capture.totalSamples - end < 16_000 * 4 else {
            confirmation?.cancel(); confirmation = nil; pendingWakeSample = nil
            return
        }
        guard pendingWakeSample != start else { return }
        confirmation?.cancel()
        pendingWakeSample = start
        let generation = generation
        confirmation = Task { [weak self] in
            // Allow partial corrections such as “see Jay” -> “see Jake”.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.generation == generation, self.pendingWakeSample == start,
                  let capture = self.takeCapture(from: start) else { return }
            self.onState?("Heard “CJ” · Connecting to your Mac…")
            if let onWake = self.onWake { onWake(capture) }
            else { capture.stop() }
        }
    }

    private func scheduleRestart(afterError: Bool) {
        guard restart == nil else { return }
        if afterError {
            failures += 1
            if failures >= 3 {
                fail("On-device wake recognition stopped. Turn Listen for CJ on again, or use Talk to CJ.")
                return
            }
        }
        finishRecognition()
        let generation = generation
        restart = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(afterError ? 1000 : 100)) } catch { return }
            guard let self, self.generation == generation else { return }
            self.restart = nil
            self.beginRecognition()
        }
    }

    /// Transfer ownership without deactivating the active Bluetooth microphone.
    /// A manual tap discards idle audio; a wake trigger keeps the phrase onward.
    func takeCapture(from sample: Int? = nil) -> VoiceCapture? {
        generation = UUID()
        startup?.cancel(); startup = nil
        restart?.cancel(); restart = nil
        finishRecognition()
        let capture = capture
        self.capture = nil
        recognizer = nil
        guard let capture, capture.started else { capture?.stop(); return nil }
        capture.prepareForConversation(from: sample ?? capture.totalSamples)
        return capture
    }

    private func finishRecognition() {
        recognitionGeneration = UUID()
        rotation?.cancel(); rotation = nil
        confirmation?.cancel(); confirmation = nil
        pendingWakeSample = nil
        capture?.onFrame = nil
        recognition?.cancel(); recognition = nil
        request?.endAudio(); request = nil
    }

    private func check(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    func stop() {
        generation = UUID()
        startup?.cancel(); startup = nil
        restart?.cancel(); restart = nil
        finishRecognition()
        capture?.stop(); capture = nil
        recognizer = nil
    }
}
