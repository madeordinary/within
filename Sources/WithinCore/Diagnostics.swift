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
    case shortcutInterrupted = "shortcut_interrupted"
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

/// Compare the active input with the capture's starting configuration without exporting identities.
public struct AudioConfigurationObservation: Encodable {
    public let engineRunning: Bool
    public let deviceUnchanged: Bool
    public let deviceAvailable: Bool
    public let inputFormatUnchanged: Bool
    public let tapFormatUnchanged: Bool
    public var requiresStop: Bool {
        !(engineRunning && deviceUnchanged && deviceAvailable && inputFormatUnchanged && tapFormatUnchanged)
    }
    public init(engineRunning: Bool, deviceUnchanged: Bool, deviceAvailable: Bool,
                inputFormatUnchanged: Bool, tapFormatUnchanged: Bool) {
        self.engineRunning = engineRunning; self.deviceUnchanged = deviceUnchanged
        self.deviceAvailable = deviceAvailable; self.inputFormatUnchanged = inputFormatUnchanged
        self.tapFormatUnchanged = tapFormatUnchanged
    }
}

/// One in-memory observation per session. No key history, text, audio, or identities.
public struct RecordingStopDiagnostic: Encodable {
    public let cause: RecordingStopCause
    public let phase: String
    public let hardwareChord: ShortcutChordState
    public let sessionChord: ShortcutChordState
    public let eventListeningAllowed: Bool
    public let audioConfiguration: AudioConfigurationObservation?
    public init(cause: RecordingStopCause, phase: DictationPhase, hardwareChord: ShortcutChordState,
                sessionChord: ShortcutChordState, eventListeningAllowed: Bool,
                audioConfiguration: AudioConfigurationObservation? = nil) {
        self.cause = cause; self.phase = phase.rawValue; self.hardwareChord = hardwareChord
        self.sessionChord = sessionChord; self.eventListeningAllowed = eventListeningAllowed
        self.audioConfiguration = audioConfiguration
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

public enum RecordingStartupTrigger: String, Encodable {
    case control, holdShortcut = "hold_shortcut", tapShortcut = "tap_shortcut"
}

public enum RecordingStartupStage: String, CaseIterable {
    case permissionsReady, targetCaptured, feedbackPresented, modelReady, speechReady, targetRechecked
    case audioEngineCreated, audioInputReady, audioDeviceSelected, audioTapInstalled, audioEnginePrepared, audioEngineStarted
    case recordingPublished, firstAudioObserved
}

/// Cumulative milliseconds from an accepted start action, not wall-clock times.
/// Shortcut recognition (including the hold guard) happens before this clock.
public struct RecordingStartupDiagnostic: Encodable {
    public let trigger: RecordingStartupTrigger
    public let practice: Bool
    public fileprivate(set) var milliseconds: [String: Int] = [:]
}

public struct RecordingStartupTracker {
    private var started: ContinuousClock.Instant?
    public private(set) var latest: RecordingStartupDiagnostic?
    public init() {}
    public mutating func begin(trigger: RecordingStartupTrigger, practice: Bool, at time: ContinuousClock.Instant = .now) {
        started = time
        latest = RecordingStartupDiagnostic(trigger: trigger, practice: practice)
    }
    public mutating func mark(_ stage: RecordingStartupStage, at time: ContinuousClock.Instant = .now) {
        guard let started, time >= started, latest?.milliseconds[stage.rawValue] == nil else { return }
        let elapsed = started.duration(to: time).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        guard milliseconds.isFinite, milliseconds < Double(Int.max) else { return }
        latest?.milliseconds[stage.rawValue] = Int(milliseconds.rounded())
        if stage == .firstAudioObserved { finish() }
    }
    public mutating func finish() { started = nil }
}

/// Closed schema: callers supply categories, never exception descriptions,
/// device names, paths, destination identities, audio, or transcript text.
public struct DiagnosticsReport: Encodable {
    public let schema = 4
    public let appVersion: String
    public let appBuild: String
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
    public let lastRecordingStartup: RecordingStartupDiagnostic?
    public let automaticUpdateChecks = false
    public let telemetry = false

    public init(appVersion: String, macOSVersion: String, architecture: String, microphonePermission: String,
                accessibilityPermission: Bool, shortcutRegistered: Bool, microphoneSelection: String,
                modelInstalled: Bool, modelRevision: String, lastModelCheck: String, lastErrorCode: String,
                lastRecordingStop: RecordingStopDiagnostic? = nil,
                appBuild: String = "development", lastRecordingStartup: RecordingStartupDiagnostic? = nil) {
        self.appVersion = appVersion; self.macOSVersion = macOSVersion; self.architecture = architecture
        self.appBuild = appBuild
        self.microphonePermission = microphonePermission; self.accessibilityPermission = accessibilityPermission
        self.shortcutRegistered = shortcutRegistered; self.microphoneSelection = microphoneSelection
        self.modelInstalled = modelInstalled; self.modelRevision = modelRevision
        self.lastModelCheck = lastModelCheck; self.lastErrorCode = lastErrorCode
        self.lastRecordingStop = lastRecordingStop
        self.lastRecordingStartup = lastRecordingStartup
    }
    public func preview() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "Diagnostics unavailable" }
        return text
    }
}
