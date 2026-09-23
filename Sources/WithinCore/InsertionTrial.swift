/// Non-content evidence supplied by a native target adapter immediately before a write.
public struct TargetEvidence {
    public var permissionGranted: Bool
    public var targetAlive: Bool
    public var sameApplication: Bool
    public var sameWindow: Bool
    public var sameElement: Bool
    public var focusChanged: Bool
    public var secure: Bool?
    public var canReplaceSelection: Bool

    public init(permissionGranted: Bool = true, targetAlive: Bool = true,
                sameApplication: Bool = true, sameWindow: Bool = true,
                sameElement: Bool = true, focusChanged: Bool = false,
                secure: Bool? = false, canReplaceSelection: Bool = true) {
        self.permissionGranted = permissionGranted
        self.targetAlive = targetAlive
        self.sameApplication = sameApplication
        self.sameWindow = sameWindow
        self.sameElement = sameElement
        self.focusChanged = focusChanged
        self.secure = secure
        self.canReplaceSelection = canReplaceSelection
    }

    public var blockReason: RecoveryReason? {
        if !permissionGranted { return .permissionRequired }
        if !targetAlive { return .targetUnavailable }
        if secure == true { return .secureField }
        if secure == nil { return .unknownSafety }
        if !sameApplication || !sameWindow || !sameElement || focusChanged { return .focusChanged }
        if !canReplaceSelection { return .unsupported }
        return nil
    }
}

public enum RecoveryReason: String, Equatable {
    case permissionRequired, targetUnavailable, secureField, unknownSafety
    case focusChanged, unsupported, uncertainWrite

    public var explanation: String {
        switch self {
        case .permissionRequired: return "Accessibility access is needed to insert into another app."
        case .targetUnavailable: return "The original text field is no longer available."
        case .secureField: return "Protected fields never receive dictation."
        case .unknownSafety: return "We couldn’t establish that this field is safe to use."
        case .focusChanged: return "Your focus changed. Your words stayed here."
        case .unsupported: return "This field doesn’t support direct insertion."
        case .uncertainWrite: return "The app didn’t confirm insertion. Check the field before copying to avoid duplicate text."
        }
    }

    public var permitsReturn: Bool { self == .focusChanged }
}

public enum TrialPhase: Equatable {
    case ready, preparing, inserting, inserted, recovery(RecoveryReason)
}

/// Deliberately contains no recording, network, persistence, or pasteboard code.
public struct InsertionTrial {
    public private(set) var phase: TrialPhase = .ready
    public private(set) var pendingText: String?
    public init() {}

    @discardableResult public mutating func begin(text: String) -> Bool {
        guard pendingText == nil, phase != .preparing, phase != .inserting else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pendingText = text
        phase = .preparing
        return true
    }

    /// Call only after native target evidence has been refreshed. A retry is a user action.
    @discardableResult public mutating func authorize(_ evidence: TargetEvidence, explicitReturn: Bool = false) -> Bool {
        guard pendingText != nil else { return false }
        if case .recovery(let reason) = phase {
            guard explicitReturn, reason.permitsReturn else { return false }
        } else if phase != .preparing { return false }
        if let reason = evidence.blockReason {
            phase = .recovery(reason)
            return false
        }
        phase = .inserting
        return true
    }

    public mutating func completeWrite(confirmed: Bool) {
        guard phase == .inserting else { return }
        if confirmed {
            pendingText = nil
            phase = .inserted
        } else {
            // An AX failure may follow a partial/accepted write. Never retry it automatically.
            phase = .recovery(.uncertainWrite)
        }
    }

    public mutating func recover(_ reason: RecoveryReason) {
        guard pendingText != nil, phase != .inserting else { return }
        phase = .recovery(reason)
    }

    public mutating func discard() {
        pendingText = nil
        phase = .ready
    }
}

import Foundation
