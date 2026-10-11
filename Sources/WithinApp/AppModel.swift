import AppKit
import AVFoundation
import Combine
import Carbon
import ServiceManagement
import WithinCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var session = SessionState()
    @Published private(set) var modelInstalled = false
    @Published private(set) var modelVerified = false
    @Published private(set) var modelBusy = false
    @Published private(set) var modelDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var modelMessage = "Checking local model…"
    @Published private(set) var message = "Your words, staying with you."
    @Published private(set) var audioFlowing = false
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var workerBusy = false
    @Published private(set) var microphoneAllowed = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var shortcutAvailable = false
    @Published private(set) var devices: [MicrophoneDevice] = []
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginMessage = ""
    @Published var settingsSection = "General"
    @Published private(set) var setupComplete: Bool
    @Published var soundsEnabled: Bool { didSet { guard !previewMode else { return }; UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") } }
    /// Opt-in: silence this Mac's output while dictating; never during a call. Off by default.
    @Published var muteOutputWhileDictating: Bool { didSet { guard !previewMode else { return }; UserDefaults.standard.set(muteOutputWhileDictating, forKey: "muteOutputWhileDictating") } }
    private var lastErrorCode = "none"
    private var lastModelCheck = "not_checked"
    private let readinessWaitMessage = "Local speech is busy. Try again when it’s ready."
    private var stopDiagnostics = RecordingStopTracker()
    private var startupDiagnostics = RecordingStartupTracker()
    /// Any edit that didn't come from a dictation ends Use original transcription, even one that retypes the same words.
    @Published var practiceText = "" { didSet { if practiceText != oldValue, !appendingPractice { practiceChange?.restorable = false } } }
    @Published private(set) var practiceChange: PracticeChange?
    private var appendingPractice = false
    @Published private(set) var isPracticeSession = false
    @Published var compatibilityPaste: Bool { didSet { guard !previewMode else { return }; UserDefaults.standard.set(compatibilityPaste, forKey: "compatibilityPaste") } }
    @Published var mode: ActivationMode { didSet { guard !previewMode else { return }; UserDefaults.standard.set(mode.rawValue, forKey: "activationMode") } }
    @Published private(set) var dictationShortcut: DictationShortcut
    @Published private(set) var editingShortcut = false
    @Published private(set) var shortcutMessage = ""
    @Published var microphoneUID: String { didSet {
        guard !previewMode else { return }
        if microphoneUID != oldValue { capture.preventReuse() }
        UserDefaults.standard.set(microphoneUID, forKey: "microphoneUID")
    } }
    @Published private(set) var recoveryReason: RecoveryReason?
    @Published private(set) var recoveryDetail = ""
    @Published private(set) var returning = false
    /// Optional local dictation history. `nil` retention means the user has not chosen; nothing is saved.
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var historyRetention: HistoryRetention?
    @Published private(set) var historyMessage = ""
    /// Voice notes: saved text documents. Audio is never stored.
    @Published private(set) var notes: [Note] = []
    @Published var selectedNoteID: UUID?
    @Published private(set) var recordingNoteID: UUID?
    @Published private(set) var liveConfirmed = ""
    @Published private(set) var liveVolatile = ""
    @Published private(set) var notesMessage = ""
    /// Personal dictionary, behind the hidden developer default `showPersonalDictionary`. Off: no file is read and nothing changes words.
    @Published private(set) var showsPersonalDictionary: Bool
    @Published private(set) var dictionary = PersonalDictionary()
    @Published private(set) var dictionaryState = DictionaryState.missing
    @Published private(set) var dictionaryIssues: [UUID: [DictionaryIssue]] = [:]
    @Published private(set) var dictionaryHasSetAside = false
    @Published private(set) var dictionaryMessage = ""
    private(set) var dictionaryMatcher = DictionaryMatcher.empty
    /// In memory only: the original transcription after your spellings left Within.
    @Published private(set) var lastDictationChange: LastDictationChange?
    @Published private(set) var lastChangeCopyFailed = false
    /// The 5-minute limit passed while the row had keyboard or VoiceOver focus: the words are gone, the row stays until focus leaves.
    @Published private(set) var lastChangeExpiredWhileFocused = false
    /// Set by the menu bar item; the Dictation row takes focus and resets it.
    @Published var lastChangeFocusRequested = false
    var lastChangeRowHasFocus = false
    private var lastChangeExpiry: Task<Void, Never>?
    /// Meetings, behind the hidden developer default `showMeetingsSpace`, read once at launch. Off: an inert
    /// controller and no store. This build has no path that starts a meeting either way.
    @Published private(set) var showsMeetingsSpace: Bool
    /// Views observe it directly; a nested object doesn't republish through this one.
    private(set) var meetings = MeetingController(preview: true)
    /// Meeting files in `Meetings.noindex`, kept by upkeep whatever the default says.
    @Published private(set) var savedMeetingCount = 0
    /// That folder exists but couldn't be listed, so the count can't be trusted.
    @Published private(set) var meetingsUnlistable = false
    @Published private(set) var meetingsMessage = ""
    /// The stored `meetingRetention`; unset keeps meetings until deleted. Nothing in this build writes it.
    private(set) var meetingRetention: DocumentRetention
    /// A quit, logout, restart or shutdown saving the meeting; one at a time.
    private var meetingQuit: Task<Bool, Never>?
    /// Update checks: `nil` means not chosen, which behaves as off. Nothing installs itself.
    @Published private(set) var automaticUpdateChecks: Bool?
    @Published private(set) var updateResult: UpdateCheckResult?
    @Published private(set) var checkingForUpdates = false

    let manifest: ModelManifest
    let store: ModelStore
    private let speech = LocalSpeech()
    private let capture = CaptureEngine()
    private lazy var shortcut = ShortcutManager()
    private var gesture = ShortcutGesture()
    private var shortcutActivationID: UUID?
    private var shortcutRegistrationPending = false
    private var target: AccessibilityTarget?
    private var initialBlock: RecoveryReason?
    private var forcedRecovery: String?
    private var trial = InsertionTrial()
    private var worker: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var pulse: Task<Void, Never>?
    private var unloadAfterSession = false
    private var unloading = false
    private var meetingsBase: URL?
    private var meetingObservers: [AnyCancellable] = []
    private var meetingWasOpen = false
    private var meetingFailureSeen: MeetingStretchEnd?
    private var meetingEndSeen: MeetingStretchEnd?
    private var meetingSaveFailedSeen = false
    /// A lock, sleep or user switch reached a capturing meeting, and whether it was still starting; announced after
    /// unlock or wake, not while the screen locks.
    private var boundaryPause: (reason: MeetingStretchEnd, starting: Bool)?
    private var recoveryActionEpoch = 0
    private var observers: [NSObjectProtocol] = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var pasteChosenForSession = false
    private var fromHoldShortcut = false
    private let previewMode: Bool
    private var historyStore: HistoryStore?
    private var historyTimer: Timer?
    private var notesStore: NotesStore?
    private(set) var dictionaryStore: DictionaryStore?
    private var pendingNoteGap: String?
    private var noteSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var updateTimer: Timer?
    private var lastNoteCheckpoint = ContinuousClock.now
    var stateChanged: (() -> Void)?
    var showMain: (() -> Void)?
    var showSettings: (() -> Void)?
    var showAudioSettings: (() -> Void)?
    var showModelSettings: (() -> Void)?
    var showHistorySettings: (() -> Void)?
    var showDictionarySettings: (() -> Void)?
    var showAboutSettings: (() -> Void)?
    var showHelp: (() -> Void)?
    var showSetup: (() -> Void)?
    var showPractice: (() -> Void)?
    var practiceAreaIsActive: (() -> Bool)?
    var showRecovery: (() -> Void)?
    var dismissRecovery: (() -> Void)?

    var phase: DictationPhase { session.phase }
    var pendingText: String { session.transcript ?? "" }
    var shortcutLabel: String { dictationShortcut.displayName }
    var canStart: Bool { !editingShortcut && phase == .ready && !workerBusy && modelInstalled && modelVerified && !modelBusy && microphoneAllowed && selectedInputAvailable }
    var selectedInputAvailable: Bool { microphoneUID.isEmpty ? !devices.isEmpty : devices.contains { $0.id == microphoneUID } }
    var selectedInputName: String {
        if microphoneUID.isEmpty { return devices.isEmpty ? "No microphone available" : "System default" }
        return devices.first(where: { $0.id == microphoneUID })?.name ?? "Selected microphone unavailable"
    }
    var targetName: String { target?.appName ?? "original app" }
    var canReturn: Bool { recoveryReason?.permitsReturn == true && target != nil && !returning }
    var isActive: Bool { phase == .preparing || phase == .recording }
    var hasActivePracticeSession: Bool { isPracticeSession && (isActive || phase == .transcribing) }
    var startsInPractice: Bool { practiceAreaIsActive?() == true }
    var effectiveRetention: HistoryRetention { historyRetention ?? .off }
    var isRecordingNote: Bool { recordingNoteID != nil }
    /// What holds the microphone. An open meeting counts while paused too, so it blocks dictation and notes.
    var activeCapture: CaptureActivity {
        if meetings.isOpen { return .meeting }
        if isRecordingNote { return .note }
        return phase == .preparing || phase == .recording || phase == .transcribing ? .dictation : .none
    }
    /// `canStart` is true between a meeting's stretches; dictation-facing controls use this instead.
    var canStartDictation: Bool { canStart && activeCapture == .none }
    static let meetingDictationRefusal = "Finish your meeting to dictate."
    static let meetingNoteRefusal = "Finish your meeting to record a note."
    static let meetingModelRefusal = "Finish your meeting before removing the model."
    static let meetingDownloadRefusal = "Finish your meeting before downloading the model."
    /// A quit must wait for the meeting: it is open, a finished one still has something to write, or a quit is
    /// already saving it.
    var meetingNeedsSaveToQuit: Bool { activeCapture == .meeting || meetings.hasUnsavedWork || meetingQuit != nil }
    var quittingMeeting: Bool { meetingQuit != nil }
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    var availableUpdate: ReleaseInfo? { if case .available(let release) = updateResult { return release }; return nil }
    var selectedNote: Note? { notes.first { $0.id == selectedNoteID } }
    var privacySummary: String {
        switch effectiveRetention {
        case .off: return "On your Mac. No recordings or dictation history saved."
        case .forever: return "On your Mac. No recordings saved. Dictation history kept until you delete it."
        default: return "On your Mac. No recordings saved. Dictation history kept \(effectiveRetention.title)."
        }
    }
    func shouldCancelPracticeOnClose(sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return hasActivePracticeSession && session.isCurrent(sessionID)
    }

    /// `dictionaryFixture` is for native checks: nothing starts, and only the dictionary under `base` is read and saved.
    init(manifest: ModelManifest, base: URL, preview: Bool = false, dictionaryFixture: Bool = false) {
        self.manifest = manifest
        previewMode = preview
        store = ModelStore(manifest: manifest, base: base)
        soundsEnabled = UserDefaults.standard.bool(forKey: "soundsEnabled")
        muteOutputWhileDictating = UserDefaults.standard.bool(forKey: "muteOutputWhileDictating")
        compatibilityPaste = UserDefaults.standard.bool(forKey: "compatibilityPaste")
        mode = ActivationMode(rawValue: UserDefaults.standard.string(forKey: "activationMode") ?? "hold") ?? .hold
        dictationShortcut = .restored(from: UserDefaults.standard.data(forKey: "dictationShortcut"), legacyAlternate: UserDefaults.standard.bool(forKey: "alternateShortcut"))
        microphoneUID = UserDefaults.standard.string(forKey: "microphoneUID") ?? ""
        setupComplete = UserDefaults.standard.bool(forKey: "setupComplete")
        historyRetention = .restored(from: UserDefaults.standard.string(forKey: "historyRetention"))
        automaticUpdateChecks = UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool
        showsPersonalDictionary = dictionaryFixture || UserDefaults.standard.bool(forKey: "showPersonalDictionary")
        showsMeetingsSpace = !dictionaryFixture && UserDefaults.standard.bool(forKey: "showMeetingsSpace")
        meetingRetention = .restored(from: UserDefaults.standard.string(forKey: "meetingRetention"))
        observeMeetings()
        if preview { return }
        if dictionaryFixture { openDictionary(base); return }
        // Upkeep runs whatever the default says; only use of meetings waits for it.
        meetingsBase = base
        let upkeep = MeetingUpkeep.atLaunch(base: base, retention: meetingRetention, now: Date())
        savedMeetingCount = upkeep?.saved ?? 0; meetingsUnlistable = upkeep?.unlistable ?? false
        if showsMeetingsSpace {
            meetings = MeetingController(speech: speech, host: self, store: MeetingStore(meetingsIn: base)) { [weak self] app in
                guard let self else { return [] }
                var sources: [MeetingAudioSource] = [MicrophoneSource(capture: capture) { [weak self] in self?.microphoneUID ?? "" }]
                if let app, #available(macOS 14.2, *) { sources.append(AppAudioSource(app: app)) }
                return sources
            }
            observeMeetings()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutomaticUpdateCheckIfDue() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.runAutomaticUpdateCheckIfDue()
        }
        recoverOutputMuteAtLaunch()
        historyStore = HistoryStore(directory: base.appendingPathComponent("History", isDirectory: true))
        loadHistory()
        notesStore = NotesStore(directory: base.appendingPathComponent("Notes", isDirectory: true))
        loadNotes()
        if showsPersonalDictionary { openDictionary(base) }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneHistory(); self?.pruneMeetings() }
        }
        shortcut.activationMode = { [weak self] in self?.mode ?? .hold }
        shortcut.onDown = { [weak self] in self?.shortcutPressed() }
        shortcut.onUp = { [weak self] in
            guard let self else { return }
            if gesture.up() == .stop { stop(cause: .hotKeyRelease) }
            shortcutActivationID = nil
            if shortcutRegistrationPending { registerShortcut() }
        }
        shortcut.onTap = { [weak self] in
            guard let self, mode == .toggle, !editingShortcut else { return }
            shortcut.onDown?(); shortcut.onUp?()
        }
        shortcut.onInterrupted = { [weak self] in
            guard let self else { return }
            if let shortcutActivationID, session.isCurrent(shortcutActivationID), isActive {
                cancel(reason: "Shortcut changed to a key combination. Recording canceled.", cause: .shortcutInterrupted)
            }
            _ = gesture.up(); shortcutActivationID = nil
        }
        capture.onConfigurationChanged = { [weak self] in
            guard let self else { return }
            // A meeting holds the session too: its microphone change pauses it, never a dictation stop.
            if meetings.isOpen { meetings.microphoneChanged(); return }
            guard phase == .recording else { return }
            lastErrorCode = "audio_input_interrupted"
            forcedRecovery = "Audio input was interrupted. Review the words captured before it stopped."; stop(cause: .inputChanged)
        }
        registerShortcut()
        refreshPermissions()
        installLifecycleObservers()
        modelTask = Task { [weak self] in
            guard let self else { return }
            await speech.setIntegrityFailureHandler { [weak self] in await self?.invalidateModelVerification() }
            try? await store.cleanInterruptedDownloads()
            modelInstalled = await store.isInstalled()
            modelMessage = modelInstalled ? "Preparing local speech…" : "One local model. No account."
            if modelInstalled {
                modelBusy = true
                do { try await speech.prepare(directory: store.directory, manifest: manifest); modelVerified = true; modelMessage = "Verified and ready · runs offline"; lastModelCheck = "passed" }
                catch { lastModelCheck = "failed_or_unavailable"; modelMessage = "Model unavailable. Remove it and download a fresh copy." }
                modelBusy = false
            }
            modelTask = nil; notify()
        }
    }

    func registerShortcut() {
        guard !previewMode, !editingShortcut else { return }
        shortcutAvailable = shortcut.register(dictationShortcut)
        shortcutRegistrationPending = false
    }
    func beginShortcutEditing() -> Bool {
        guard phase == .ready, !workerBusy, !editingShortcut else { return false }
        editingShortcut = true; shortcutMessage = ""
        if !previewMode { shortcut.unregisterDictation() }
        gesture = ShortcutGesture(); shortcutActivationID = nil
        notify(); return true
    }
    func endShortcutEditing() {
        guard editingShortcut else { return }
        editingShortcut = false; registerShortcut(); notify()
    }
    @discardableResult func chooseShortcut(_ candidate: DictationShortcut) -> Bool {
        guard phase == .ready, !workerBusy else {
            shortcutMessage = "Wait for the current work to finish, then try again."; notify(); return false
        }
        guard candidate.isValid else {
            shortcutMessage = "That key is used for typing or system commands. Choose another shortcut."; notify(); return false
        }
        let registered = previewMode || shortcut.register(candidate)
        if !registered && !(candidate.isModifierOnly && !accessibilityAllowed) {
            shortcutMessage = "That shortcut is unavailable. Try a different combination."
            if editingShortcut { shortcut.unregisterDictation() } else { registerShortcut() }
            notify(); return false
        }
        dictationShortcut = candidate; shortcutAvailable = registered; shortcutMessage = ""
        if !previewMode {
            UserDefaults.standard.set(try? JSONEncoder().encode(candidate), forKey: "dictationShortcut")
            if editingShortcut { shortcut.unregisterDictation() }
        }
        notify(); return true
    }
    func refreshPermissions() {
        refreshPermissions(mayRegisterShortcut: true)
    }
    private func refreshPermissions(mayRegisterShortcut: Bool) {
        guard !previewMode else { return }
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !microphoneAllowed { capture.preventReuse() }
        let accessibilityChanged = accessibilityAllowed != AXIsProcessTrusted()
        accessibilityAllowed = AXIsProcessTrusted()
        loginEnabled = SMAppService.mainApp.status == .enabled
        devices = CaptureEngine.devices()
        if accessibilityChanged && dictationShortcut.isModifierOnly { shortcutRegistrationPending = true }
        // A press callback must retain its release handler if permissions changed.
        if shortcutRegistrationPending && mayRegisterShortcut && !shortcut.isHeld(dictationShortcut) { registerShortcut() }
        notify()
    }
    func requestMicrophone() {
        guard !microphoneAllowed else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
        } else { openSystemSettings("Privacy_Microphone") }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
        if !accessibilityAllowed { openSystemSettings("Privacy_Accessibility") }
    }
    private func openSystemSettings(_ page: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)") { NSWorkspace.shared.open(url) }
    }

    func downloadModel() {
        guard !meetings.isOpen else { announce(Self.meetingDownloadRefusal); return }
        guard !modelBusy, !workerBusy, phase == .ready, !modelInstalled else { return }
        modelBusy = true; modelDownloading = true; modelMessage = "Downloading model files…"; downloadProgress = 0
        modelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.install { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.modelBusy, self.modelDownloading else { return }
                        self.downloadProgress = max(self.downloadProgress, Double(progress.completedBytes) / Double(progress.totalBytes))
                        self.modelMessage = "Downloading file \(progress.file) of \(progress.count)…"
                    }
                }
                modelInstalled = true; modelDownloading = false; modelMessage = "Preparing local speech…"
                try await speech.prepare(directory: store.directory, manifest: manifest)
                modelVerified = true; modelMessage = "Verified and ready · runs offline"; lastModelCheck = "passed"
            } catch is CancellationError { modelMessage = "Download canceled. Temporary files removed." }
            catch { modelMessage = Task.isCancelled ? "Download canceled. Temporary files removed." : modelInstalled ? "Model unavailable. Remove it and download a fresh copy." : "Download couldn’t be verified. Check your connection and try again." }
            modelBusy = false; modelDownloading = false; modelTask = nil; notify()
        }
    }
    func cancelDownload() { modelTask?.cancel() }
    func completeSetup() {
        setupComplete = true
        if !previewMode { UserDefaults.standard.set(true, forKey: "setupComplete") }
    }
    func invalidateModelVerification() {
        modelVerified = false
        lastModelCheck = "failed"
        modelMessage = "Model files failed verification. Remove the model and download a fresh copy."
        notify()
    }
    func removeModel() {
        // The button is disabled with this reason shown; the model's status line keeps describing the model.
        guard !meetings.isOpen else { announce(Self.meetingModelRefusal); return }
        guard !modelBusy, !workerBusy, phase == .ready else { return }
        capture.preventReuse()
        modelBusy = true
        modelTask = Task { [weak self] in
            guard let self else { return }
            await speech.unload()
            do { try await store.remove(); modelInstalled = false; modelVerified = false; modelMessage = "Model removed from this Mac." }
            catch { modelMessage = "The model couldn’t be removed. Try again after restarting Within." }
            modelBusy = false; modelDownloading = false; modelTask = nil; notify()
        }
    }

    /// The dictation shortcut went down. Another capture refuses it with its own reason.
    func shortcutPressed() {
        guard !editingShortcut else { return }
        guard !isRecordingNote else { refuseDictationDuringNote(); return }
        guard !meetings.isOpen else { refuseDictationDuringMeeting(); return }
        switch gesture.down(mode: mode, isActive: isActive) {
        case .start:
            startFromCurrentWindow(fromShortcut: true)
            shortcutActivationID = isActive ? session.id : nil
        case .stop: shortcutActivationID = nil; stop(cause: .togglePress)
        case nil: break
        }
    }
    func startFromCurrentWindow(fromShortcut: Bool = false) {
        start(practice: startsInPractice, fromShortcut: fromShortcut)
    }
    func start(practice: Bool, fromShortcut: Bool = false) {
        guard !editingShortcut else { return }
        guard !isRecordingNote else { refuseDictationDuringNote(); return }
        guard !meetings.isOpen else { refuseDictationDuringMeeting(); return }
        let requestedAt = ContinuousClock.now
        refreshPermissions(mayRegisterShortcut: !fromShortcut)
        guard canStart else {
            if phase == .recovery { showRecovery?() }
            else if phase != .ready { announce(message) }
            else if modelBusy || workerBusy { message = readinessWaitMessage; announce(message); notify() }
            else if !modelInstalled || !microphoneAllowed { message = "Finish setup before you dictate."; showMain?() }
            else if !selectedInputAvailable { message = "Your selected microphone is unavailable. Reconnect it or choose another in Settings."; showMain?() }
            else if !modelVerified { message = "Check the local speech model in Settings."; showModelSettings?() }
            return
        }
        startupDiagnostics.begin(trigger: fromShortcut ? (mode == .hold ? .holdShortcut : .tapShortcut) : .control,
            practice: practice, at: requestedAt)
        startupDiagnostics.mark(.permissionsReady)
        target?.stopObserving(); target = nil; initialBlock = nil; forcedRecovery = nil
        pasteChosenForSession = false
        fromHoldShortcut = fromShortcut && mode == .hold
        audioFlowing = false
        if !practice {
            switch AccessibilityTarget.capture(allowUnsupported: compatibilityPaste) {
            case .success(let destination):
                target = destination
                pasteChosenForSession = compatibilityPaste && !destination.evidence().canReplaceSelection
            case .failure(let error):
                if error.reason == .secureField { message = "Dictation is unavailable in protected fields."; announce(message); return }
                initialBlock = error.reason
            }
        }
        startupDiagnostics.mark(.targetCaptured)
        guard let id = session.begin() else { return }
        isPracticeSession = practice
        stopDiagnostics.begin()
        capture.resetDiagnostics()
        trial.discard(); workerBusy = true; message = "Preparing local speech…"; elapsed = 0; level = 0
        notify()
        resumeEscapeShortcut()
        startupDiagnostics.mark(.feedbackPresented)
        // Dictionary edits during this recording apply to the next one.
        let matcher = dictionaryMatcher
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = await store.directory
                try await speech.prepare(directory: directory, manifest: manifest)
                lastModelCheck = "passed"
                try Task.checkCancellation()
                guard session.isCurrent(id) else { throw CancellationError() }
                startupDiagnostics.mark(.modelReady)
                try await speech.begin()
                try Task.checkCancellation()
                guard session.isCurrent(id) else { throw CancellationError() }
                startupDiagnostics.mark(.speechReady)
                guard !IsSecureEventInputEnabled() else { throw CaptureFailure.protectedInput }
                if let target, target.evidence(forCompatibilityPaste: pasteChosenForSession).blockReason != nil { throw CaptureFailure.targetChanged }
                startupDiagnostics.mark(.targetRechecked)
                let ring = try capture.start(deviceUID: microphoneUID) { self.startupDiagnostics.mark($0) }
                let rate = capture.sampleRate
                guard session.recording(id) else { capture.stop(); throw CancellationError() }
                if !practice { muteOutputIfNeeded() }
                message = "Starting microphone…"; notify()
                startupDiagnostics.mark(.recordingPublished)
                startPulse(ring: ring, sampleRate: rate, id: id)
                let text = try await speech.consume(ring, sampleRate: rate)
                try Task.checkCancellation()
                guard session.isCurrent(id) else { throw CancellationError() }
                capture.stop(); pulse?.cancel(); pulse = nil
                if phase == .recording {
                    recordStop(ring.status == 2 ? .bufferOverflow : ring.status == 3 ? .durationLimit : .streamEnded)
                }
                if ring.status == 2 { forcedRecovery = "Recording stopped because speech processing fell behind. These are the words captured before the stop." }
                if phase == .recording { _ = session.stopped(id) }
                let result = matcher.apply(to: text)
                if text.isEmpty {
                    session.finish(id)
                    message = forcedRecovery == nil ? "No speech detected. Try again when you’re ready." : "Recording stopped before any words were captured. Check the microphone and try again."
                    releaseTarget(); announce(message)
                }
                else if practice {
                    completeSetup()
                    appendPractice(result)
                    session.finish(id); message = "Your words arrived. Try the shortcut in another app."; releaseTarget()
                    announce(result.changed ? "Practice dictation finished. Your dictionary made \(Self.count(result.changes.count, "change"))." : "Practice dictation finished")
                } else { await deliver(result, id: id) }
            } catch {
                capture.stop(reusingStoppedEngine: false); pulse?.cancel(); pulse = nil; shortcut.stopEscapeMonitor()
                restoreOutputIfNeeded()
                if session.isCurrent(id) { recordStop(.pipelineError) }
                await speech.cancel()
                // Model integrity is independent of whether the user canceled this session.
                if error is IntegrityError { invalidateModelVerification() }
                if session.isCurrent(id), case SpeechFailure.partial(let text) = error {
                    forcedRecovery = "Transcription stopped early. These are the words recovered before the error; part of your dictation may be missing."
                    await deliver(matcher.apply(to: text), id: id)
                } else if session.isCurrent(id) {
                    session.finish(id); releaseTarget()
                    lastErrorCode = error is IntegrityError ? "model_integrity" : "capture_or_inference"
                    message = error is CancellationError ? "Canceled. Microphone off." : "Dictation stopped. Audio was discarded. Check the microphone and local model, then try again."
                    if case CaptureFailure.protectedInput = error { message = "Protected input is active. Microphone off." }
                    if case CaptureFailure.targetChanged = error { message = "The destination changed before recording. Choose your text field and try again." }
                    announce(message)
                }
            }
            if unloadAfterSession { await speech.unload(); capture.preventReuse(); unloadAfterSession = false }
            shortcut.stopEscapeMonitor()
            workerBusy = false; worker = nil; notify()
        }
    }

    func suspendEscapeShortcut() { if !previewMode { shortcut.stopEscapeMonitor() } }
    func resumeEscapeShortcut() {
        // A long note recording or a meeting is never canceled by a global Escape.
        guard !previewMode, activeCapture == .dictation else { return }
        shortcut.monitorEscape { [weak self] in self?.cancel(cause: .escape) }
    }

    private func startPulse(ring: AudioRing, sampleRate: Double, id: UUID) {
        pulse?.cancel()
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(CaptureLimits.dictation.totalSeconds))
        pulse = Task { [weak self] in
            var lastSampleCount: UInt64 = 0
            var lastAudioProgress = started
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, session.isCurrent(id), phase == .recording else { return }
                level = min(1, ring.level * 7); elapsed = Double(ring.samplesCaptured) / sampleRate
                if ring.samplesCaptured != lastSampleCount { lastSampleCount = ring.samplesCaptured; lastAudioProgress = .now }
                if audioFlowing, ContinuousClock.now >= lastAudioProgress.advanced(by: .seconds(5)) {
                    forcedRecovery = "The microphone stopped sending audio. Review the words captured before it stopped."; stop(cause: .audioStalled); return
                }
                if !audioFlowing, ring.samplesCaptured > 0 {
                    startupDiagnostics.mark(.firstAudioObserved)
                    audioFlowing = true; message = "Listening"; announce("Recording started"); playCue(start: true)
                }
                if !audioFlowing, ContinuousClock.now >= started.advanced(by: .seconds(5)) { cancel(reason: "No audio arrived from the microphone. Check the selected input and try again.", cause: .noAudio); return }
                if fromHoldShortcut {
                    let chord = shortcut.chordState(dictationShortcut)
                    if gesture.poll(chordHeld: shortcut.isHeld(dictationShortcut)) == .stop {
                        stop(cause: .holdWatchdog, hardwareChord: chord); return
                    }
                }
                if IsSecureEventInputEnabled() { cancel(reason: "Protected input became active. Recording canceled.", cause: .secureInput); return }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { cancel(reason: "Microphone access changed. Recording canceled.", cause: .microphonePermission); return }
                if ring.status != 0 || ContinuousClock.now >= deadline {
                    if ring.status == 2 { forcedRecovery = "Recording stopped because speech processing fell behind. Review the captured words before using them." }
                    else { message = "Five-minute limit reached. Finishing your words…"; announce("Five-minute limit reached. Recording stopped") }
                    stop(cause: ring.status == 2 ? .bufferOverflow : .durationLimit); return
                }
            }
        }
    }
    func stop() { stop(cause: .stopButton) }
    private func stop(cause: RecordingStopCause, hardwareChord: ShortcutChordState? = nil) {
        // A meeting holds the session as well; only its own controls end it.
        guard activeCapture != .meeting, let id = session.id else { return }
        if phase == .preparing {
            // Nothing has been heard yet; call the private path directly so a note's cancel→stop routing cannot loop.
            cancel(reason: isRecordingNote ? "Note recording canceled before it started." : "Canceled. Microphone off.", cause: cause); return
        }
        guard phase == .recording else { return }
        capture.stop(); pulse?.cancel(); pulse = nil
        restoreOutputIfNeeded()
        if !isRecordingNote { recordStop(cause, hardwareChord: hardwareChord) }
        _ = session.stopped(id); playCue(start: false); level = 0; message = "Finishing on this Mac…"; notify(); announce("Recording stopped. Transcribing")
    }
    func cancel() { cancel(cause: .cancelButton) }
    func cancel(cause: RecordingStopCause) {
        guard activeCapture != .meeting || cause == .shutdown else { return }
        // Canceling a note recording keeps what was heard: it stops and saves instead.
        if isRecordingNote, cause != .shutdown { stop(cause: cause); return }
        cancel(reason: "Canceled. Microphone off.", cause: cause)
    }
    private func cancel(reason: String, cause: RecordingStopCause) {
        capture.stop(reusingStoppedEngine: false); pulse?.cancel(); pulse = nil; shortcut.stopEscapeMonitor()
        restoreOutputIfNeeded()
        recordStop(cause)
        worker?.cancel(); session.cancel(); trial.discard(); releaseTarget()
        recoveryReason = nil; recoveryDetail = ""; level = 0; message = reason
        dismissRecovery?(); notify(); announce(message)
    }
    private func recordStop(_ cause: RecordingStopCause, hardwareChord: ShortcutChordState? = nil) {
        guard isActive || phase == .transcribing, stopDiagnostics.lastStop == nil else { return }
        startupDiagnostics.finish()
        stopDiagnostics.record(RecordingStopDiagnostic(cause: cause, phase: phase,
            hardwareChord: hardwareChord ?? shortcut.chordState(dictationShortcut),
            sessionChord: shortcut.chordState(dictationShortcut, source: .combinedSessionState),
            eventListeningAllowed: CGPreflightListenEventAccess(),
            audioConfiguration: capture.lastConfigurationChange))
    }
    private func deliver(_ result: DictionaryResult, id: UUID) async {
        let text = result.text
        guard session.isCurrent(id), trial.begin(text: text) else { return }
        if forcedRecovery != nil { trial.recover(.targetUnavailable) }
        else if let initialBlock { trial.recover(initialBlock) }
        else if pasteChosenForSession, let target, trial.authorize(target.evidence(forCompatibilityPaste: true)) {
            let detail = await CompatibilityPaste.perform(text: text, target: target) { self.session.isCurrent(id) }
            guard session.isCurrent(id), !Task.isCancelled else { return }
            trial.completeWrite(confirmed: false)
            forcedRecovery = detail
        }
        else if let target, trial.authorize(target.evidence()) {
            trial.completeWrite(confirmed: target.replaceSelection(with: text))
        } else if target == nil { trial.recover(.targetUnavailable) }
        if trial.phase == .inserted {
            session.finish(id); releaseTarget()
            message = Self.insertedMessage(changes: result.changes.count)
            announce(result.changed ? "Dictation inserted. Your dictionary made \(Self.count(result.changes.count, "change"))." : "Dictation inserted")
            recordHistory(text, original: nil, practice: isPracticeSession)
            if result.changed { keepLastDictationChange(original: result.original, changes: result.changes, sessionID: id) }
        } else {
            suspendEscapeShortcut()
            _ = session.recover(result, id: id)
            if case .recovery(let reason) = trial.phase { recoveryReason = reason }
            else { recoveryReason = .uncertainWrite }
            lastErrorCode = recoveryReason?.rawValue ?? "insertion_unconfirmed"
            recoveryDetail = forcedRecovery ?? recoveryReason?.explanation ?? "Your words are ready for review."
            message = "Your words are here."; notify(); showRecovery?(); announce("Your dictation is ready for review")
        }
    }
    func returnToOriginal() {
        guard canReturn, let target, let id = session.id else { return }
        returning = true
        recoveryActionEpoch += 1
        let epoch = recoveryActionEpoch
        Task { [weak self] in
            guard let self else { return }
            let restored = target.restoreOriginalTarget()
            try? await Task.sleep(for: .milliseconds(180))
            guard session.isCurrent(id), phase == .recovery, recoveryActionEpoch == epoch else { returning = false; return }
            if restored, trial.authorize(target.evidence(ignoreFocusHistory: true), explicitReturn: true) {
                trial.completeWrite(confirmed: target.replaceSelection(with: pendingText))
            } else { trial.recover(.targetUnavailable) }
            returning = false
            if trial.phase == .inserted {
                let words = pendingText, original = session.originalTranscription, changes = session.dictionaryChanges
                discard(); message = "Inserted into the original field."; announce(message)
                recordHistory(words, original: nil, practice: isPracticeSession)
                if let original { keepLastDictationChange(original: original, changes: changes, sessionID: id) }
            }
            else {
                if case .recovery(let reason) = trial.phase { recoveryReason = reason; recoveryDetail = reason.explanation }
                showRecovery?()
            }
        }
    }
    func copyPending(pasteboard: NSPasteboard = .general) {
        guard phase == .recovery, !workerBusy, !returning, !pendingText.isEmpty, let id = session.id else { return }
        pasteboard.clearContents()
        let words = pendingText, original = session.originalTranscription, changes = session.dictionaryChanges
        if pasteboard.setString(words, forType: .string) {
            discard(); message = "Copied. Your clipboard may sync through macOS."; announce("Copied to clipboard")
            recordHistory(words, original: nil, practice: isPracticeSession)
            if let original { keepLastDictationChange(original: original, changes: changes, sessionID: id) }
        }
        else { recoveryDetail = "Copy failed. Your words are still here." }
    }
    /// Shows the other version of the pending words; Return and Copy use whichever is showing.
    func switchPendingWords() {
        guard phase == .recovery, !workerBusy, !returning, session.switchPendingWords() else { return }
        announce(session.showingOriginal ? "Showing original transcription" : "Showing your spellings")
    }
    func discard() {
        guard !workerBusy else { return }
        session.cancel(); trial.discard(); releaseTarget(); recoveryReason = nil; recoveryDetail = ""
        dismissRecovery?(); message = "Ready when you are."; notify()
    }
    private func releaseTarget() { target?.stopObserving(); target = nil }

    // MARK: Original transcription

    /// Your spellings left Within: keeps the original transcription in memory for Copy original transcription.
    /// Only a later dictation the dictionary changed replaces it.
    private func keepLastDictationChange(original: String, changes: [DictionaryChange], sessionID: UUID) {
        setLastDictationChange(LastDictationChange(sessionID: sessionID, original: original, changes: changes, time: Date()))
        lastChangeExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.expireLastDictationChange(sessionID: sessionID)
        }
    }
    private func setLastDictationChange(_ change: LastDictationChange?) {
        lastChangeExpiry?.cancel(); lastChangeExpiry = nil
        lastDictationChange = change; lastChangeCopyFailed = false; lastChangeExpiredWhileFocused = false
        notify()
    }
    private func clearLastDictationChange() {
        if lastDictationChange != nil || lastChangeExpiredWhileFocused { setLastDictationChange(nil) }
    }
    /// The 5-minute limit. An earlier dictation's timer never clears a later one.
    func expireLastDictationChange(sessionID: UUID) {
        guard lastDictationChange?.sessionID == sessionID else { return }
        let focused = lastChangeRowHasFocus
        setLastDictationChange(nil)
        lastChangeExpiredWhileFocused = focused
    }
    func lastChangeRowLostFocus() {
        lastChangeRowHasFocus = false
        if lastChangeExpiredWhileFocused { lastChangeExpiredWhileFocused = false }
    }
    func dismissLastDictationChange() { clearLastDictationChange() }
    func copyLastOriginal(pasteboard: NSPasteboard = .general) {
        guard let change = lastDictationChange else {
            guard lastChangeExpiredWhileFocused else { return }
            clearLastDictationChange(); message = "The original transcription is no longer kept."; announce(message); return
        }
        pasteboard.clearContents()
        guard pasteboard.setString(change.original, forType: .string) else {
            lastChangeCopyFailed = true; announce("Copy failed. The original transcription is still here."); return
        }
        clearLastDictationChange()
        message = "Copied the original transcription. Your clipboard may sync through macOS."; announce("Copied the original transcription")
    }
    /// Previews and native checks only: no timer starts.
    func previewLastDictationChange(_ change: LastDictationChange?) {
        guard previewMode else { return }
        setLastDictationChange(change)
    }
    static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
    static func insertedMessage(changes: Int) -> String {
        changes == 0 ? "Inserted. Microphone off." : "Inserted with \(count(changes, "dictionary change")). Microphone off."
    }

    // MARK: Practice

    private func appendPractice(_ result: DictionaryResult) {
        let separator = practiceText.isEmpty ? "" : "\n"
        appendingPractice = true; practiceText += separator + result.text; appendingPractice = false
        practiceChange = result.changed ? PracticeChange(separator: separator, text: result.text, original: result.original, changes: result.changes) : nil
    }
    /// Only while the practice text is unedited since that result, so exactly the appended words are replaced.
    func useOriginalPracticeText() {
        guard let change = practiceChange, change.restorable else { return }
        let appended = (change.separator + change.text).utf8
        guard practiceText.utf8.suffix(appended.count).elementsEqual(appended) else { return }
        practiceText = String(decoding: practiceText.utf8.dropLast(appended.count), as: UTF8.self) + change.separator + change.original
        practiceChange = nil
        announce("Practice text now uses the original transcription")
    }
    func clearPractice() { practiceText = ""; practiceChange = nil }

    // MARK: Personal dictionary

    /// A file that couldn't be read, or came from a newer version, can only be set aside or deleted.
    var canEditDictionary: Bool { dictionaryState == .missing || dictionaryState == .loaded }
    /// Checks exactly what was typed, then saves it normalized. Issue positions match the fields given;
    /// blank fields are ignored. Returns the issues to show; none means the word was saved.
    func addDictionaryEntry(heardAs: [String], writeAs: String) -> [DictionaryIssue] {
        guard canEditDictionary else { return [] }
        let entry = DictionaryEntry(heardAs: heardAs, writeAs: writeAs, created: Date())
        let issues = DictionaryPolicy.editorIssues(for: entry, in: dictionary)
        guard issues.isEmpty else { return issues }
        dictionary.entries.append(Self.normalized(entry))
        dictionaryChanged()
        return []
    }
    func updateDictionaryEntry(_ id: UUID, heardAs: [String], writeAs: String) -> [DictionaryIssue] {
        guard canEditDictionary, let index = dictionary.entries.firstIndex(where: { $0.id == id }) else { return [] }
        var entry = dictionary.entries[index]
        entry.heardAs = heardAs; entry.writeAs = writeAs
        let issues = DictionaryPolicy.editorIssues(for: entry, in: dictionary)
        guard issues.isEmpty else { return issues }
        entry.modified = Date()
        dictionary.entries[index] = Self.normalized(entry)
        dictionaryChanged()
        return []
    }
    func setDictionaryEntry(_ id: UUID, enabled: Bool) {
        guard canEditDictionary, let index = dictionary.entries.firstIndex(where: { $0.id == id }),
              dictionary.entries[index].enabled != enabled else { return }
        dictionary.entries[index].enabled = enabled; dictionary.entries[index].modified = Date()
        dictionaryChanged()
    }
    func deleteDictionaryEntry(_ id: UUID) {
        guard canEditDictionary, dictionary.entries.contains(where: { $0.id == id }) else { return }
        dictionary.entries.removeAll { $0.id == id }
        dictionaryChanged()
        // A failed save has already announced itself; don't talk over it.
        if dictionaryMessage.isEmpty { announce("Word deleted from your dictionary") }
    }
    func setDictionaryEnabled(_ enabled: Bool) {
        guard canEditDictionary, dictionary.enabled != enabled else { return }
        dictionary.enabled = enabled; dictionaryChanged()
    }
    func deleteAllDictionaryEntries() {
        guard canEditDictionary else { return }
        deleteDictionaryFiles()
    }
    /// Also offered while the file can't be used. Memory goes back to defaults only after every file is gone.
    func deleteDictionaryFiles() {
        if !previewMode, let dictionaryStore {
            do { try dictionaryStore.removeAll() }
            catch { reloadDictionary(after: "Your dictionary couldn’t be deleted. Nothing was changed."); return }
        }
        replaceDictionary(with: .missing); dictionaryHasSetAside = false; dictionaryMessage = ""
        announce("Dictionary cleared")
    }
    /// Only while the file can't be used: keeps it under a new name in the same folder and starts empty.
    func startNewDictionary() {
        guard !canEditDictionary else { return }
        if !previewMode, let dictionaryStore {
            do { _ = try dictionaryStore.setAside() }
            catch { reloadDictionary(after: "Your dictionary file couldn’t be renamed. It was left untouched."); return }
        }
        replaceDictionary(with: .missing); dictionaryHasSetAside = true; dictionaryMessage = ""
    }
    /// The Dictation space's line while the dictionary can't do what the user set up. Counts only, never words.
    var dictionaryAttentionLine: String? {
        guard showsPersonalDictionary else { return nil }
        guard canEditDictionary else { return "Your dictionary couldn’t be read, so words are written as transcribed." }
        switch dictionaryIssues.count {
        case 0: return nil
        case 1: return "1 dictionary word needs attention and isn’t being used."
        case let count: return "\(count) dictionary words need attention and aren’t being used."
        }
    }
    func openDictionarySettings() { showDictionarySettings?() }
    /// Selects Within's own dictionary files in Finder: the saved file, or the earlier ones it kept. Nothing is opened or read.
    func showDictionaryFilesInFinder(setAside: Bool) {
        guard !previewMode, let dictionaryStore else { return }
        let files = dictionaryStore.shownInFinder(setAside: setAside)
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }
    /// Previews and native checks: the dictionary as the developer default shows it. Nothing is read or written.
    func previewDictionary(_ loaded: DictionaryStore.Loaded) {
        guard previewMode else { return }
        showsPersonalDictionary = true; replaceDictionary(with: loaded)
    }
    private func openDictionary(_ base: URL) {
        dictionaryStore = DictionaryStore(directory: base.appendingPathComponent("Dictionary.noindex", isDirectory: true))
        loadDictionary()
    }
    private func loadDictionary() {
        guard let dictionaryStore else { return }
        replaceDictionary(with: dictionaryStore.load())
        dictionaryHasSetAside = !dictionaryStore.setAsideFiles().isEmpty
    }
    /// After a failed delete or rename, shows what is on disk now, and the failure while the file is still there.
    private func reloadDictionary(after failure: String) {
        loadDictionary()
        dictionaryMessage = dictionaryState == .missing ? "" : failure
        if !dictionaryMessage.isEmpty { announce(dictionaryMessage) }
    }
    private func replaceDictionary(with loaded: DictionaryStore.Loaded) {
        switch loaded {
        case .loaded(let saved): dictionary = saved; dictionaryState = .loaded
        case .missing: dictionary = PersonalDictionary(); dictionaryState = .missing
        case .unreadable: dictionary = PersonalDictionary(); dictionaryState = .unreadable
        case .newerVersion: dictionary = PersonalDictionary(); dictionaryState = .newerVersion
        }
        refreshDictionary()
    }
    private func dictionaryChanged() { refreshDictionary(); persistDictionary() }
    /// Issues and the matcher always follow the entries. Off, or while the file can't be used, nothing changes words.
    private func refreshDictionary() {
        dictionaryIssues = DictionaryPolicy.loadIssues(dictionary)
        dictionaryMatcher = showsPersonalDictionary && canEditDictionary ? DictionaryMatcher(dictionary) : .empty
    }
    /// The only save path. It never writes over a file that couldn't be read or came from a newer version.
    private func persistDictionary() {
        guard !previewMode, let dictionaryStore, canEditDictionary else { return }
        do { try dictionaryStore.save(dictionary); dictionaryState = .loaded; dictionaryMessage = "" }
        catch {
            dictionaryMessage = "Your dictionary couldn’t be saved on this Mac. Your change applies until you quit."
            announce(dictionaryMessage)
        }
    }
    private static func normalized(_ entry: DictionaryEntry) -> DictionaryEntry {
        var copy = entry
        copy.writeAs = DictionaryPolicy.normalized(entry.writeAs)
        copy.heardAs = entry.heardAs.map(DictionaryPolicy.normalized).filter { !$0.isEmpty }
        return copy
    }

    // MARK: Mute while dictating

    private var selfBundleID: String { Bundle.main.bundleIdentifier ?? "com.madeordinary.Within" }
    private var outputMuteRecord: OutputMuteRecord? {
        get { UserDefaults.standard.data(forKey: "outputMuteRecord").flatMap { try? JSONDecoder().decode(OutputMuteRecord.self, from: $0) } }
        set { if let newValue, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "outputMuteRecord") } else { UserDefaults.standard.removeObject(forKey: "outputMuteRecord") } }
    }
    /// Silences the default output only if another app is playing and no other app is using a microphone.
    private func muteOutputIfNeeded() {
        guard !previewMode, muteOutputWhileDictating, outputMuteRecord == nil,
              let device = SystemOutput.defaultOutputDevice(), SystemOutput.canMute(device),
              let uid = SystemOutput.uid(of: device), let muted = SystemOutput.isMuted(device),
              OutputMutePolicy.shouldMute(enabled: true, clients: SystemOutput.audioClients(), selfBundleID: selfBundleID, deviceAlreadyMuted: muted) else { return }
        // Record before muting so a crash between the two still leaves a recovery path.
        outputMuteRecord = OutputMuteRecord(deviceUID: uid, mutedAt: Date())
        if !SystemOutput.setMuted(device, true) { outputMuteRecord = nil }
    }
    /// Unmutes the device Within muted (even if the default output changed), unless the user already did.
    private func restoreOutputIfNeeded() {
        guard !previewMode, let record = outputMuteRecord else { return }
        let device = SystemOutput.device(forUID: record.deviceUID)
        if OutputMutePolicy.shouldRestore(record: record, deviceStillMuted: device.flatMap(SystemOutput.isMuted)), let device {
            SystemOutput.setMuted(device, false)
        }
        outputMuteRecord = nil
    }
    private func recoverOutputMuteAtLaunch() {
        guard let record = outputMuteRecord else { return }
        let device = SystemOutput.device(forUID: record.deviceUID)
        if OutputMutePolicy.shouldRecoverAtLaunch(record: record, deviceStillMuted: device.flatMap(SystemOutput.isMuted), now: Date()), let device {
            SystemOutput.setMuted(device, false)
        }
        outputMuteRecord = nil
    }

    // MARK: Meetings

    /// Views that read `activeCapture` redraw as the meeting's phase changes. After each change lands, the
    /// status menu follows, the Dictation message is reset when a meeting closes, and errors are recorded.
    private func observeMeetings() {
        meetingObservers = [meetings.$phase.sink { [weak self] _ in self?.objectWillChange.send() }]
        guard !previewMode else { return }
        meetingObservers.append(meetings.$phase.map { _ in () }.merge(with: meetings.$notSaved.map { _ in () })
            .receive(on: DispatchQueue.main).sink { [weak self] in MainActor.assumeIsolated { self?.meetingStateChanged() } })
    }
    private static let meetingCaptureErrors: Set<MeetingStretchEnd> = [.speechError, .processingFellBehind, .microphoneStalled, .computerAudioStalled]
    private func meetingStateChanged() {
        let open = meetings.isOpen
        if open != meetingWasOpen {
            meetingWasOpen = open
            // Dictation's last message, such as "Microphone off.", doesn't describe a meeting; a refusal is no longer true after one.
            if open { message = "" }
            else {
                if message.isEmpty || message == Self.meetingDictationRefusal { message = canStartDictation ? "Ready when you are. Microphone off." : readinessWaitMessage }
                if notesMessage == Self.meetingNoteRefusal { notesMessage = "" }
            }
        }
        // An unload asked for while a stretch was starting, which then never claimed the session, runs now.
        if unloadAfterSession, !meetings.isCapturing, !workerBusy { requestUnload() }
        if let failure = meetings.startFailure, failure != meetingFailureSeen { lastErrorCode = "meeting_start_failed" }
        if let end = meetings.lastEnd, end != meetingEndSeen, Self.meetingCaptureErrors.contains(end) { lastErrorCode = "meeting_capture_or_inference" }
        if meetings.notSaved, !meetingSaveFailedSeen { lastErrorCode = "meeting_save_failed" }
        meetingFailureSeen = meetings.startFailure; meetingEndSeen = meetings.lastEnd; meetingSaveFailedSeen = meetings.notSaved
        notify()
    }
    /// Hourly, on an existing folder only. Open meetings are never expired, and the one shown, which may still be
    /// saving, is left alone.
    func pruneMeetings() {
        guard let meetingsBase else { return }
        let upkeep = MeetingUpkeep.prune(base: meetingsBase, retention: meetingRetention, now: Date(), keeping: Set([meetings.meeting?.id].compactMap { $0 }))
        savedMeetingCount = upkeep?.saved ?? 0; meetingsUnlistable = upkeep?.unlistable ?? false
    }
    /// Counts the meeting files without reading them, as Settings → Privacy appears and after Show in Finder.
    func refreshSavedMeetings() {
        guard !previewMode, let meetingsBase else { return }
        let count = MeetingStore(meetingsIn: meetingsBase).fileCount
        savedMeetingCount = count ?? 0; meetingsUnlistable = count == nil
    }
    /// Selects the meetings folder in Finder; nothing is opened or read. A folder removed meanwhile is recounted instead.
    func showMeetingsInFinder() {
        guard !previewMode, let meetingsBase else { return }
        let store = MeetingStore(meetingsIn: meetingsBase)
        guard store.exists else { refreshSavedMeetings(); return }
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
    /// Every meeting file it can remove, after confirmation; only while the space is hidden, where no meeting is shown or saving.
    func deleteAllMeetings() {
        guard !showsMeetingsSpace, !meetings.isOpen else { return }
        guard !previewMode, let meetingsBase else { savedMeetingCount = 0; return }
        let store = MeetingStore(meetingsIn: meetingsBase)
        do {
            if store.exists { try store.removeAll() }
            savedMeetingCount = 0; meetingsUnlistable = false; meetingsMessage = ""
            announce("Saved meetings deleted")
        } catch {
            refreshSavedMeetings()
            meetingsMessage = "Some meetings couldn’t be deleted from this Mac. Try again."
            announce(meetingsMessage)
        }
    }
    /// Quit, logout, restart or shutdown: capture stops now, before anything awaits. The task ends once the meeting
    /// is saved (true) or its save failed (false); a second request gets the same task.
    func finishMeetingForQuit() -> Task<Bool, Never> {
        if let meetingQuit { return meetingQuit }
        meetings.stopForQuit()
        let quitting = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let saved = await meetings.quit()
            meetingQuit = nil
            return saved
        }
        meetingQuit = quitting
        return quitting
    }

    // MARK: Updates

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        automaticUpdateChecks = enabled
        guard !previewMode else { return }
        UserDefaults.standard.set(enabled, forKey: "automaticUpdateChecks")
        runAutomaticUpdateCheckIfDue()
    }
    func checkForUpdates() {
        guard !previewMode, !checkingForUpdates else { return }
        checkingForUpdates = true
        Task { [weak self] in
            guard let self else { return }
            let result = await UpdateChecker.check(currentBuild: currentBuild)
            updateResult = result; checkingForUpdates = false
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            announce(updateSummary)
        }
    }
    private func runAutomaticUpdateCheckIfDue() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
        guard UpdateCheck.automaticCheckDue(enabled: automaticUpdateChecks, lastCheck: last, now: Date()) else { return }
        checkForUpdates()
    }
    var updateSummary: String {
        switch updateResult {
        case nil: return checkingForUpdates ? "Checking for updates…" : "Not checked yet."
        case .upToDate: return "Within is up to date (build \(currentBuild))."
        case .available(let release): return "\(release.title) is available."
        case .noReleases: return "No builds have been published yet."
        case .unavailable: return "Couldn’t check for updates. Try again later."
        }
    }

    // MARK: Voice notes

    @discardableResult func newNote() -> UUID {
        let note = Note(created: Date())
        notes.insert(note, at: 0); selectedNoteID = note.id; persistNote(note)
        return note.id
    }
    func updateNote(_ id: UUID, title: String? = nil, body: String? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if let title { notes[index].title = title }
        if let body { notes[index].body = body }
        notes[index].modified = Date()
        scheduleNoteSave(id)
    }
    /// Typing saves about a second after the last change instead of on every keystroke.
    private func scheduleNoteSave(_ id: UUID) {
        noteSaveTasks[id]?.cancel()
        noteSaveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            noteSaveTasks[id] = nil
            if let note = notes.first(where: { $0.id == id }) { persistEdited(note) }
        }
    }
    /// While recording, an edit save keeps the confirmed live words so it never undoes a checkpoint.
    private func persistEdited(_ note: Note) {
        var copy = note
        if recordingNoteID == note.id, !liveConfirmed.isEmpty { copy.body = NoteText.appending(liveConfirmed, to: note.body) }
        persistNote(copy)
    }
    func flushNoteEdits() {
        for (id, task) in noteSaveTasks {
            task.cancel()
            if let note = notes.first(where: { $0.id == id }) { persistEdited(note) }
        }
        noteSaveTasks.removeAll()
    }
    func deleteNote(_ id: UUID) {
        guard recordingNoteID != id else { notesMessage = "Stop recording before deleting this note."; return }
        noteSaveTasks[id]?.cancel(); noteSaveTasks[id] = nil
        notes.removeAll { $0.id == id }
        if selectedNoteID == id { selectedNoteID = notes.first?.id }
        if !previewMode {
            do { try notesStore?.delete(id) } catch { notesMessage = "This note couldn’t be deleted from disk." }
        }
        announce("Note deleted")
    }
    private func refuseDictationDuringNote() {
        message = "Stop your note recording to dictate."; notify(); announce(message)
    }
    private func refuseDictationDuringMeeting() {
        message = Self.meetingDictationRefusal; notify(); announce(message)
    }
    private func loadNotes() {
        guard let notesStore else { return }
        let loaded = notesStore.loadAll()
        notes = loaded.documents
        if loaded.unreadable > 0 { notesMessage = "\(loaded.unreadable) saved note(s) couldn’t be read and were left untouched." }
    }
    private func persistNote(_ note: Note) {
        guard !previewMode, let notesStore else { return }
        do { try notesStore.save(note); notesMessage = "" }
        catch { notesMessage = "This note couldn’t be saved on this Mac." }
    }

    /// Records into one note. Text is committed when recording stops for any reason,
    /// and a disk checkpoint including confirmed live text is written every ten seconds.
    func startNoteRecording(_ noteID: UUID) {
        guard !editingShortcut, !isRecordingNote, notes.contains(where: { $0.id == noteID }) else { return }
        guard !meetings.isOpen else { notesMessage = Self.meetingNoteRefusal; announce(notesMessage); return }
        refreshPermissions(mayRegisterShortcut: true)
        guard canStart else {
            notesMessage = phase == .recovery ? "Review your pending dictation first." : modelBusy || workerBusy ? readinessWaitMessage
                : !modelInstalled || !microphoneAllowed ? "Finish setup before recording." : !selectedInputAvailable ? "Your selected microphone is unavailable." : "Check the local speech model in Settings."
            announce(notesMessage); return
        }
        guard let id = session.begin() else { return }
        recordingNoteID = noteID; isPracticeSession = false; pendingNoteGap = nil
        liveConfirmed = ""; liveVolatile = ""; notesMessage = ""
        target?.stopObserving(); target = nil; fromHoldShortcut = false; audioFlowing = false
        workerBusy = true; message = "Preparing local speech…"; elapsed = 0; level = 0
        notify()
        worker = Task { [weak self] in
            guard let self else { return }
            var text = ""
            do {
                try await speech.prepare(directory: await store.directory, manifest: manifest)
                lastModelCheck = "passed"
                try Task.checkCancellation(); guard session.isCurrent(id) else { throw CancellationError() }
                try await speech.begin()
                try Task.checkCancellation(); guard session.isCurrent(id) else { throw CancellationError() }
                let ring = try capture.start(deviceUID: microphoneUID, limits: .note)
                let rate = capture.sampleRate
                guard session.recording(id) else { capture.stop(); throw CancellationError() }
                message = "Starting microphone…"; notify()
                startNotePulse(ring: ring, sampleRate: rate, id: id)
                text = try await speech.consume(ring, sampleRate: rate) { confirmed, volatile in
                    Task { @MainActor [weak self] in self?.noteLiveUpdate(id: id, noteID: noteID, confirmed: confirmed, volatile: volatile) }
                }
                capture.stop(); pulse?.cancel(); pulse = nil
                if ring.status == 2 { pendingNoteGap = pendingNoteGap ?? "Paused because speech processing fell behind" }
                if ring.status == 3 { pendingNoteGap = pendingNoteGap ?? "Paused at the recording limit" }
            } catch {
                capture.stop(reusingStoppedEngine: false); pulse?.cancel(); pulse = nil
                await speech.cancel()
                if error is IntegrityError { invalidateModelVerification() }
                if case SpeechFailure.partial(let partial) = error {
                    text = partial; pendingNoteGap = pendingNoteGap ?? "Paused after a speech processing error"
                } else if !(error is CancellationError) {
                    notesMessage = "Recording stopped. Check the microphone and local model, then record again."
                }
            }
            let added = commitNoteRecording(noteID: noteID, text: text)
            if session.isCurrent(id) { session.finish(id) }
            recordingNoteID = nil; liveConfirmed = ""; liveVolatile = ""; level = 0
            // Keep a specific reason (canceled, no audio) instead of claiming words were saved.
            if added { message = "Your note is saved on this Mac."; announce("Note recording stopped and saved") }
            else if !message.localizedCaseInsensitiveContains("canceled") {
                message = notesMessage.isEmpty ? "No speech was added to the note." : "Note recording stopped. Microphone off."
                announce(notesMessage.isEmpty ? message : notesMessage)
            }
            if unloadAfterSession { await speech.unload(); capture.preventReuse(); unloadAfterSession = false }
            workerBusy = false; worker = nil; notify()
        }
    }
    private func noteLiveUpdate(id: UUID, noteID: UUID, confirmed: String, volatile: String) {
        guard session.isCurrent(id), recordingNoteID == noteID else { return }
        liveConfirmed = confirmed; liveVolatile = volatile
        guard ContinuousClock.now >= lastNoteCheckpoint.advanced(by: .seconds(10)),
              var checkpoint = notes.first(where: { $0.id == noteID }) else { return }
        // Disk-only checkpoint so a crash keeps confirmed words; the in-memory body stays the user's.
        lastNoteCheckpoint = .now
        checkpoint.body = NoteText.appending(confirmed, to: checkpoint.body)
        checkpoint.modified = Date()
        persistNote(checkpoint)
    }
    @discardableResult private func commitNoteRecording(noteID: UUID, text: String) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return false }
        noteSaveTasks[noteID]?.cancel(); noteSaveTasks[noteID] = nil
        guard !TranscriptFormatting.clean(text).isEmpty else { pendingNoteGap = nil; return false }
        var body = NoteText.appending(text, to: notes[index].body)
        if let gap = pendingNoteGap, !TranscriptFormatting.clean(text).isEmpty { body += "\n\n" + NoteText.gapMarker(reason: gap) }
        pendingNoteGap = nil
        notes[index].body = body; notes[index].modified = Date()
        persistNote(notes[index])
        return true
    }
    private func startNotePulse(ring: AudioRing, sampleRate: Double, id: UUID) {
        pulse?.cancel()
        let started = ContinuousClock.now
        pulse = Task { [weak self] in
            var lastSampleCount: UInt64 = 0
            var lastAudioProgress = started
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, session.isCurrent(id), phase == .recording else { return }
                level = min(1, ring.level * 7); elapsed = Double(ring.samplesCaptured) / sampleRate
                if ring.samplesCaptured != lastSampleCount { lastSampleCount = ring.samplesCaptured; lastAudioProgress = .now }
                if !audioFlowing, ring.samplesCaptured > 0 {
                    audioFlowing = true; message = "Recording your note"; announce("Note recording started"); playCue(start: true)
                }
                if !audioFlowing, ContinuousClock.now >= started.advanced(by: .seconds(5)) {
                    notesMessage = "No audio arrived from the microphone. Check the selected input and try again."
                    stop(cause: .noAudio); return
                }
                if audioFlowing, ContinuousClock.now >= lastAudioProgress.advanced(by: .seconds(5)) {
                    pendingNoteGap = "Paused because the microphone stopped sending audio"; stop(cause: .audioStalled); return
                }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    pendingNoteGap = "Paused because microphone access changed"; stop(cause: .microphonePermission); return
                }
                if ring.status != 0 { stop(cause: ring.status == 2 ? .bufferOverflow : .durationLimit); return }
            }
        }
    }

    func chooseHistoryRetention(_ retention: HistoryRetention) {
        historyRetention = retention
        if retention == .off { clearLastDictationChange() }
        if !previewMode { UserDefaults.standard.set(retention.rawValue, forKey: "historyRetention") }
        pruneHistory()
    }
    func pruneHistory() {
        guard let retention = historyRetention else { return }
        let pruned = HistoryPolicy.prune(history, now: Date(), retention: retention)
        guard pruned != history else { return }
        history = pruned; persistHistory()
    }
    func deleteHistoryEntry(_ id: UUID) {
        history.removeAll { $0.id == id }; persistHistory(); clearLastDictationChange(); announce("Dictation deleted from history")
    }
    func clearHistory() { history = []; persistHistory(); clearLastDictationChange(); announce("History cleared") }
    func copyHistoryEntry(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        historyMessage = pasteboard.setString(entry.text, forType: .string) ? "Copied. Your clipboard may sync through macOS." : "Copy failed."
        announce(historyMessage)
    }
    private func loadHistory() {
        // Without an explicit choice, the history file is neither read nor changed.
        guard let historyStore, let retention = historyRetention else { return }
        do {
            let stored = try historyStore.load()
            history = HistoryPolicy.prune(stored, now: Date(), retention: retention)
            if history != stored { persistHistory() }
        } catch { historyMessage = "Saved history couldn’t be read. New dictations will start a fresh history." }
    }
    private func persistHistory() {
        guard !previewMode, let historyStore else { return }
        do { try historyStore.save(history); historyMessage = "" }
        catch { historyMessage = "History couldn’t be saved on this Mac. Your dictation wasn’t affected." }
    }
    /// Only confirmed insertions and explicit Copy reach history. Practice, cancel and discard never do.
    /// `original` is not saved yet: history keeps the original transcription only if the owner approves it (question 1).
    private func recordHistory(_ text: String, original: String?, practice: Bool) {
        guard !practice, let retention = historyRetention, retention.keepsHistory else { return }
        history = HistoryPolicy.adding(text, at: Date(), to: history, retention: retention)
        persistHistory()
    }
    private func notify() {
        // While a meeting is open, even paused, dictation isn't ready, so nothing says it is.
        if phase == .ready, !workerBusy, !modelBusy, message == readinessWaitMessage, !meetings.isOpen {
            message = canStartDictation ? "Ready when you are. Microphone off." : !modelVerified ? modelMessage : "Check your microphone and permissions in Settings."
            announce(message)
        }
        stateChanged?()
    }
    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private func installLifecycleObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancelForBoundary() } })
        // Its own handler, so a meeting's gap says the user switched rather than the Mac slept.
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelForBoundary(.userSwitched) }
        })
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.announceBoundaryPause() } })
        }
        // Logout, restart or shutdown: an alert would wait while capture runs, so capture stops now and the meeting is
        // finished and saved. If the logout is canceled, Within stays open with the meeting finished.
        observers.append(workspace.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.meetingNeedsSaveToQuit else { return }
                _ = self.finishMeetingForQuit()
            }
        })
        // The name of the unlock notification is UNVERIFIED; wake and becoming active again also announce.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPermissions()
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let target = self.target, app.processIdentifier != target.application.processIdentifier { target.markFocusChanged() }
            }
        })
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestUnload()
            }
        }
        memoryPressure?.resume()
    }
    @objc private func screenLocked() { cancelForBoundary() }
    @objc private func screenUnlocked() { announceBoundaryPause() }
    func cancelForBoundary(_ reason: MeetingStretchEnd = .lockOrSleep) {
        clearLastDictationChange()
        if meetings.isOpen {
            // Pause and keep: a gap marks it, nothing resumes on its own, and the models unload once the rings drain.
            if meetings.isCapturing { boundaryPause = (reason, meetings.phase == .preparing) }
            meetings.boundary(reason)
            requestUnload(); return
        }
        if isRecordingNote {
            // Pause and keep: the note keeps its words and a visible gap; Record resumes explicitly.
            pendingNoteGap = "Paused when the Mac locked or went to sleep"
            stop(cause: .systemBoundary); requestUnload(); return
        }
        // Stop audio before querying diagnostic state or invalidating the session.
        capture.stop(reusingStoppedEngine: false)
        recordStop(.systemBoundary)
        if session.interruptForSystemBoundary() { cancel() }
        else if phase == .recovery {
            recoveryActionEpoch += 1; returning = false
            target?.markFocusChanged(); dismissRecovery?()
            message = "Your pending words are still here. Review when you’re ready."; notify()
        }
        requestUnload()
    }
    /// After unlock or wake: a meeting a boundary paused says so now, once, rather than while the screen locked.
    private func announceBoundaryPause() {
        guard let pending = boundaryPause else { return }
        boundaryPause = nil
        // The stretch the boundary ended, including a rollover's; a pause or finish already under way said so itself.
        // A start the boundary stopped closed no stretch, so its own reason is used.
        let ended = meetings.lastEnd.flatMap { $0 == .lockOrSleep || $0 == .userSwitched ? $0 : nil }
        guard meetings.isOpen, let reason = ended ?? (pending.starting ? pending.reason : nil),
              let detail = MeetingGap(start: 0, end: 0, reason: reason).detail(appName: "") else { return }
        announce("Meeting notes paused: \(detail). Microphone off.")
    }
    func requestUnload() {
        capture.preventReuse()
        // An unload already running covers a second request, such as a meeting's own after a lock. A meeting between
        // stretches, such as a rollover saving before its next one, holds no session but would fail without the models.
        if workerBusy || meetings.isCapturing { if !unloading { unloadAfterSession = true }; return }
        workerBusy = true; unloading = true; unloadAfterSession = false
        worker = Task {
            await speech.unload()
            unloading = false; workerBusy = false; worker = nil; notify()
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !previewMode else { return }
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                loginEnabled = SMAppService.mainApp.status == .enabled
                loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Approve Within in System Settings → Login Items." : ""
            } catch { loginMessage = "macOS couldn’t change this preference. Try from the installed app in Applications." }
        }
    }
    func playCue(start: Bool) {
        if soundsEnabled { NSSound(named: start ? "Pop" : "Tink")?.play() }
    }
    func diagnostics() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "allowed"
        case .denied: permission = "denied"
        case .restricted: permission = "restricted"
        case .notDetermined: permission = "not_requested"
        @unknown default: permission = "unknown"
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported"
        #endif
        return DiagnosticsReport(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", architecture: architecture,
            microphonePermission: permission, accessibilityPermission: accessibilityAllowed, shortcutRegistered: shortcutAvailable,
            microphoneSelection: microphoneUID.isEmpty ? "system_default" : "selected_device_identity_omitted",
            modelInstalled: modelInstalled, modelRevision: manifest.revision, lastModelCheck: lastModelCheck,
            lastErrorCode: lastErrorCode, lastRecordingStop: stopDiagnostics.lastStop,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            lastRecordingStartup: startupDiagnostics.latest, lastMeeting: meetingDiagnostic()).preview()
    }
    /// Closed values only, and nil until a meeting in this run ended a stretch or failed to start.
    private func meetingDiagnostic() -> MeetingDiagnostic? {
        guard let end = meetings.lastEnd ?? meetings.startFailure else { return nil }
        let supported: Bool
        if #available(macOS 14.2, *) { supported = true } else { supported = false }
        return MeetingDiagnostic(lastStretchEnd: end, sources: meetings.sourceStates[.others] == nil ? .microphone : .microphoneAndApp,
            youState: meetings.sourceStates[.you] ?? .off, othersState: meetings.sourceStates[.others] ?? .off,
            startFailure: meetings.startFailure, computerAudioSupported: supported, remindersOn: false, lastSaveFailed: meetings.notSaved)
    }
    /// Synthetic entries for previews and native checks only.
    static let previewWords = PersonalDictionary(entries: [
        DictionaryEntry(heardAs: ["gira", "jeera"], writeAs: "Jira", created: Date(timeIntervalSince1970: 1_800_000_000)),
        DictionaryEntry(heardAs: ["shivon", "chevonne"], writeAs: "Siobhan", created: Date(timeIntervalSince1970: 1_800_000_001)),
        DictionaryEntry(heardAs: ["cube cuddle", "cube control"], writeAs: "kubectl", created: Date(timeIntervalSince1970: 1_800_000_002))
    ])
    /// The Dictionary page's synthetic words: one turned off, and one from a hand-edited file that repeats an earlier word's phrase.
    static let previewPageWords = PersonalDictionary(entries: previewWords.entries + [
        DictionaryEntry(heardAs: ["postgres q l", "gira"], writeAs: "PostgreSQL", created: Date(timeIntervalSince1970: 1_800_000_003)),
        DictionaryEntry(heardAs: ["made ordinarily"], writeAs: "Made Ordinary", enabled: false, created: Date(timeIntervalSince1970: 1_800_000_004))
    ])
    func configurePreview(_ state: String) {
        guard previewMode else { return }
        modelBusy = false; workerBusy = false
        mode = .toggle; dictationShortcut = .controlShiftD; microphoneUID = "preview-input"
        historyRetention = nil; history = []
        automaticUpdateChecks = nil; updateResult = nil
        showsPersonalDictionary = false; dictionaryHasSetAside = false; dictionaryMessage = ""; replaceDictionary(with: .missing)
        lastChangeExpiry?.cancel(); lastDictationChange = nil; lastChangeCopyFailed = false; lastChangeExpiredWhileFocused = false; practiceChange = nil
        // Meeting visibility and retention are forced in memory only; the defaults are never written or read here.
        showsMeetingsSpace = false; savedMeetingCount = 0; meetingsUnlistable = false; meetingsMessage = ""; meetingRetention = .untilDeleted
        meetings.configurePreview(nil, phase: .idle)
        if state.hasPrefix("home-meeting") || state == "notes-meeting" {
            showsMeetingsSpace = true
            let phase: MeetingLifecycle.Phase = switch state {
            case "home-meeting-paused", "notes-meeting": .paused
            case "home-meeting-finishing": .finishing
            // Native checks only: a stretch starting or rolling over, before it claims the session.
            case "home-meeting-between-stretches": .preparing
            default: .recording
            }
            meetings.configurePreview(Self.previewMeeting, phase: phase, sourceStates: phase == .recording ? [.you: .live, .others: .live] : [.you: .off, .others: .off],
                                      elapsed: 754, needsAcknowledgment: phase == .paused)
        }
        if state.hasPrefix("settings-privacy-saved-meetings") { savedMeetingCount = 3 }
        if state == "settings-privacy-saved-meetings-days30" { meetingRetention = .days30 }
        if state == "settings-privacy-meetings-unlistable" { meetingsUnlistable = true }
        if state.hasSuffix("-dictionary") { previewDictionary(.loaded(Self.previewWords)) }
        if state == "dictionary" || state == "dictionary-recording" { previewDictionary(.loaded(Self.previewPageWords)) }
        if state == "dictionary-empty" { previewDictionary(.missing) }
        if state == "dictionary-unreadable" || state == "dictation-dictionary-unreadable" { previewDictionary(.unreadable) }
        if state == "update-available" {
            automaticUpdateChecks = true
            updateResult = .available(ReleaseInfo(tag: "v0.1.0-build12", title: "Within 0.1.0 (build 12)",
                notes: "Check for updates from Within, and a weekly check you can turn on.", pageURL: URL(string: "https://github.com/madeordinary/within/releases")!,
                downloadURL: URL(string: "https://github.com/madeordinary/within/releases/download/v0.1.0-build12/Within-0.1.0-build12.dmg"),
                build: 12, prerelease: true))
        }
        notes = []; selectedNoteID = nil; recordingNoteID = nil; liveConfirmed = ""; liveVolatile = ""
        if state == "notes" || state == "note-recording" || state == "note-preparing" || state == "notes-meeting" {
            // Synthetic sample notes only; previews never read or write the Notes folder.
            let now = state == "notes-meeting" ? Date(timeIntervalSince1970: 1_800_000_000) : Date()
            var plan = Note(title: "Weekend planning", created: now.addingTimeInterval(-3 * 3600), body: "Pick up the bike from the shop on Saturday morning.\n\nAsk whether the Sunday hike still works if it rains. Maybe move it to the afternoon.")
            plan.modified = now.addingTimeInterval(-20 * 60)
            var ideas = Note(created: now.addingTimeInterval(-2 * 86_400), body: "Ideas for the onboarding flow: fewer words, show the shortcut as real keys, and let people try it before choosing settings.")
            ideas.modified = now.addingTimeInterval(-2 * 86_400)
            notes = [plan, ideas]; selectedNoteID = plan.id
            if state == "note-preparing" { recordingNoteID = plan.id; _ = session.begin() }
            if state == "note-recording" {
                recordingNoteID = plan.id
                let id = session.begin()!; _ = session.recording(id); elapsed = 83; level = 0.4; audioFlowing = true
                liveConfirmed = "Also remember to book the table for Friday, somewhere quiet enough to talk,"
                liveVolatile = "and ask Sam if the"
            }
        }
        if state == "history" || state == "history-empty" { historyRetention = .week }
        if state == "history-off" { historyRetention = .off }
        if state == "history" {
            // Synthetic sample text only; previews never read the history file.
            let now = Date()
            let samples: [(String, TimeInterval)] = [
                ("Let’s move the design review to Thursday afternoon so everyone can join.", 12 * 60),
                ("Add a short note to the README explaining how to download the speech model.", 58 * 60),
                ("Refactor the settings sidebar so each section keeps its own scroll position, then run the native checks again.", 3 * 3600),
                ("Groceries: oat milk, lemons, rice, and something for Saturday dinner.", 26 * 3600),
                ("Thanks for the notes — I’ll send an updated draft tomorrow morning.", 29 * 3600),
                ("Remember to ask about the older-Mac test machine.", 4 * 86_400)
            ]
            history = samples.map { HistoryEntry(date: now.addingTimeInterval(-$0.1), text: $0.0) }
        }
        devices = [MicrophoneDevice(id: "preview-input", objectID: 0, name: "Built-in Microphone"),
                   MicrophoneDevice(id: "preview-external", objectID: 1, name: "USB Microphone")]
        modelInstalled = state != "setup"; microphoneAllowed = state != "setup"; accessibilityAllowed = state != "setup"
        modelVerified = modelInstalled && state != "model-error"
        if state == "setup" { setupComplete = false }
        modelMessage = "One local model. No account."; shortcutAvailable = true
        if state == "model-error" { modelMessage = "Model unavailable. Remove it and download a fresh copy." }
        if state == "missing-input" { devices = [] }
        if state == "permission" { accessibilityAllowed = false }
        if state == "practice" || state == "practice-dictionary" { practiceText = "A little more room for an ordinary idea."; isPracticeSession = true }
        if state == "practice-dictionary" { appendPractice(dictionaryMatcher.apply(to: "I moved the ticket to gira and asked shivon to review it.")) }
        if state == "inserted-dictionary" {
            let result = dictionaryMatcher.apply(to: "Ask shivon to move the gira ticket, run cube cuddle apply, and loop in chevonne.")
            message = Self.insertedMessage(changes: result.changes.count)
            setLastDictationChange(LastDictationChange(sessionID: UUID(), original: result.original, changes: result.changes, time: Date(timeIntervalSince1970: 1_800_000_000)))
        }
        if state == "practice-unloading" { isPracticeSession = true; workerBusy = true }
        if state == "model-busy" { modelBusy = true }
        if state == "practice-recording" || state == "practice-transcribing" {
            isPracticeSession = true; workerBusy = true
            let id = session.begin()!; _ = session.recording(id)
            if state == "practice-transcribing" { _ = session.stopped(id) }
        }
        if state == "recovery" || state == "practice-recovery" || state == "recovery-dictionary" {
            isPracticeSession = state == "practice-recovery"
            let words = state == "recovery-dictionary" ? "I moved the ticket to gira and asked shivon to review it."
                : "The best ideas often start as a few ordinary words. Let’s make a little room for them."
            // The same step as a dictation result: with no dictionary in use, the words are unchanged.
            let id = session.begin()!; _ = session.recover(dictionaryMatcher.apply(to: words), id: id)
            recoveryReason = .focusChanged; recoveryDetail = RecoveryReason.focusChanged.explanation
        } else if state == "recording" || state == "dictionary-recording" {
            let id = session.begin()!; _ = session.recording(id); elapsed = 12; level = 0.45; audioFlowing = true
        }
        if meetings.isOpen {
            // A capturing meeting holds the session as each of its stretches does, transcribing while it drains.
            if meetings.isCapturing, state != "home-meeting-between-stretches" {
                let id = session.begin()!; _ = session.recording(id); workerBusy = true
                if meetings.phase != .recording { _ = session.stopped(id) }
            }
            message = state == "home-meeting-refused" ? Self.meetingDictationRefusal : ""
        }
        notify()
    }
    /// A synthetic meeting for previews and native checks only.
    static let previewMeeting = Meeting(id: UUID(uuidString: "6F1D2C3B-4A59-4E68-9F70-8192A3B4C5D6")!, title: "Weekly planning",
        created: Date(timeIntervalSince1970: 1_800_000_000), appName: "Zoom",
        segments: [MeetingSegment(source: .others, offset: 12, text: "Thanks for joining, everyone."),
                   MeetingSegment(source: .you, offset: 20, text: "Happy to be here.")],
        stretches: [MeetingStretch(start: 0, sources: [.you, .others])])
    func shutdown() {
        // Before anything else, so quitting never leaves a meeting source running.
        meetings.emergencyStop()
        flushNoteEdits(); cancel(cause: .shutdown); clearLastDictationChange(); practiceChange = nil
        restoreOutputIfNeeded(); modelTask?.cancel(); shortcut.shutdown()
    }
}

enum CaptureActivity { case none, dictation, note, meeting }

/// A meeting's stretches hold the one session the way a note recording does, so every guard on `phase` and
/// `workerBusy` applies while it captures.
extension AppModel: MeetingHost {
    var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var modelManifest: ModelManifest { manifest }
    func modelDirectory() async -> URL { await store.directory }

    /// What holds capture, in order, before whether Within is ready.
    func meetingStartRefusal() -> String? {
        if isRecordingNote { return "Stop your note recording to start meeting notes." }
        if phase == .preparing || phase == .recording || phase == .transcribing { return "Finish dictating to start meeting notes." }
        if phase == .recovery { return "Review your pending dictation first." }
        if hasActivePracticeSession || editingShortcut { return "Finish practice or the shortcut change first." }
        refreshPermissions(mayRegisterShortcut: true)
        guard !canStart else { return nil }
        return modelBusy || workerBusy ? readinessWaitMessage : !modelInstalled || !microphoneAllowed ? "Finish setup before recording."
            : !selectedInputAvailable ? "Your selected microphone is unavailable." : "Check the local speech model in Settings."
    }

    func claimCapture() -> UUID? {
        guard !workerBusy, !modelBusy, let id = session.begin() else { return nil }
        // As for a note: no practice session, destination or hold gesture belongs to a meeting.
        isPracticeSession = false
        target?.stopObserving(); target = nil; fromHoldShortcut = false; audioFlowing = false
        workerBusy = true; elapsed = 0; level = 0
        notify()
        return id
    }
    func captureRecording(_ id: UUID) -> Bool {
        guard session.recording(id) else { return false }
        notify()
        return true
    }
    func captureDraining(_ id: UUID) {
        _ = session.stopped(id)
        notify()
    }
    func releaseCapture(_ id: UUID) async {
        if session.isCurrent(id) { session.finish(id) }
        if unloadAfterSession { await speech.unload(); capture.preventReuse(); unloadAfterSession = false }
        workerBusy = false; notify()
    }
}

/// In memory only: what Copy original transcription copies and the pairs the row shows, never the inserted text.
struct LastDictationChange: Equatable {
    let sessionID: UUID
    let original: String
    let changes: [DictionaryChange]
    let time: Date
}

/// The last practice result the dictionary changed. Restorable until the practice text is edited.
struct PracticeChange: Equatable {
    let separator: String
    let text: String
    let original: String
    let changes: [DictionaryChange]
    var restorable = true
}
