import XCTest
@testable import WithinCore

final class ShortcutTests: XCTestCase {
    func testShortcutRestorationMigratesBothLegacyPresetsAndRejectsInvalidData() throws {
        XCTAssertEqual(DictationShortcut.restored(from: nil, legacyAlternate: true), .controlShiftD)
        XCTAssertEqual(DictationShortcut.restored(from: Data("broken".utf8), legacyAlternate: false), .controlShiftSpace)
        let data = try JSONEncoder().encode(DictationShortcut.rightControl)
        XCTAssertEqual(DictationShortcut.restored(from: data, legacyAlternate: false), .rightControl)
        let invalid = DictationShortcut(keyCode: 2, modifiers: 0, keyLabel: "D")
        XCTAssertEqual(DictationShortcut.restored(from: try JSONEncoder().encode(invalid), legacyAlternate: true), .controlShiftD)
    }
    func testShortcutValidationKeepsTypingAndEscapeAvailable() {
        XCTAssertFalse(DictationShortcut(keyCode: 0, modifiers: 0, keyLabel: "A").isValid)
        XCTAssertFalse(DictationShortcut(keyCode: 0, modifiers: DictationShortcut.shift, keyLabel: "A").isValid)
        XCTAssertFalse(DictationShortcut(keyCode: 53, modifiers: DictationShortcut.control, keyLabel: "Escape").isValid)
        XCTAssertFalse(DictationShortcut(keyCode: 63, modifiers: 0, keyLabel: "Fn").isValid)
        XCTAssertTrue(DictationShortcut(keyCode: 40, modifiers: DictationShortcut.command | DictationShortcut.option, keyLabel: "K").isValid)
        XCTAssertTrue(DictationShortcut.rightControl.isValid)
        let left = DictationShortcut(keyCode: 59, modifiers: 0, keyLabel: "Left Control")
        XCTAssertTrue(left.isValid)
        XCTAssertNotEqual(left, .rightControl)
        XCTAssertEqual(left.displayName, "Left Control")
        XCTAssertEqual(DictationShortcut.rightControl.displayName, "Right Control")
        XCTAssertFalse(DictationShortcut(keyCode: 56, modifiers: 0, keyLabel: "Left Shift").isValid)
        XCTAssertFalse(DictationShortcut(keyCode: 55, modifiers: 0, keyLabel: "Left Command").isValid)
    }
    func testShortcutValidationPreservesEditingSystemAndOptionTyping() {
        for code: UInt16 in [0, 6, 7, 8, 9, 12, 13, 48, 49] {
            XCTAssertFalse(DictationShortcut(keyCode: code, modifiers: DictationShortcut.command, keyLabel: "Key").isValid)
        }
        XCTAssertFalse(DictationShortcut(keyCode: 37, modifiers: DictationShortcut.option, keyLabel: "L").isValid)
        XCTAssertFalse(DictationShortcut(keyCode: 20, modifiers: DictationShortcut.command | DictationShortcut.shift, keyLabel: "3").isValid)
        XCTAssertFalse(DictationShortcut(keyCode: 48, modifiers: DictationShortcut.control, keyLabel: "Tab").isValid)
        XCTAssertTrue(DictationShortcut.controlShiftSpace.isValid)
        XCTAssertTrue(DictationShortcut.controlShiftD.isValid)
        XCTAssertEqual(DictationShortcut.controlShiftD.accessibilityName, "Control Shift D")
        XCTAssertEqual(DictationShortcut.restored(from: nil, legacyAlternate: false), .controlShiftSpace)
    }
    func testModifierHoldAndMissedReleaseRearm() {
        var gesture = ModifierShortcutGesture()
        gesture.down(isAlone: true)
        XCTAssertEqual(gesture.activateIfStillHeld(), .press)
        XCTAssertNil(gesture.activateIfStillHeld())
        XCTAssertEqual(gesture.up(observed: false), .release)
        XCTAssertNil(gesture.up())
        gesture.down(isAlone: true)
        XCTAssertEqual(gesture.activateIfStillHeld(), .press)
        XCTAssertEqual(gesture.up(), .release)
    }
    func testShortModifierTapNeedsAnObservedRelease() {
        var gesture = ModifierShortcutGesture()
        gesture.down(isAlone: true)
        XCTAssertEqual(gesture.up(), .tap)
        gesture.down(isAlone: true)
        XCTAssertNil(gesture.up(observed: false))
    }
    func testOrdinaryModifierKeyCombinationDoesNotActivate() {
        var gesture = ModifierShortcutGesture()
        gesture.down(isAlone: true)
        XCTAssertNil(gesture.interrupt())
        XCTAssertNil(gesture.activateIfStillHeld())
        XCTAssertNil(gesture.up())
        gesture.down(isAlone: false)
        XCTAssertNil(gesture.activateIfStillHeld())
        XCTAssertNil(gesture.up())
    }
    func testAddingAKeyDuringModifierHoldCancelsOnce() {
        var gesture = ModifierShortcutGesture()
        gesture.down(isAlone: true)
        XCTAssertEqual(gesture.activateIfStillHeld(), .press)
        XCTAssertEqual(gesture.interrupt(), .cancel)
        XCTAssertNil(gesture.interrupt())
        XCTAssertNil(gesture.up())
    }
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
