import Foundation

public enum DictationPhase: String, Sendable { case ready, preparing, recording, transcribing, recovery }

/// Session identity is checked again at every asynchronous boundary and immediately before writing.
public struct SessionState {
    public private(set) var phase: DictationPhase = .ready
    public private(set) var id: UUID?
    public private(set) var transcript: String?
    public init() {}
    @discardableResult public mutating func begin() -> UUID? {
        guard phase == .ready, transcript == nil else { return nil }
        let id = UUID(); self.id = id; phase = .preparing
        return id
    }
    public func isCurrent(_ id: UUID) -> Bool { self.id == id }
    public mutating func recording(_ id: UUID) -> Bool {
        guard isCurrent(id), phase == .preparing else { return false }
        phase = .recording; return true
    }
    public mutating func stopped(_ id: UUID) -> Bool {
        guard isCurrent(id), phase == .recording else { return false }
        phase = .transcribing; return true
    }
    public mutating func recover(_ text: String, id: UUID) -> Bool {
        guard isCurrent(id), phase != .ready else { return false }
        transcript = text; phase = .recovery; return true
    }
    public mutating func finish(_ id: UUID) {
        guard isCurrent(id) else { return }
        cancel()
    }
    /// Lock/sleep cancels live work, but already-recovered words remain until
    /// an explicit resolution or app exit, as required by the retention contract.
    @discardableResult public mutating func interruptForSystemBoundary() -> Bool {
        guard phase == .preparing || phase == .recording || phase == .transcribing else { return false }
        cancel(); return true
    }
    public mutating func cancel() { id = nil; transcript = nil; phase = .ready }
}

public enum TranscriptFormatting {
    /// Deterministic cleanup only; never prompts another model or rewrites wording.
    public static func clean(_ text: String) -> String {
        let withoutControls = text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        let normalized = withoutControls.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains(where: { $0.isLetter || $0.isNumber }) ? normalized : ""
    }
}
