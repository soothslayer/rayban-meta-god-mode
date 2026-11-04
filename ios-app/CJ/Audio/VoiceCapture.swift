import Foundation

/// Owns one microphone across local wake detection and the live conversation.
/// No network consumer exists while this capture is waiting for a wake word.
@MainActor
final class VoiceCapture {
    let audio = LiveAudio()
    private(set) var started = false
    var onFrame: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var totalSamples: Int { buffer.endSample }
    private var buffer = WakeAudioBuffer(maximumSamples: 16_000 * 4)
    private var awaitingMac = false
    private var reader: Task<Void, Never>?
    private var downstream: AsyncStream<Data>.Continuation?

    func start() async throws {
        guard !started else { return }
        audio.onFailure = { [weak self] message in self?.onFailure?(message) }
        do {
            let frames = try await audio.start()
            try Task.checkCancellation()
            started = true
            reader = Task { [weak self] in
                for await frame in frames {
                    guard !Task.isCancelled, let self else { return }
                    self.receive(frame)
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    private func receive(_ frame: Data) {
        if let downstream {
            // Keep the absolute sample clock advancing without retaining audio.
            buffer.append(frame)
            _ = buffer.drain()
            if case .dropped = downstream.yield(frame) {
                onFailure?("Live audio fell behind. Tap Talk to reconnect.")
            }
        } else {
            let dropped = buffer.append(frame)
            if awaitingMac && dropped > 0 {
                onFailure?("The Mac took too long to start listening. Try again when it is connected.")
                return
            }
        }
        onFrame?(frame)
    }

    func prepareForConversation(from sample: Int) {
        onFrame = nil
        buffer.discard(before: sample)
        buffer.maximumSamples = 16_000 * 30
        awaitingMac = true
    }

    func conversationFrames() -> AsyncStream<Data> {
        precondition(downstream == nil)
        // A bounded backlog allows the initial question to catch up after the
        // connection handshake without dropping its first words.
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let initial = buffer.drain()
        for offset in stride(from: 0, to: initial.count, by: 3200) {
            pair.continuation.yield(initial.subdata(in: offset..<min(initial.count, offset + 3200)))
        }
        downstream = pair.continuation
        awaitingMac = false
        return pair.stream
    }

    func prepareForWakeWord() {
        downstream?.finish()
        downstream = nil
        onFrame = nil
        _ = buffer.drain()
        buffer.maximumSamples = 16_000 * 4
        awaitingMac = false
        audio.interrupt()
    }

    func stop() {
        reader?.cancel(); reader = nil
        downstream?.finish(); downstream = nil
        onFrame = nil
        onFailure = nil
        _ = buffer.drain()
        awaitingMac = false
        started = false
        audio.stop()
    }
}
