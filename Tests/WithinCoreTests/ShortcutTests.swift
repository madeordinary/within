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
}
