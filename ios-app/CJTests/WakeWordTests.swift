import XCTest
#if canImport(CJ)
@testable import CJ
#else
@testable import CJCore
#endif

final class WakeWordTests: XCTestCase {
    func testRecognizesWakeWordAndKeepsFollowingQuestion() {
        XCTAssertEqual(WakeWordMatcher.match(["Hey", "CJ", "what", "time"]), 1..<2)
        XCTAssertEqual(WakeWordMatcher.match(["C.J."]), 0..<1)
        XCTAssertEqual(WakeWordMatcher.match(["see", "jay", "take", "a", "photo"]), 0..<2)
        XCTAssertEqual(WakeWordMatcher.match(["c", "j"]), 0..<2)
        XCTAssertEqual(WakeWordMatcher.match(["CJ", "pause", "hey", "C", "Jay"]), 3..<5)
    }

    func testRejectsSimilarWordsAndPartialCorrections() {
        for words in [["city"], ["see", "Jake"], ["see", "you"], ["jay"], ["CJ7"], ["abcj"], ["c", "e", "o"], [String]()] {
            XCTAssertNil(WakeWordMatcher.match(words), words.joined(separator: " "))
        }
        XCTAssertNotNil(WakeWordMatcher.match(["see", "jay"]))
        XCTAssertNil(WakeWordMatcher.match(["see", "Jake"]))
    }

    func testRollingBufferDropsOldAudioAndPreservesAbsolutePositions() {
        var buffer = WakeAudioBuffer(maximumSamples: 4)
        buffer.append(Data([0, 0, 1, 0, 2, 0]))
        XCTAssertEqual(buffer.append(Data([3, 0, 4, 0, 5, 0])), 2)
        XCTAssertEqual(buffer.startSample, 2)
        XCTAssertEqual(buffer.endSample, 6)
        XCTAssertEqual(buffer.data, Data([2, 0, 3, 0, 4, 0, 5, 0]))
    }

    func testHandoffKeepsWakePhraseAndImmediateQuestionWithoutEarlierSpeech() {
        var buffer = WakeAudioBuffer(maximumSamples: 10)
        buffer.append(Data([0, 0, 1, 0, 2, 0, 3, 0, 4, 0]))
        buffer.discard(before: 3)
        buffer.maximumSamples = 20
        buffer.append(Data([5, 0, 6, 0]))
        XCTAssertEqual(buffer.drain(), Data([3, 0, 4, 0, 5, 0, 6, 0]))
        XCTAssertTrue(buffer.data.isEmpty)
        XCTAssertEqual(buffer.startSample, 7)
        XCTAssertEqual(buffer.endSample, 7)
        buffer.append(Data([7, 0]))
        XCTAssertEqual(buffer.drain(), Data([7, 0]))
    }

    func testDiscardClampsToAvailableAudioAndReportsOverflow() {
        var buffer = WakeAudioBuffer(maximumSamples: 2)
        XCTAssertEqual(buffer.append(Data(repeating: 1, count: 12)), 4)
        buffer.discard(before: -100)
        XCTAssertEqual(buffer.data.count, 4)
        buffer.discard(before: 100)
        XCTAssertEqual(buffer.startSample, 6)
        XCTAssertTrue(buffer.data.isEmpty)
    }
}
