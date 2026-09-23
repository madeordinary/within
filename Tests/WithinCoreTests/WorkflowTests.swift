import XCTest
@testable import WithinCore

final class WorkflowTests: XCTestCase {
    func testCancellationInvalidatesEveryLateResult() {
        var state = SessionState()
        let first = state.begin()!
        XCTAssertTrue(state.recording(first))
        state.cancel()
        let second = state.begin()!
        XCTAssertFalse(state.stopped(first))
        XCTAssertFalse(state.recover("Late words", id: first))
        state.finish(first)
        XCTAssertTrue(state.isCurrent(second))
        XCTAssertEqual(state.phase, .preparing)
    }
    func testRecoveryCannotBeReplaced() {
        var state = SessionState()
        let id = state.begin()!
        _ = state.recording(id); _ = state.stopped(id)
        XCTAssertTrue(state.recover("Keep", id: id))
        XCTAssertNil(state.begin())
        XCTAssertEqual(state.transcript, "Keep")
        state.finish(id)
        XCTAssertNil(state.transcript)
    }
    func testFormattingIsDeterministicAndRejectsNonSpeech() {
        XCTAssertEqual(TranscriptFormatting.clean("<|nospeech|> . \n"), "")
        XCTAssertEqual(TranscriptFormatting.clean("  Hello\t  world.  "), "Hello world.")
        XCTAssertEqual(TranscriptFormatting.clean("Keep my words, exactly!"), "Keep my words, exactly!")
    }
    func testRingWrapPreservesOrderAndRejectsOverflow() {
        let ring = AudioRing(capacity: 4, sampleLimit: 20)
        [Float(1),2,3].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 3), 0) }
        XCTAssertEqual(ring.drain(upTo: 2), [1,2])
        [Float(4),5,6].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 3), 0) }
        XCTAssertEqual(ring.pending, 4)
        [Float(7)].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 1), 2) }
        XCTAssertEqual(ring.drain(upTo: 10), [3,4,5,6])
        XCTAssertEqual(ring.samplesCaptured, 6)
    }
    func testDurationLimitIsMeasuredInSamples() {
        let ring = AudioRing(capacity: 10, sampleLimit: 3)
        [Float(1),2,3,4,5].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 5), 3) }
        XCTAssertEqual(ring.samplesCaptured, 3)
        XCTAssertEqual(ring.drain(upTo: 10), [1,2,3])
        ring.close()
        XCTAssertEqual(ring.status, 3)
    }
    func testClosedRingRejectsNewAudio() {
        let ring = AudioRing(capacity: 8, sampleLimit: 20)
        ring.close()
        [Float(1)].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 1), 1) }
        XCTAssertEqual(ring.pending, 0)
    }
}
