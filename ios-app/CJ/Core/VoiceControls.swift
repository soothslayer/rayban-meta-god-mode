import Foundation

enum VoiceCommand: String, CaseIterable, Hashable {
    case start
    case stop
    case cancel
    case mute
    case unmute
}

// Commands must be short standalone utterances. This keeps phrases such as
// “Where is the bus stop?” and “How do I mute this?” available as questions.
enum VoiceCommandPolicy {
    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func isStandbyStart(_ lastWord: String, at timestamp: TimeInterval, previousEnd: TimeInterval?) -> Bool {
        guard command(in: lastWord) == .start else { return false }
        guard let previousEnd else { return true }
        return timestamp - previousEnd >= 0.7
    }

    static func command(in text: String) -> VoiceCommand? {
        let tokens = words(text)
        guard tokens.count == 1 else { return nil }
        return VoiceCommand(rawValue: tokens[0])
    }
}

enum VoicePhase {
    case standby, listening, thinking, speaking

    func accepts(_ command: VoiceCommand, muted: Bool) -> Bool {
        if muted { return command == .unmute }
        if self == .standby { return command == .start }
        return command == .stop || command == .cancel || command == .mute
    }
}

// Original RayBridge tone envelopes and timing.
enum RayBridgeSounds {
    static let listeningCue = twoNoteCue(first: 660, second: 880)
    static let stoppedListeningCue = twoNoteCue(first: 880, second: 660)
    static let thinkingHeartbeat = makeWave(duration: 2.5) { _, time in
        func pulse(start: Double, duration: Double, frequency: Double) -> Double {
            let local = time - start
            guard local >= 0, local < duration else { return 0 }
            let envelope = sin(.pi * local / duration)
            return 0.22 * envelope * sin(2 * .pi * frequency * local)
        }
        return pulse(start: 0, duration: 0.075, frequency: 330) +
            pulse(start: 0.13, duration: 0.09, frequency: 260)
    }
    private static func twoNoteCue(first: Double, second: Double) -> Data {
        var phase = 0.0
        return makeWave(duration: 0.18) { frame, time in
            let progress = time / 0.18
            let frequency = progress < 0.5 ? first : second
            phase += 2.0 * .pi * frequency / 44_100.0
            let attack = min(1.0, Double(frame) / 180.0)
            let frameCount = Int(44_100.0 * 0.18)
            let release = min(1.0, Double(frameCount - frame) / 900.0)
            return 0.32 * min(attack, release) * sin(phase)
        }
    }
    private static func makeWave(duration: Double, sample: (Int, Double) -> Double) -> Data {
        let sampleRate: UInt32 = 44_100
        let frameCount = Int(Double(sampleRate) * duration)
        var samples = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let value = Int16(Double(Int16.max) * max(-1, min(1, sample(frame, time))))
            append(UInt16(bitPattern: value), to: &samples)
        }

        var wave = Data()
        wave.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count), to: &wave)
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wave)           // PCM format chunk length
        append(UInt16(1), to: &wave)            // Linear PCM
        append(UInt16(1), to: &wave)            // Mono
        append(sampleRate, to: &wave)
        append(sampleRate * 2, to: &wave)        // Bytes per second
        append(UInt16(2), to: &wave)             // Bytes per frame
        append(UInt16(16), to: &wave)            // Bits per sample
        wave.append(contentsOf: "data".utf8)
        append(UInt32(samples.count), to: &wave)
        wave.append(samples)
        return wave
    }
    private static func append(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
