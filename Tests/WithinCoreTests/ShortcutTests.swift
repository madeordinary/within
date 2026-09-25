import XCTest
@testable import WithinCore

final class ShortcutTests: XCTestCase {
    func testHoldReleaseAndRepeat() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(mode: .hold, isActive: false), .start)
        XCTAssertNil(gesture.down(mode: .hold, isActive: true))
        XCTAssertEqual(gesture.up(), .stop)
        XCTAssertNil(gesture.up())
    }
    func testToggleIgnoresRelease() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(mode: .toggle, isActive: false), .start)
        XCTAssertNil(gesture.up())
        XCTAssertEqual(gesture.down(mode: .toggle, isActive: true), .stop)
        XCTAssertNil(gesture.up())
    }
    func testChangingModeWhileHeldStillStopsHold() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(mode: .hold, isActive: false), .start)
        XCTAssertNil(gesture.down(mode: .toggle, isActive: true))
        XCTAssertEqual(gesture.up(), .stop)
    }
    func testPollingKeepsHeldRecordingActiveThroughRepeats() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(mode: .hold, isActive: false), .start)
        for _ in 0..<100 {
            XCTAssertNil(gesture.poll(chordHeld: true))
            XCTAssertNil(gesture.down(mode: .hold, isActive: true))
        }
        XCTAssertEqual(gesture.up(), .stop)
    }
    func testMissedKeyUpStopsAndRearmsNextHold() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(mode: .hold, isActive: false), .start)
        XCTAssertEqual(gesture.poll(chordHeld: false), .stop)
        XCTAssertNil(gesture.poll(chordHeld: false))
        XCTAssertNil(gesture.up())
        XCTAssertEqual(gesture.down(mode: .hold, isActive: false), .start)
        XCTAssertEqual(gesture.up(), .stop)
    }
    func testPollingAfterDeliveredReleaseDoesNotStopTwice() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(mode: .hold, isActive: false), .start)
        XCTAssertEqual(gesture.up(), .stop)
        XCTAssertNil(gesture.poll(chordHeld: false))
    }
    func testPolledReleasePreservesModeChosenAtPress() {
        var gesture = ShortcutGesture()
        XCTAssertEqual(gesture.down(mode: .hold, isActive: false), .start)
        XCTAssertNil(gesture.down(mode: .toggle, isActive: true))
        XCTAssertEqual(gesture.poll(chordHeld: false), .stop)
        XCTAssertEqual(gesture.down(mode: .toggle, isActive: false), .start)
        XCTAssertNil(gesture.poll(chordHeld: false))
        XCTAssertEqual(gesture.down(mode: .toggle, isActive: true), .stop)
    }
}
