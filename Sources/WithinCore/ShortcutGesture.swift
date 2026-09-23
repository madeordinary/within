public enum ActivationMode: String, CaseIterable, Sendable { case hold, toggle }
public enum ShortcutAction: Equatable { case start, stop }

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
}
