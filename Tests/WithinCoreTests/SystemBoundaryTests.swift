import XCTest
@testable import WithinCore

final class SystemBoundaryTests: XCTestCase {
    func testLockPreservesUnresolvedRecovery() {
        var state = SessionState()
        let id = state.begin()!
        _ = state.recording(id); _ = state.stopped(id); _ = state.recover("Pending words", id: id)
        XCTAssertFalse(state.interruptForSystemBoundary())
        XCTAssertEqual(state.phase, .recovery)
        XCTAssertEqual(state.transcript, "Pending words")
        XCTAssertTrue(state.isCurrent(id))
        XCTAssertNil(state.begin())
    }
    func testLockKeepsBothVersionsOfPendingWords() {
        var state = SessionState()
        let id = state.begin()!
        let change = DictionaryChange(transcribed: "gira", written: "Jira", outputUTF8Range: 0..<4)
        _ = state.recording(id); _ = state.stopped(id)
        _ = state.recover(DictionaryResult(original: "gira words", text: "Jira words", changes: [change]), id: id)
        XCTAssertTrue(state.switchPendingWords())
        XCTAssertFalse(state.interruptForSystemBoundary())
        XCTAssertEqual(state.phase, .recovery)
        XCTAssertTrue(state.isCurrent(id))
        XCTAssertEqual(state.transcript, "gira words")
        XCTAssertEqual(state.alternateTranscript, "Jira words")
        XCTAssertTrue(state.showingOriginal)
        XCTAssertEqual(state.dictionaryChanges, [change])
        XCTAssertNil(state.begin())
        XCTAssertTrue(state.switchPendingWords())
        XCTAssertEqual(state.transcript, "Jira words")
        XCTAssertEqual(state.originalTranscription, "gira words")
    }
    func testLockInvalidatesActiveWorkAtEveryStage() {
        for stage in 0..<3 {
            var state = SessionState(); let id = state.begin()!
            if stage >= 1 { _ = state.recording(id) }
            if stage >= 2 { _ = state.stopped(id) }
            XCTAssertTrue(state.interruptForSystemBoundary())
            XCTAssertEqual(state.phase, .ready)
            XCTAssertFalse(state.isCurrent(id))
            XCTAssertFalse(state.recover("Late text", id: id))
        }
    }
}
