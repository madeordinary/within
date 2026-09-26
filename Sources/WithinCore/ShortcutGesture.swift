import Foundation

public enum ActivationMode: String, CaseIterable, Sendable { case hold, toggle }
public enum ShortcutAction: Equatable { case start, stop }

/// Only the deliberately chosen shortcut is stored, never a stream of keyboard events.
public struct DictationShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: UInt8
    public let keyLabel: String
    public static let command: UInt8 = 1
    public static let option: UInt8 = 2
    public static let control: UInt8 = 4
    public static let shift: UInt8 = 8
    public static let controlShiftSpace = DictationShortcut(keyCode: 49, modifiers: control | shift, keyLabel: "Space")
    public static let controlShiftD = DictationShortcut(keyCode: 2, modifiers: control | shift, keyLabel: "D")
    public static let rightControl = DictationShortcut(keyCode: 62, modifiers: 0, keyLabel: "Right Control")
    public init(keyCode: UInt16, modifiers: UInt8, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    public static func modifierName(for code: UInt16) -> String? {
        [54: "Right Command", 55: "Left Command", 56: "Left Shift", 60: "Right Shift",
         58: "Left Option", 61: "Right Option", 59: "Left Control", 62: "Right Control"][code]
    }
    public var isModifierOnly: Bool { modifiers == 0 && Self.modifierName(for: keyCode) != nil }
    public var isValid: Bool {
        guard keyCode <= 126, modifiers <= 15, !keyLabel.isEmpty, keyLabel.count <= 24,
              !keyLabel.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        // Shift, Left Command and Left Option are too entangled with ordinary typing.
        if isModifierOnly { return [59, 62, 61, 54].contains(keyCode) }
        // Ordinary typing, Escape, Caps Lock and Fn/Globe are not assignable here.
        guard Self.modifierName(for: keyCode) == nil && ![53, 57, 63].contains(keyCode),
              modifiers & (Self.command | Self.control) != 0 else { return false }
        if keyCode == 48 { return false } // App/tab switching.
        if modifiers & Self.command != 0 {
            // Preserve editing, application commands, Spotlight and system screenshots.
            if [0, 6, 7, 8, 9, 12, 13, 1, 3, 4, 31, 35, 45, 46, 49, 50].contains(keyCode) { return false }
            if modifiers & Self.shift != 0 && [20, 21, 23].contains(keyCode) { return false }
        }
        if keyCode == 49 && modifiers == Self.control { return false }
        return true
    }
    public var displayName: String {
        if isModifierOnly { return Self.modifierName(for: keyCode)! }
        return [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined(separator: " ") + " " + keyLabel
    }
    public var accessibilityName: String {
        if isModifierOnly { return displayName }
        return [(Self.control, "Control"), (Self.option, "Option"), (Self.shift, "Shift"), (Self.command, "Command")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined(separator: " ") + " " + keyLabel
    }
    public static func restored(from data: Data?, legacyAlternate: Bool) -> Self {
        if let data, let decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.isValid { return decoded }
        return legacyAlternate ? .controlShiftD : .controlShiftSpace
    }
}

public enum ModifierShortcutAction: Equatable { case press, release, tap, cancel }

/// A short arming interval keeps normal modifier+key combinations from starting dictation.
public struct ModifierShortcutGesture {
    private enum State { case idle, armed, active, blocked }
    private var state: State = .idle
    public init() {}
    public var isArmed: Bool { state == .armed }
    public mutating func down(isAlone: Bool) {
        guard state == .idle else { return }
        state = isAlone ? .armed : .blocked
    }
    public mutating func activateIfStillHeld() -> ModifierShortcutAction? {
        guard state == .armed else { return nil }
        state = .active
        return .press
    }
    public mutating func interrupt() -> ModifierShortcutAction? {
        let wasActive = state == .active
        if state != .idle { state = .blocked }
        return wasActive ? .cancel : nil
    }
    public mutating func up(observed: Bool = true) -> ModifierShortcutAction? {
        defer { state = .idle }
        if state == .active { return .release }
        return state == .armed && observed ? .tap : nil
    }
}

/// Repeated key-downs never start another recording. A mode change is effective
/// only after release, so changing preferences cannot strand a held session.
public struct ShortcutGesture {
    private var heldMode: ActivationMode?
    public init() {}
    public mutating func down(mode: ActivationMode, isActive: Bool) -> ShortcutAction? {
        guard heldMode == nil else { return nil }
        heldMode = mode
        if mode == .toggle { return isActive ? .stop : .start }
        return isActive ? nil : .start
    }
    public mutating func up() -> ShortcutAction? {
        defer { heldMode = nil }
        return heldMode == .hold ? .stop : nil
    }
    /// Recover a missed key-up through the same transition as a delivered one.
    /// Clear the held gesture as well as stopping capture so the next press works.
    public mutating func poll(chordHeld: Bool) -> ShortcutAction? {
        guard !chordHeld else { return nil }
        return up()
    }
}
