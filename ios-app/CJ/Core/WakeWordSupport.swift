import Foundation

enum WakeWordMatcher {
    /// Match complete words, including the common spellings of the letters CJ.
    /// Return the latest match so an old partial transcript cannot retrigger it.
    static func match(_ words: [String]) -> Range<Int>? {
        let words = words.map { $0.lowercased().filter { !$0.isPunctuation && !$0.isWhitespace } }
        for index in words.indices.reversed() {
            if words[index] == "cj" { return index..<(index + 1) }
            guard index + 1 < words.count else { continue }
            if ["c j", "c jay", "see jay"].contains("\(words[index]) \(words[index + 1])") {
                return index..<(index + 2)
            }
        }
        return nil
    }
}

/// Bounded, memory-only 16-bit mono PCM with absolute sample positions.
/// Before activation this is a rolling window; after activation it holds the
/// wake phrase and question while the Mac starts the live session.
struct WakeAudioBuffer {
    var maximumSamples: Int
    private(set) var startSample = 0
    private(set) var endSample = 0
    private(set) var data = Data()

    @discardableResult
    mutating func append(_ frame: Data) -> Int {
        precondition(frame.count.isMultiple(of: 2))
        data.append(frame)
        endSample += frame.count / 2
        let dropped = max(0, data.count / 2 - maximumSamples)
        if dropped > 0 { discard(before: startSample + dropped) }
        return dropped
    }

    mutating func discard(before sample: Int) {
        let boundary = min(endSample, max(startSample, sample))
        data = Data(data.dropFirst((boundary - startSample) * 2))
        startSample = boundary
    }

    mutating func drain() -> Data {
        let result = data
        data.removeAll(keepingCapacity: false)
        startSample = endSample
        return result
    }
}
