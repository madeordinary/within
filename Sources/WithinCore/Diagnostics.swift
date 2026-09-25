import Foundation

public struct ShortcutChordState: Encodable, Equatable {
    public let controlHeld: Bool
    public let shiftHeld: Bool
    public let triggerHeld: Bool
    public var isHeld: Bool { controlHeld && shiftHeld && triggerHeld }
    public init(controlHeld: Bool, shiftHeld: Bool, triggerHeld: Bool) {
        self.controlHeld = controlHeld; self.shiftHeld = shiftHeld; self.triggerHeld = triggerHeld
    }
}

public enum RecordingStopCause: String, Encodable {
    case hotKeyRelease = "hot_key_release"
    case holdWatchdog = "hold_watchdog"
    case togglePress = "toggle_press"
    case stopButton = "stop_button"
    case cancelButton = "cancel_button"
    case escape, shutdown
    case inputChanged = "input_changed"
    case noAudio = "no_audio"
    case audioStalled = "audio_stalled"
    case secureInput = "secure_input"
    case microphonePermission = "microphone_permission"
    case durationLimit = "duration_limit"
    case bufferOverflow = "buffer_overflow"
    case streamEnded = "stream_ended"
    case pipelineError = "pipeline_error"
    case systemBoundary = "system_boundary"
}

/// One in-memory observation per session. No key history, text, audio, or identities.
public struct RecordingStopDiagnostic: Encodable {
    public let cause: RecordingStopCause
    public let phase: String
    public let hardwareChord: ShortcutChordState
    public let sessionChord: ShortcutChordState
    public let eventListeningAllowed: Bool
    public init(cause: RecordingStopCause, phase: DictationPhase, hardwareChord: ShortcutChordState,
                sessionChord: ShortcutChordState, eventListeningAllowed: Bool) {
        self.cause = cause; self.phase = phase.rawValue; self.hardwareChord = hardwareChord
        self.sessionChord = sessionChord; self.eventListeningAllowed = eventListeningAllowed
    }
}

public struct RecordingStopTracker {
    public private(set) var lastStop: RecordingStopDiagnostic?
    public init() {}
    public mutating func begin() { lastStop = nil }
    public mutating func record(_ observation: RecordingStopDiagnostic) {
        // Cleanup and delayed events must not replace the trigger that stopped capture.
        if lastStop == nil { lastStop = observation }
    }
}

/// Closed schema: callers supply categories, never exception descriptions,
/// device names, paths, destination identities, audio, or transcript text.
public struct DiagnosticsReport: Encodable {
    public let schema = 2
    public let appVersion: String
    public let macOSVersion: String
    public let architecture: String
    public let microphonePermission: String
    public let accessibilityPermission: Bool
    public let shortcutRegistered: Bool
    public let microphoneSelection: String
    public let modelInstalled: Bool
    public let modelRevision: String
    public let modelVerificationPolicy = "Full pinned SHA-256 before every session"
    public let lastModelCheck: String
    public let lastErrorCode: String
    public let lastRecordingStop: RecordingStopDiagnostic?
    public let automaticUpdateChecks = false
    public let telemetry = false

    public init(appVersion: String, macOSVersion: String, architecture: String, microphonePermission: String,
                accessibilityPermission: Bool, shortcutRegistered: Bool, microphoneSelection: String,
                modelInstalled: Bool, modelRevision: String, lastModelCheck: String, lastErrorCode: String,
                lastRecordingStop: RecordingStopDiagnostic? = nil) {
        self.appVersion = appVersion; self.macOSVersion = macOSVersion; self.architecture = architecture
        self.microphonePermission = microphonePermission; self.accessibilityPermission = accessibilityPermission
        self.shortcutRegistered = shortcutRegistered; self.microphoneSelection = microphoneSelection
        self.modelInstalled = modelInstalled; self.modelRevision = modelRevision
        self.lastModelCheck = lastModelCheck; self.lastErrorCode = lastErrorCode
        self.lastRecordingStop = lastRecordingStop
    }
    public func preview() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "Diagnostics unavailable" }
        return text
    }
}
