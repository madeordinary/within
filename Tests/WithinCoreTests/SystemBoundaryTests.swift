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
