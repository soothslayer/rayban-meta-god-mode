import AVFoundation

/// Uses the active conversation audio session so cues follow the glasses route.
@MainActor
final class VoiceFeedback: NSObject, AVSpeechSynthesizerDelegate {
    private var chime: AVAudioPlayer?
    private var heartbeat: AVAudioPlayer?
    private let voice = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var completion: CheckedContinuation<Void, Never>?
    private var deadline: Task<Void, Never>?

    override init() {
        super.init()
        voice.usesApplicationAudioSession = true
        voice.delegate = self
    }

    func listening(_ ready: Bool) {
        chime?.stop()
        chime = try? AVAudioPlayer(data: ready ? RayBridgeSounds.listeningCue : RayBridgeSounds.stoppedListeningCue)
        chime?.volume = 0.8
        chime?.play()
    }

    func thinking(_ enabled: Bool) {
        if !enabled { heartbeat?.stop(); heartbeat = nil; return }
        guard heartbeat == nil else { return }
        let player = try? AVAudioPlayer(data: RayBridgeSounds.thinkingHeartbeat)
        player?.volume = 0.35
        player?.numberOfLoops = -1
        player?.play()
        heartbeat = player
    }

    func confirm(_ text: String) async {
        guard !Task.isCancelled else { return }
        stop()
        let line = AVSpeechUtterance(string: text)
        line.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance = line
        await withCheckedContinuation { continuation in
            completion = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                self?.stop()
            }
            voice.speak(line)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish line: AVSpeechUtterance) {
        Task { @MainActor in if utterance === line { finish() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel line: AVSpeechUtterance) {
        Task { @MainActor in if utterance === line { finish() } }
    }

    private func finish() {
        deadline?.cancel(); deadline = nil
        utterance = nil
        completion?.resume(); completion = nil
    }

    func stop() {
        chime?.stop(); chime = nil
        thinking(false)
        finish()
        voice.stopSpeaking(at: .immediate)
    }
}
