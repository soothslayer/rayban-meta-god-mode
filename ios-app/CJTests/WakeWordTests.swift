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

final class VoiceControlsTests: XCTestCase {
    func testOnlyWholeCommandsMatch() {
        for command in VoiceCommand.allCases {
            XCTAssertEqual(VoiceCommandPolicy.command(in: "  " + command.rawValue.uppercased() + "!"), command)
        }
        for question in ["Where’s the bus stop?", "Start a timer", "Stop 2", "Unmute me", "cancelled", ""] {
            XCTAssertNil(VoiceCommandPolicy.command(in: question))
        }
    }

    func testStandbyStartCanFollowAnEarlierUtterance() {
        XCTAssertTrue(VoiceCommandPolicy.isStandbyStart("Start.", at: 1.1, previousEnd: nil))
        XCTAssertTrue(VoiceCommandPolicy.isStandbyStart("start", at: 3, previousEnd: 2))
        XCTAssertFalse(VoiceCommandPolicy.isStandbyStart("start", at: 3, previousEnd: 2.8))
        XCTAssertFalse(VoiceCommandPolicy.isStandbyStart("restart", at: 3, previousEnd: nil))
    }

    func testAllowedCommandsWhileAskingThinkingSpeakingAndMuted() {
        for phase in [VoicePhase.listening, .thinking, .speaking] {
            XCTAssertEqual(VoiceCommand.allCases.filter { phase.accepts($0, muted: false) }, [.stop, .cancel, .mute])
            XCTAssertEqual(VoiceCommand.allCases.filter { phase.accepts($0, muted: true) }, [.unmute])
        }
        XCTAssertEqual(VoiceCommand.allCases.filter { VoicePhase.standby.accepts($0, muted: false) }, [.start])
    }

    func testCuesUseTheRayBridgePitchOrderAndHeartbeatTiming() {
        func crossings(_ wav: Data, start: Int, count: Int) -> Int {
            func sample(_ frame: Int) -> Int16 {
                let offset = 44 + 2 * frame
                return Int16(bitPattern: UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8)
            }
            return (start..<(start + count)).filter { sample($0) <= 0 && sample($0 + 1) > 0 }.count
        }
        for (cue, rising) in [(RayBridgeSounds.listeningCue, true), (RayBridgeSounds.stoppedListeningCue, false)] {
            XCTAssertEqual(String(decoding: cue.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(cue.count, 44 + 7938 * 2)
            XCTAssertEqual(crossings(cue, start: 500, count: 2205), rising ? 33 : 44)
            XCTAssertEqual(crossings(cue, start: 4500, count: 2205), rising ? 44 : 33)
        }
        let beat = RayBridgeSounds.thinkingHeartbeat
        XCTAssertEqual(beat.count, 44 + 110250 * 2)
        XCTAssertGreaterThan(crossings(beat, start: 0, count: 3200), 20)
        XCTAssertGreaterThan(crossings(beat, start: 5800, count: 3800), 20)
        XCTAssertTrue(beat.dropFirst(44 + 9800 * 2).allSatisfy { $0 == 0 })
    }
}
