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
    /// controller, no store and no Meetings space; only its own Start, Continue and Resume ever start capture.
    @Published private(set) var showsMeetingsSpace: Bool
    /// Views observe it directly; a nested object doesn't republish through this one.
    private(set) var meetings = MeetingController(preview: true)
    /// Meeting files in `Meetings.noindex`, kept by upkeep whatever the default says.
    @Published private(set) var savedMeetingCount = 0
    /// That folder exists but couldn't be listed, so the count can't be trusted.
    @Published private(set) var meetingsUnlistable = false
    @Published private(set) var meetingsMessage = ""
    /// The stored `meetingRetention`; unset keeps meetings until deleted. Written only by a choice in Settings → Meetings.
    @Published private(set) var meetingRetention: DocumentRetention
    /// The stored `meetingBackups`: meetings stay out of Time Machine unless the user turns this on (absent is off).
    /// Applied to the folder at every launch, whatever the developer default says.
    @Published private(set) var meetingBackups: Bool
    /// The switch was on before it was turned off, so Time Machine may still hold copies. Only the switch writes
    /// `meetingBackups`, and its first write is `true`, so a stored `false` means exactly this.
    @Published private(set) var meetingBackupsWereIncluded: Bool
    /// Why the backup choice couldn't be applied to the meetings folder; empty once it was.
    @Published private(set) var meetingBackupMessage = ""
    private var meetingBackupApply: Task<Void, Never>?
    /// A quit, logout, restart or shutdown saving the meeting; one at a time.
    private var meetingQuit: Task<Bool, Never>?
    /// Where the Meetings space is. An open meeting is always shown, whatever this says.
    @Published var meetingsRoute = MeetingsRoute.library
    /// Saved meetings for the library, newest first: read only while the space is visible, synthetic in previews.
    @Published private(set) var meetingLibrary: [Meeting] = []
    @Published private(set) var meetingLibraryUnreadable = 0
    /// Recovered at launch and not yet opened in this run: the sidebar's "to review".
    @Published private(set) var meetingsToReview: Set<UUID> = []
    /// Recovered-meeting banners closed in this run.
    @Published private(set) var closedRecoveryNotices: Set<UUID> = []
    /// The shown meeting reads as originally transcribed instead of in your spellings; reset for each meeting.
    @Published private(set) var showingOriginalTranscription = false
    /// Include Zoom's sound in the next start; off at every launch, and remembered only for this run.
    @Published var includeZoomSound = false { didSet { if includeZoomSound { zoomSoundEverIncluded = true } } }
    /// Why the last new meeting didn't start, shown in setup until it is left.
    @Published private(set) var meetingSetupFailure: String?
    /// Where focus goes next in the Meetings space; the view that can take it clears it.
    @Published var meetingsFocusRequest: MeetingsFocus?
    /// Including an app's sound needs macOS 14.2; a preview can say otherwise to show the microphone-only setup.
    @Published private(set) var meetingAppSoundSupported = AppModel.appSoundAvailable
    /// The stored `meetingReminders`; unset is off. Written only by Settings → Meetings' switch.
    @Published private(set) var meetingReminders: Bool
    /// Opt-in reminders: the only reader of which apps use a microphone, and only while they are on and the space is
    /// visible. A preview's has no reader. Views observe it directly.
    private(set) var meetingWatcher = MeetingWatcher(read: nil)
    private var meetingWatcherObserver: AnyCancellable?
    /// Zoom's sound was turned on at least once in this run, in setup or by the reminder's first-time choice. In memory
    /// only, like the switch: until then the reminder explains it first and starts with the microphone alone.
    @Published private(set) var zoomSoundEverIncluded = false
    /// The shown reminder's sources; its link changes this start only.
    @Published private(set) var reminderIncludesZoomSound = false
    /// The reminder's first-time explanation is showing, after Start notes.
    @Published private(set) var reminderExplaining = false
    /// The menu path's sheet over Within's window; it closes whenever its reminder does.
    @Published private(set) var meetingStartSheet = false
    /// The dictation shortcut was refused during a meeting a moment ago; the capsule says so for a few seconds.
    @Published private(set) var meetingDictationRefused = false
    private var dictationRefusalReset: Task<Void, Never>?
    /// The acknowledgment epoch a start from the reminder began in, until that meeting closes.
    private var reminderStartEpoch: Int?
    /// Bumped by each quit that starts saving the meeting, so a start the reminder asked for before it never happens after.
    private var meetingQuitRequests = 0
    /// Each saved turn in your spellings, kept while its text and the dictionary stay the same.
    let meetingSpellings = MeetingSpellingCache()
    /// Bumped whenever the matcher may have changed.
    private(set) var dictionaryRevision = 0
    private var meetingsDeleted: Set<UUID> = []
    private var meetingShownID: UUID?
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
    var showMeetings: (() -> Void)?
    /// Brings Within's window forward without changing its page.
    var showWindow: (() -> Void)?
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
    static let dictationRefusalShown: Duration = .seconds(4)
    /// As setup says when a start fails for no reason it can name.
    static let meetingStartFailed = "Meeting notes couldn’t start. Try again."
    static let meetingStartSheetBlocked = "Close the open dialog in Within, then choose Start Zoom Notes… again."
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
        meetingBackups = Self.storedMeetingBackups(UserDefaults.standard.object(forKey: "meetingBackups"))
        meetingBackupsWereIncluded = Self.meetingBackupsWereIncluded(UserDefaults.standard.object(forKey: "meetingBackups"))
        meetingReminders = UserDefaults.standard.object(forKey: "meetingReminders") as? Bool ?? false
        observeMeetings()
        observeMeetingWatcher()
        if preview { return }
        if dictionaryFixture { openDictionary(base); return }
        // Upkeep runs whatever the default says; only use of meetings waits for it.
        meetingsBase = base
        let upkeep = MeetingUpkeep.atLaunch(base: base, retention: meetingRetention, excludedFromBackup: !meetingBackups, now: Date())
        savedMeetingCount = upkeep?.saved ?? 0; meetingsUnlistable = upkeep?.unlistable ?? false
        meetingsToReview = Set(upkeep?.recoveredIDs ?? [])
        if upkeep?.backupFailed == true { meetingBackupMessage = Self.meetingBackupFailure }
        if showsMeetingsSpace {
            meetings = MeetingController(speech: speech, host: self, store: meetingStore(base)) { [weak self] app in
                guard let self else { return [] }
                var sources: [MeetingAudioSource] = [MicrophoneSource(capture: capture) { [weak self] in self?.microphoneUID ?? "" }]
                if let app, #available(macOS 14.2, *) { sources.append(AppAudioSource(app: app)) }
                return sources
            }
            observeMeetings()
            meetingWatcher = MeetingWatcher {
                MeetingSourceAudit.audioClientReads += 1
                return SystemOutput.audioClients()
            }
            observeMeetingWatcher()
            updateMeetingWatcher()
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
    /// Privacy & Security, where macOS lists System Audio Recording; Within can't read that permission.
    func openPrivacySettings() { if !previewMode { openSystemSettings("Privacy") } }
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
        meetingWatcher.captureStarted()
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
        dictionaryRevision += 1
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
        meetingObservers.append(meetings.$phase.map { _ in () }.merge(with: meetings.$notSaved.map { _ in () }, meetings.$meeting.map { $0?.id }.removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main).sink { [weak self] in MainActor.assumeIsolated { self?.meetingStateChanged() } })
        // The status item says when the meeting app goes quiet, which changes no phase.
        meetingObservers.append(meetings.$sourceStates.map { $0[.others] }.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.stateChanged?() } })
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
        // The space shows an open meeting; one that ended without a record goes back to setup with the reason, or to the library.
        if open { meetingsRoute = .meeting }
        else if meetingsRoute == .meeting, meetings.meeting == nil, !meetings.deletionPending {
            meetingSetupFailure = meetings.startFailure.map { MeetingWords.startFailure($0, appName: MeetingApp.zoom.name) }
                ?? (meetings.refusal == MeetingController.notSavedMessage ? MeetingWords.startNotSaved : nil)
            meetingsRoute = meetingSetupFailure == nil ? .library : .setup
        }
        // The controller lets go of a meeting only once its file is gone: a discard, a delete, or a start that kept nothing.
        if meetings.meeting == nil, let shown = meetingShownID { forgetMeeting(shown) }
        meetingShownID = meetings.meeting?.id
        keepShownMeetingInLibrary()
        if let failure = meetings.startFailure, failure != meetingFailureSeen { lastErrorCode = "meeting_start_failed" }
        if let end = meetings.lastEnd, end != meetingEndSeen, Self.meetingCaptureErrors.contains(end) { lastErrorCode = "meeting_capture_or_inference" }
        if meetings.notSaved, !meetingSaveFailedSeen { lastErrorCode = "meeting_save_failed" }
        meetingFailureSeen = meetings.startFailure; meetingEndSeen = meetings.lastEnd; meetingSaveFailedSeen = meetings.notSaved
        reminderStartClosed(failure: meetingSetupFailure)
        notify()
    }
    // MARK: Meetings space

    static var appSoundAvailable: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    /// Reads the saved meetings off the main actor, only while the space is visible and never in a preview. A crash's
    /// staging files were swept at launch; any a save is writing now are left alone.
    func loadMeetingLibrary() {
        guard showsMeetingsSpace, !previewMode, let meetingsBase else { return }
        let store = meetingStore(meetingsBase)
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { store.loadAll(sweepingStaging: false) }.value
            guard let self else { return }
            meetingLibrary = Self.newestFirst(loaded.documents.filter { !self.meetingsDeleted.contains($0.id) })
            meetingLibraryUnreadable = loaded.unreadable; meetingsUnlistable = loaded.unlistable
            // "To review" counts only meetings still here, such as after retention deleted one; a folder that couldn't be listed proves nothing.
            if !loaded.unlistable { meetingsToReview.formIntersection(meetingLibrary.map(\.id)) }
            keepShownMeetingInLibrary()
        }
    }
    private static func newestFirst(_ meetings: [Meeting]) -> [Meeting] { meetings.sorted { $0.created > $1.created } }
    /// The controller's copy is the truth for the meeting it shows; the library keeps one for its row and search.
    private func keepShownMeetingInLibrary() {
        guard showsMeetingsSpace, let shown = meetings.meeting, !meetingsDeleted.contains(shown.id) else { return }
        if let index = meetingLibrary.firstIndex(where: { $0.id == shown.id }) {
            if meetingLibrary[index] != shown { meetingLibrary[index] = shown }
        } else { meetingLibrary = Self.newestFirst(meetingLibrary + [shown]) }
    }
    private func forgetMeeting(_ id: UUID) {
        meetingsDeleted.insert(id); meetingLibrary.removeAll { $0.id == id }
        meetingsToReview.remove(id); closedRecoveryNotices.remove(id)
    }
    /// The library. While a meeting is open the space keeps showing it, so this does nothing.
    func showAllMeetings() {
        guard !meetings.isOpen, !meetings.deletionPending else { return }
        keepShownMeetingInLibrary()
        meetingSetupFailure = nil
        meetingsFocusRequest = meetingsRoute == .meeting ? meetings.meeting.map { .row($0.id) } ?? .newMeeting : .newMeeting
        meetingsRoute = .library
    }
    /// Setup for a new meeting. Nothing starts until its Start meeting.
    func newMeeting() {
        guard showsMeetingsSpace, !meetings.isOpen, !meetings.deletionPending else { return }
        keepShownMeetingInLibrary()
        meetingSetupFailure = nil
        meetingsRoute = .setup
    }
    /// Shows a saved meeting; never starts anything. Refused while another is open, or one shown is held in memory only.
    @discardableResult func openMeeting(_ id: UUID) -> Bool {
        guard showsMeetingsSpace, !meetings.isOpen,
              let meeting = meetings.meeting?.id == id ? meetings.meeting : meetingLibrary.first(where: { $0.id == id }) else { return false }
        keepShownMeetingInLibrary()
        guard meetings.show(meeting) else { return false }
        if meetings.meeting?.id != id { return false }
        showingOriginalTranscription = false; meetingsToReview.remove(id)
        meetingsRoute = .meeting; meetingsFocusRequest = .title
        return true
    }
    private var meetingApp: MeetingApp? { includeZoomSound && meetingAppSoundSupported ? .zoom : nil }
    /// Setup's Start meeting: a new meeting with the sources chosen there, saved before anything starts.
    @discardableResult func startMeeting(title: String, acknowledged: Bool) -> Bool {
        guard showsMeetingsSpace, !meetings.isOpen else { return false }
        keepShownMeetingInLibrary()
        guard meetings.start(title: title, app: meetingApp, acknowledged: acknowledged) else { return false }
        meetingSetupFailure = nil; showingOriginalTranscription = false
        meetingsRoute = .meeting; meetingsFocusRequest = .notes
        return true
    }
    /// What a Continue includes: Zoom's sound only for a meeting that already included it, since a microphone-only
    /// meeting's labels and export say the microphone alone.
    var meetingContinueApp: MeetingApp? { meetings.meeting?.includesAppSound == true ? meetingApp : nil }
    /// "Continue this meeting" on the shown one, with its own acknowledgment and the sources chosen for it.
    @discardableResult func continueMeeting(acknowledged: Bool) -> Bool {
        guard showsMeetingsSpace, let id = meetings.meeting?.id,
              meetings.continueMeeting(app: meetingContinueApp, acknowledged: acknowledged) else { return false }
        meetingsToReview.remove(id); meetingsFocusRequest = .notes
        return true
    }
    @discardableResult func resumeMeeting(acknowledged: Bool, microphoneOnly: Bool = false) -> Bool {
        meetings.resume(acknowledged: acknowledged, microphoneOnly: microphoneOnly)
    }
    /// Stops capture, drains and saves; focus then goes to Export.
    @discardableResult func finishMeeting() async -> Bool {
        let finished = await meetings.finish()
        keepShownMeetingInLibrary()
        if finished { meetingsFocusRequest = .export }
        return finished
    }
    @discardableResult func discardMeeting() async -> Bool {
        let id = meetings.meeting?.id
        guard await meetings.discard() else { return false }
        if let id { forgetMeeting(id) }
        meetingsRoute = .library; meetingsFocusRequest = .newMeeting
        return true
    }
    /// Deletes a finished meeting after its confirmation: the one shown, or a library row, which is shown first.
    @discardableResult func deleteMeeting(_ id: UUID) async -> Bool {
        guard !meetings.isOpen else { return false }
        if meetings.meeting?.id != id {
            guard let meeting = meetingLibrary.first(where: { $0.id == id }), meetings.show(meeting), meetings.meeting?.id == id else { return false }
        }
        let rows = meetingLibrary.map(\.id)
        guard await meetings.delete() else { return false }
        forgetMeeting(id)
        // The row after it, or the one before when it was last.
        let next = rows.firstIndex(of: id).flatMap { index in rows.indices.contains(index + 1) ? rows[index + 1] : index > 0 ? rows[index - 1] : nil }
        meetingsRoute = .library; meetingsFocusRequest = next.map { .row($0) } ?? .newMeeting
        return true
    }
    /// Try again after a failed save, or after a discard or delete that couldn't remove the file.
    func retryMeeting() async {
        let id = meetings.meeting?.id, removing = meetings.deletionPending
        guard await meetings.tryAgain(), removing, let id else { keepShownMeetingInLibrary(); return }
        forgetMeeting(id)
        meetingsRoute = .library; meetingsFocusRequest = .newMeeting
    }
    func closeRecoveryNotice(_ id: UUID) { closedRecoveryNotices.insert(id); meetingsFocusRequest = .firstTurn }
    func setShowingOriginalTranscription(_ showing: Bool) {
        guard showing != showingOriginalTranscription else { return }
        showingOriginalTranscription = showing
        announce(showing ? "Showing original transcription" : "Showing your spellings")
    }
    /// A saved turn in your spellings from the current dictionary.
    func meetingTurn(_ segment: MeetingSegment) -> DictionaryResult {
        meetingSpellings.turn(segment, dictionary: dictionaryMatcher, revision: dictionaryRevision)
    }
    /// What the meeting screen shows for a saved turn.
    func meetingTurnText(_ segment: MeetingSegment) -> String { showingOriginalTranscription ? segment.text : meetingTurn(segment).text }
    /// Turns the dictionary changes in the shown meeting; zero with the dictionary off or empty.
    var meetingFixedTurns: Int {
        guard let meeting = meetings.meeting, !dictionaryMatcher.isEmpty else { return 0 }
        return meeting.segments.filter { meetingTurn($0).changed }.count
    }
    /// Library rows matching a search: title, notes, and each turn as transcribed or in your spellings.
    func searchMeetings(_ query: String) -> [UUID] {
        MeetingSearch.matching(meetingLibrary, query: query, dictionary: dictionaryMatcher).map(\.id)
    }
    /// The same search off the main actor, since a library of long meetings takes seconds to search: nil once a newer
    /// search cancels it, checked between meetings.
    func findMeetings(_ query: String) async -> [UUID]? {
        guard !Task.isCancelled else { return nil }
        let library = meetingLibrary, dictionary = dictionaryMatcher
        let search = Task.detached(priority: .userInitiated) { () -> [UUID]? in
            var found: [UUID] = []
            for meeting in library {
                if Task.isCancelled { return nil }
                if !MeetingSearch.matching([meeting], query: query, dictionary: dictionary).isEmpty { found.append(meeting.id) }
            }
            return found
        }
        return await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
    }
    /// The shown meeting as Markdown for Export: your spellings, or the original transcription when asked; never both.
    func meetingMarkdown(useOriginalTranscription: Bool) -> String? {
        meetings.meeting.map { MeetingExport.markdown($0, dictionary: dictionaryMatcher, useOriginalTranscription: useOriginalTranscription) }
    }
    /// A library row's state in words: the open meeting's, or a meeting Within stopped during.
    func meetingBadge(_ meeting: Meeting) -> String? {
        if meetings.isOpen, meetings.meeting?.id == meeting.id { return meetings.phase == .paused ? "Paused" : "In progress" }
        return meeting.recovered ? "Recovered" : nil
    }
    /// What keeps a meeting from starting, in `meetingStartRefusal()`'s words, without refreshing anything; for views.
    var meetingStartBlocker: String? { meetingCaptureHolder ?? meetingReadinessRefusal }
    /// The shown meeting is held in memory only, so no other meeting starts or opens until its Try again succeeds.
    var meetingHeldMessage: String? {
        meetings.deletionPending ? MeetingController.notDeletedMessage : meetings.notSaved ? MeetingController.notSavedMessage : nil
    }
    static let meetingNotice = "I'm taking private transcribed notes of this call on my Mac."
    /// Copy notice: the sentence goes to the clipboard only on this click and is never posted anywhere by Within.
    @discardableResult func copyMeetingNotice(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let copied = pasteboard.setString(Self.meetingNotice, forType: .string)
        announce(copied ? "Notice copied" : "Copy failed")
        return copied
    }

    /// Hourly, on an existing folder only. Open meetings are never expired, and the one shown, which may still be
    /// saving, is left alone.
    func pruneMeetings() {
        guard let meetingsBase else { return }
        let upkeep = MeetingUpkeep.prune(base: meetingsBase, retention: meetingRetention, excludedFromBackup: !meetingBackups, now: Date(),
                                         keeping: Set([meetings.meeting?.id].compactMap { $0 }))
        savedMeetingCount = upkeep?.saved ?? 0; meetingsUnlistable = upkeep?.unlistable ?? false
        // The library drops what was deleted.
        if (upkeep?.pruned ?? 0) > 0 { loadMeetingLibrary() }
    }
    /// Counts the meeting files without reading them, as Settings → Privacy appears and after Show in Finder.
    func refreshSavedMeetings() {
        guard !previewMode, let meetingsBase else { return }
        let count = meetingStore(meetingsBase).fileCount
        savedMeetingCount = count ?? 0; meetingsUnlistable = count == nil
    }
    /// Selects the meetings folder in Finder; nothing is opened or read. A folder removed meanwhile is recounted instead.
    func showMeetingsInFinder() {
        guard !previewMode, let meetingsBase else { return }
        let store = meetingStore(meetingsBase)
        guard store.exists else { refreshSavedMeetings(); return }
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
    /// Every meeting file it can remove, after confirmation; only while the space is hidden, where no meeting is shown or saving.
    func deleteAllMeetings() {
        guard !showsMeetingsSpace, !meetings.isOpen else { return }
        guard !previewMode, let meetingsBase else { savedMeetingCount = 0; return }
        let store = meetingStore(meetingsBase)
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
    // MARK: Meetings settings

    /// The meetings folder with the user's backup choice, for every store this model builds.
    private func meetingStore(_ base: URL) -> MeetingStore { MeetingStore(meetingsIn: base, excludedFromBackup: !meetingBackups) }
    /// `meetingBackups` as stored: only a real `true` includes meetings in backups.
    static func storedMeetingBackups(_ value: Any?) -> Bool { value as? Bool ?? false }
    /// Any stored value other than `true` was written after the switch was on, as it starts absent.
    static func meetingBackupsWereIncluded(_ value: Any?) -> Bool { value != nil && !storedMeetingBackups(value) }
    static let meetingBackupFailure = "The meetings folder’s backup setting couldn’t be changed."
    /// What the copy can say about Time Machine and the meetings folder.
    enum MeetingBackupStatus: Equatable {
        /// Out of Time Machine since the folder was made.
        case excluded
        case included
        /// Out of new Time Machine backups; ones made while the switch was on may keep copies.
        case excludedAfterIncluded
        /// The choice couldn't be applied to the folder, so neither is claimed.
        case unconfirmed
    }
    var meetingBackupStatus: MeetingBackupStatus {
        !meetingBackupMessage.isEmpty ? .unconfirmed : meetingBackups ? .included : meetingBackupsWereIncluded ? .excludedAfterIncluded : .excluded
    }
    /// Settings → Meetings' retention, set only by the user's choice there; expired meetings are deleted at once.
    func chooseMeetingRetention(_ retention: DocumentRetention) {
        guard showsMeetingsSpace, retention != meetingRetention else { return }
        meetingRetention = retention
        guard !previewMode else { return }
        UserDefaults.standard.set(retention.rawValue, forKey: "meetingRetention")
        pruneMeetings()
    }
    /// How many saved meetings `retention` would delete now, read from the folder off the main actor so a library
    /// not loaded yet never counts as empty. The shown meeting is kept, as pruning keeps it.
    func meetingsExpiring(under retention: DocumentRetention, now: Date = Date()) async -> Int {
        guard showsMeetingsSpace, retention.interval != nil else { return 0 }
        let keeping = meetings.meeting?.id
        let documents: [Meeting]
        if previewMode { documents = meetingLibrary } else {
            guard let meetingsBase else { return 0 }
            let store = meetingStore(meetingsBase)
            documents = await Task.detached(priority: .userInitiated) { store.loadAll(sweepingStaging: false).documents }.value
        }
        return retention.expired(documents, now: now).filter { $0 != keeping }.count
    }
    /// Settings → Meetings' backup switch, only while the space is visible.
    func setMeetingBackups(_ included: Bool) {
        guard showsMeetingsSpace, included != meetingBackups else { return }
        meetingBackups = included; meetingBackupMessage = ""
        if !included { meetingBackupsWereIncluded = true }
        guard !previewMode else { return }
        UserDefaults.standard.set(included, forKey: "meetingBackups")
        applyMeetingBackups()
    }
    /// The stored choice, applied to the folder that exists, in order. While the space is visible it goes through the
    /// controller's writer, after every save already sent, so a folder a later save creates gets it too. Try again
    /// repeats it.
    func applyMeetingBackups() {
        guard !previewMode, let meetingsBase else { return }
        let excluded = !meetingBackups, previous = meetingBackupApply
        meetingBackupApply = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let applied = showsMeetingsSpace ? await meetings.setExcludedFromBackup(excluded)
                : (try? MeetingStore(meetingsIn: meetingsBase, excludedFromBackup: excluded).applyBackupChoice()) != nil
            // A newer choice reports for itself.
            guard excluded == !meetingBackups else { return }
            meetingBackupMessage = applied ? "" : Self.meetingBackupFailure
            if !applied { announce(meetingBackupMessage) }
        }
    }
    /// Quit, logout, restart or shutdown: capture stops now, before anything awaits. The task ends once the meeting
    /// is saved (true) or its save failed (false); a second request gets the same task.
    func finishMeetingForQuit() -> Task<Bool, Never> {
        if let meetingQuit { return meetingQuit }
        meetings.stopForQuit()
        meetingQuitRequests += 1
        let quitting = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let saved = await meetings.quit()
            meetingQuit = nil
            return saved
        }
        meetingQuit = quitting
        return quitting
    }

    // MARK: Meeting reminders

    /// Which apps use a microphone is read only while reminders are on, the space is visible and macOS is 14.2 or later.
    var meetingRemindersActive: Bool { showsMeetingsSpace && meetingReminders && meetingAppSoundSupported }
    var meetingReminder: MeetingReminderState.Reminder? { meetingWatcher.shown }
    /// No reminder is offered during any capture, a dictation's review or a shortcut change. A paused meeting is open but
    /// not capturing, so a new call is still offered.
    var meetingReminderBlocked: Bool {
        meetings.isCapturing || isRecordingNote || [.preparing, .recording, .transcribing, .recovery].contains(phase) || editingShortcut
    }
    /// What the reminder and the menu-path sheet say now; nil without a reminder.
    var meetingReminderContent: MeetingReminderContent? {
        guard meetingReminder != nil else { return nil }
        let firstTime = !zoomSoundEverIncluded
        return MeetingReminderContent(blocker: meetingHeldMessage ?? meetingStartBlocker, paused: meetings.phase == .paused,
                                      firstTime: firstTime, includesZoomSound: !firstTime && reminderIncludesZoomSound)
    }
    /// Settings → Meetings' switch, only while the space is visible. Off hides any reminder at once and stops reading.
    func setMeetingReminders(_ on: Bool) {
        guard showsMeetingsSpace, on != meetingReminders else { return }
        meetingReminders = on
        if !previewMode { UserDefaults.standard.set(on, forKey: "meetingReminders") }
        updateMeetingWatcher()
    }
    private func updateMeetingWatcher() { meetingWatcher.update(on: meetingRemindersActive) }
    private func observeMeetingWatcher() {
        meetingWatcher.captureActive = { [weak self] in self?.meetingReminderBlocked ?? true }
        meetingWatcher.pausedMeeting = { [weak self] in self?.meetings.phase == .paused }
        meetingWatcher.onChange = { [weak self] in self?.meetingReminderChanged() }
        meetingWatcherObserver = meetingWatcher.$shown.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    /// Each reminder starts with the sources setup would use and is announced; the sheet closes with it.
    private func meetingReminderChanged() {
        reminderExplaining = false
        if meetingReminder != nil {
            reminderIncludesZoomSound = meetingApp != nil
            announce("Within: \(MeetingReminderContent.title)")
        } else { meetingStartSheet = false }
        notify()
    }
    /// Start notes on the reminder. Until Zoom's sound was included in this run, it explains that first and starts
    /// nothing; otherwise it starts with the sources shown. The task ends once the start was asked for or refused.
    @discardableResult func reminderStartNotes() -> Task<Bool, Never>? {
        guard let content = meetingReminderContent, content.blocker == nil else { return nil }
        guard !content.firstTime else {
            reminderExplaining = true
            announce(MeetingReminderContent.explaining); notify()
            return nil
        }
        return meetingStartSheetDefault()
    }
    /// The first-time choice. Including Zoom's sound turns setup's switch on for this run, as turning it on there does.
    @discardableResult func reminderStart(includingZoomSound: Bool) -> Task<Bool, Never>? {
        guard let content = meetingReminderContent, content.blocker == nil else { return nil }
        if includingZoomSound && meetingAppSoundSupported { includeZoomSound = true }
        let app = includingZoomSound ? meetingApp : nil
        return Task { await startMeetingFromReminder(app) }
    }
    /// The sheet's default button, and Start notes once Zoom's sound was included: the sources shown, so never Zoom's
    /// sound before it was ever turned on.
    @discardableResult func meetingStartSheetDefault() -> Task<Bool, Never>? {
        guard let content = meetingReminderContent, content.blocker == nil else { return nil }
        let app: MeetingApp? = content.includesZoomSound ? .zoom : nil
        return Task { await startMeetingFromReminder(app) }
    }
    /// Start notes: the click is the acknowledgment, passed once. A paused meeting is finished first; a lock, sleep, user
    /// switch or quit while it saves cancels the start, since the click came before it. Within's window stays where it is,
    /// so focus stays in the call, unless notes then can't start: it comes forward on New meeting, which says why.
    @discardableResult func startMeetingFromReminder(_ app: MeetingApp?) async -> Bool {
        guard showsMeetingsSpace else { return false }
        // Refused while the reminder still shows, so it stays and says why.
        if let refusal = meetingHeldMessage ?? meetingStartRefusal() { announce(refusal); notify(); return false }
        let epoch = meetings.acknowledgmentEpoch, quits = meetingQuitRequests
        let effects = meetingWatcher.handle(.startNotes)
        guard effects.contains(where: { if case .startMeeting = $0 { return true }; return false }) else { return false }
        if meetings.phase == .paused {
            let finished = await finishMeeting()
            guard meetings.acknowledgmentEpoch == epoch, meetingQuitRequests == quits, !quittingMeeting else { return false }
            guard finished else { reminderStartFailed(nil); return false }
        }
        guard !meetings.isOpen else { return false }
        keepShownMeetingInLibrary()
        guard meetings.start(app: app, acknowledged: true) else {
            // The controller says its own refusals.
            reminderStartFailed(meetings.refusal == nil ? Self.meetingStartFailed : nil)
            return false
        }
        meetingSetupFailure = nil; showingOriginalTranscription = false
        meetingsRoute = .meeting; meetingsFocusRequest = .notes
        reminderStartEpoch = epoch
        return true
    }
    /// After the reminder closed, notes didn't start: Within comes forward on New meeting, which shows why, or on the
    /// meeting still open.
    private func reminderStartFailed(_ failure: String?, announcing: Bool = true) {
        if !meetings.isOpen { meetingSetupFailure = failure; meetingsRoute = .setup }
        if announcing, let failure { announce(failure) }
        notify()
        showMeetings?()
    }
    /// Once a meeting the reminder started has closed: if it never started, for a reason other than a lock, sleep, user
    /// switch or quit, Within says so as for a refusal. Called as the meeting changes; native checks call it directly.
    func reminderStartClosed(failure: String?) {
        guard let epoch = reminderStartEpoch, !meetings.isOpen else { return }
        reminderStartEpoch = nil
        guard let failure, epoch == meetings.acknowledgmentEpoch, !quittingMeeting else { return }
        // A save that failed was said already.
        reminderStartFailed(failure, announcing: meetings.startFailure != nil)
    }
    func reminderSnooze() { meetingWatcher.handle(.snooze) }
    func reminderDismiss() { meetingWatcher.handle(.dismiss) }
    /// The sources line's link: this start only.
    func toggleReminderZoomSound() {
        guard meetingReminderContent?.firstTime == false else { return }
        reminderIncludesZoomSound.toggle()
        notify()
    }
    /// Opens the paused meeting, or what keeps notes from starting. The reminder stays until one of its own actions.
    func reminderShowPausedMeeting() { showMeetings?() }
    func reminderOpenWithin() { if meetingHeldMessage != nil { showMeetings?() } else { showMain?() } }
    /// The menu path: Within comes forward with the reminder's full text in a sheet. Only the sheet's buttons start anything.
    func openMeetingStartSheet() {
        guard showsMeetingsSpace, meetingReminder != nil else { return }
        meetingStartSheet = true
        showWindow?()
        notify()
    }
    func closeMeetingStartSheet() {
        guard meetingStartSheet else { return }
        meetingStartSheet = false
        notify()
    }
    /// Another dialog already covers Within's window, so the sheet can't show: nothing starts, and it says why.
    func meetingStartSheetUnavailable() {
        guard meetingStartSheet else { return }
        meetingStartSheet = false
        announce(Self.meetingStartSheetBlocked); notify()
    }

    // MARK: Meeting capsule and status menu

    /// The capsule shows while a meeting is open and Within isn't the active app.
    func meetingCapsuleShown(appIsActive: Bool) -> Bool { !appIsActive && meetingCapsuleContent != nil }
    /// What the capsule says now: nil unless a meeting is open. A pause is described from its stretch, never as a call's end.
    var meetingCapsuleContent: MeetingCapsuleContent? {
        guard showsMeetingsSpace, meetings.isOpen, let meeting = meetings.meeting else { return nil }
        let phase = meetings.phase, elapsed = meetings.elapsed, app = meeting.appName
        let notHearing = phase == .recording && [.quiet, .lost].contains(meetings.sourceStates[.others])
        let sources = meetings.sourceStates[.others] != nil ? "Transcribing: your microphone + \(app)’s sound" : "Transcribing: your microphone only"
        let (title, spoken): (String, String) = switch phase {
        case .preparing: ("Meeting · starting…", "Meeting notes starting")
        case .recording: notHearing ? ("Meeting · not hearing \(app)", "\(meetings.homeStatus), not hearing \(app)")
            : ("Meeting · \(MeetingTime.short(elapsed))", "\(meetings.homeStatus), \(MeetingTime.spoken(elapsed))")
        case .paused: ("Meeting paused", "\(meetings.homeStatus) at \(MeetingTime.spoken(elapsed))")
        case .pausing: ("Meeting · pausing…", meetings.homeStatus)
        case .finishing: ("Meeting · finishing…", meetings.homeStatus)
        case .discarding, .idle, .finished: ("Meeting · discarding…", meetings.homeStatus)
        }
        let symbol = phase == .paused ? "pause.circle" : notHearing ? "speaker.slash" : meetings.listening ? "mic.fill" : "mic.slash"
        let expansion: MeetingCapsuleContent.Expansion?
        if meetingDictationRefused { expansion = .dictationRefused }
        else if let reason = meetingPauseReason { expansion = .paused(reason) }
        else if phase == .recording, elapsed - (meeting.stretches.last?.start ?? 0) < 60 { expansion = .firstMinute }
        else { expansion = nil }
        let finish: String? = switch (phase, expansion) {
        case (.paused, .paused?): "Finish"
        case (.paused, .dictationRefused?): "Finish meeting"
        default: nil
        }
        return MeetingCapsuleContent(title: title, spokenTitle: spoken, symbol: symbol, warning: notHearing, sources: sources, expansion: expansion,
                                     action: meetings.listening ? .pause : phase == .paused ? .resume : nil,
                                     resumeTitle: meetings.needsAcknowledgment ? "Resume…" : "Resume", resumeBlocker: phase == .paused ? meetingStartBlocker : nil,
                                     finishTitle: finish)
    }
    /// Why a paused meeting paused, from its last stretch, when Within paused it; a call's end is never described here.
    var meetingPauseReason: String? {
        guard meetings.phase == .paused, let meeting = meetings.meeting, let ended = meeting.stretches.last?.ended, ended != .callEnded else { return nil }
        return MeetingWords.pauseReason(ended, appName: meeting.appName)
    }
    /// The status menu's meeting lines: the time, its spoken form, and what the meeting is doing.
    var meetingMenuLines: (title: String, spoken: String, detail: String)? {
        guard showsMeetingsSpace, meetings.isOpen else { return nil }
        let elapsed = meetings.elapsed
        let spoken = meetings.phase == .paused ? "\(meetings.homeStatus) at \(MeetingTime.spoken(elapsed))" : "\(meetings.homeStatus), \(MeetingTime.spoken(elapsed))"
        // While Resume Meeting is unavailable, why.
        let detail = meetings.listening ? MeetingWords.muteHint : (meetings.phase == .paused ? meetingStartBlocker : nil) ?? meetingPauseReason ?? meetings.homeStatus
        return ("Meeting · \(MeetingTime.short(elapsed))", spoken, detail)
    }
    /// Pause from the capsule or the status menu.
    func pauseOpenMeeting() { meetings.pause() }
    /// Resume from outside the meeting screen. When the call may have changed, the screen's acknowledgment is shown
    /// instead, since only it can give one; nothing resumes.
    func resumeOpenMeeting() {
        guard meetings.phase == .paused else { return }
        guard meetings.needsAcknowledgment else { resumeMeeting(acknowledged: false); return }
        showMeetings?()
        meetingsFocusRequest = .acknowledgment
    }
    @discardableResult func finishOpenMeeting() -> Task<Bool, Never> { Task { await finishMeeting() } }
    /// Within forward on the Meetings space: the open meeting, or the library with a recovered one to review.
    func showOpenMeeting() { if showsMeetingsSpace { showMeetings?() } }

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
        message = Self.meetingDictationRefusal
        // The capsule says so for a few seconds; previews keep it until they are configured again.
        meetingDictationRefused = true; dictationRefusalReset?.cancel()
        if !previewMode {
            dictationRefusalReset = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.dictationRefusalShown)
                guard let self, !Task.isCancelled else { return }
                meetingDictationRefused = false; notify()
            }
        }
        notify(); announce(message)
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
        meetingWatcher.captureStarted()
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
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.boundaryEnded() } })
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
    @objc private func screenUnlocked() { boundaryEnded() }
    /// Unlock, wake or the session active again: reminders may offer again, and a meeting a boundary paused says so.
    private func boundaryEnded() {
        meetingWatcher.boundaryEnded()
        announceBoundaryPause()
    }
    func cancelForBoundary(_ reason: MeetingStretchEnd = .lockOrSleep) {
        clearLastDictationChange()
        meetingWatcher.lockOrSleep()
        let meetingOpen = meetings.isOpen
        if meetingOpen, meetings.isCapturing { boundaryPause = (reason, meetings.phase == .preparing) }
        // Always: it also clears an acknowledgment checked in setup or for Continue, since the call may have changed.
        meetings.boundary(reason)
        if meetingOpen {
            // Pause and keep: a gap marks it, nothing resumes on its own, and the models unload once the rings drain.
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
            startFailure: meetings.startFailure, computerAudioSupported: supported, remindersOn: meetingRemindersActive, lastSaveFailed: meetings.notSaved)
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
        meetingBackups = false; meetingBackupsWereIncluded = false; meetingBackupMessage = ""
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
        meetingsRoute = .library; meetingLibrary = []; meetingLibraryUnreadable = 0; meetingsToReview = []; closedRecoveryNotices = []
        showingOriginalTranscription = false; includeZoomSound = false; meetingSetupFailure = nil; meetingsFocusRequest = nil
        meetingReminders = false; zoomSoundEverIncluded = false; reminderExplaining = false; meetingStartSheet = false
        meetingDictationRefused = false; dictationRefusalReset?.cancel()
        meetingWatcher = MeetingWatcher(read: nil); observeMeetingWatcher()
        meetingAppSoundSupported = Self.appSoundAvailable
        if state.hasPrefix("meeting") || state == "home-during-meeting" { configureMeetingsPreview(state) }
        if state.hasPrefix("meeting-reminder") || state.hasPrefix("meeting-menu-start-sheet") { configureReminderPreview(state) }
        if state.hasPrefix("meeting-capsule") { configureCapsulePreview(state) }
        // Native checks only: reminders stored on while the space is hidden.
        if state == "reminders-on-space-hidden" { meetingReminders = true; updateMeetingWatcher() }
        if state.hasPrefix("settings-privacy-saved-meetings") { savedMeetingCount = 3 }
        if state == "settings-privacy-saved-meetings-days30" { meetingRetention = .days30 }
        // Hidden after the backups switch was turned on: the folder stays in backups, and Privacy says so.
        if state == "settings-privacy-saved-meetings-backups" { meetingBackups = true }
        // The switch was on and then turned off; or the choice couldn't be applied to the folder.
        if state.hasSuffix("-backups-off") { meetingBackupsWereIncluded = true }
        if state == "settings-privacy-saved-meetings-backup-failed" { meetingBackupMessage = Self.meetingBackupFailure }
        if state.hasPrefix("settings-meetings") {
            showsMeetingsSpace = true
            meetingLibrary = [MeetingPreviews.finished, MeetingPreviews.recovered, MeetingPreviews.microphoneOnly, MeetingPreviews.oneOnOne]
            if state == "settings-meetings-backups" { meetingBackups = true; meetingRetention = .days90 }
            if state.hasPrefix("settings-meetings-reminders") { meetingReminders = true }
            if state == "settings-meetings-reminders-unsupported" { meetingAppSoundSupported = false }
            updateMeetingWatcher()
        }
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
        // "meeting-capsule-resume-blocked": the selected microphone was unplugged while the meeting was paused.
        if state == "missing-input" || state == "meeting-capsule-resume-blocked" { devices = [] }
        if state == "permission" { accessibilityAllowed = false }
        if state == "meeting-reminder-not-ready" { microphoneAllowed = false }
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
    /// The Meetings space with synthetic meetings only; nothing is read, written or started.
    private func configureMeetingsPreview(_ state: String) {
        showsMeetingsSpace = true
        let previews = MeetingPreviews.self
        meetingLibrary = state == "meetings-empty" ? [] : [previews.finished, previews.recovered, previews.microphoneOnly, previews.oneOnOne]
        switch state {
        case "meetings-library", "meetings-library-720": meetingsToReview = [previews.recovered.id]
        case "meeting-setup", "meeting-setup-computer-audio-intro", "meeting-mic-only", "meeting-setup-not-saved":
            meetingsRoute = .setup
            includeZoomSound = state == "meeting-setup-computer-audio-intro"
            if state == "meeting-mic-only" { meetingAppSoundSupported = false }
            // The finished meeting shown before couldn't be saved, so setup says why Start waits and offers Try again.
            if state == "meeting-setup-not-saved" { meetings.configurePreview(previews.finished, phase: .finished, notSaved: true) }
        case "meeting-recording", "meeting-recording-720", "meeting-recording-900", "home-during-meeting":
            meetings.configurePreview(previews.live, phase: .recording, provisional: [.others: "I think we could move the shortcut choice to the end and"],
                                      sourceStates: [.you: .live, .others: .live], elapsed: 137)
        case "meeting-paused", "meeting-resume-acknowledge", "meeting-call-ended":
            let ended: MeetingStretchEnd = state == "meeting-paused" ? .pauseButton : state == "meeting-call-ended" ? .callEnded : .lockOrSleep
            meetings.configurePreview(previews.paused(ended), phase: .paused, sourceStates: [.you: .off, .others: .off], elapsed: 754,
                                      needsAcknowledgment: ended != .pauseButton)
        case "meeting-recovered", "meeting-finished", "meeting-finished-720", "meeting-dictionary-fixes":
            let meeting = state == "meeting-recovered" ? previews.recovered : state.hasPrefix("meeting-finished") ? previews.finished : previews.fixes
            if state == "meeting-recovered" { meetingsToReview = [meeting.id] }
            if state == "meeting-dictionary-fixes" { previewDictionary(.loaded(Self.previewWords)); meetingLibrary.insert(meeting, at: 0) }
            _ = openMeeting(meeting.id)
            meetingsFocusRequest = nil
        default: break
        }
        if meetings.isOpen { meetingsRoute = .meeting; meetingLibrary.insert(meetings.meeting!, at: 0) }
    }
    /// A reminder for a synthetic Zoom call, offered by the watcher from two synthetic readings; nothing is read or started.
    private func configureReminderPreview(_ state: String) {
        showsMeetingsSpace = true; meetingReminders = true; meetings.previewStartsAccepted = true
        updateMeetingWatcher()
        // "first": Zoom's sound was never included in this run.
        includeZoomSound = !state.contains("-first")
        if state == "meeting-reminder-while-paused" {
            meetings.configurePreview(MeetingPreviews.paused(.pauseButton), phase: .paused, sourceStates: [.you: .off, .others: .off], elapsed: 754)
        }
        let call = [AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)]
        for _ in 0..<2 { meetingWatcher.observe(call, now: Date(timeIntervalSince1970: 1_800_000_000)) }
        reminderExplaining = state == "meeting-reminder-first-audio"
        meetingStartSheet = state.hasPrefix("meeting-menu-start-sheet")
    }
    /// The capsule over a synthetic open meeting, as another app in front would see it; nothing is read or started.
    /// Increase Contrast and Reduce Motion use the first minute's.
    private func configureCapsulePreview(_ state: String) {
        showsMeetingsSpace = true
        let off: [MeetingSource: MeetingSourceState] = [.you: .off, .others: .off]
        switch state {
        case "meeting-capsule-paused", "meeting-capsule-dictation-refused-paused", "meeting-capsule-resume-blocked":
            meetings.configurePreview(MeetingPreviews.paused(.pauseButton), phase: .paused, sourceStates: off, elapsed: 754)
        case "meeting-capsule-after-unlock":
            meetings.configurePreview(MeetingPreviews.paused(.lockOrSleep), phase: .paused, sourceStates: off, elapsed: 754, needsAcknowledgment: true)
        case "meeting-capsule-source-lost":
            meetings.configurePreview(MeetingPreviews.paused(.computerAudioLost), phase: .paused, sourceStates: [.you: .off, .others: .lost], elapsed: 754,
                                      needsAcknowledgment: true)
        default:
            let firstMinute = ["meeting-capsule-first-minute", "meeting-capsule-increase-contrast", "meeting-capsule-reduce-motion"].contains(state)
            meetings.configurePreview(MeetingPreviews.live, phase: .recording,
                                      sourceStates: [.you: .live, .others: state == "meeting-capsule-not-hearing" ? .quiet : .live], elapsed: firstMinute ? 42 : 4324)
        }
        meetingDictationRefused = state.hasPrefix("meeting-capsule-dictation-refused")
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
        meetingWatcher.update(on: false)
        flushNoteEdits(); cancel(cause: .shutdown); clearLastDictationChange(); practiceChange = nil
        restoreOutputIfNeeded(); modelTask?.cancel(); shortcut.shutdown()
    }
}

enum CaptureActivity { case none, dictation, note, meeting }
enum MeetingsRoute { case library, setup, meeting }
/// Where focus goes in the Meetings space after an action.
enum MeetingsFocus: Equatable { case newMeeting, row(UUID), title, notes, export, firstTurn, acknowledgment }

/// A meeting's stretches hold the one session the way a note recording does, so every guard on `phase` and
/// `workerBusy` applies while it captures.
extension AppModel: MeetingHost {
    var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var modelManifest: ModelManifest { manifest }
    func modelDirectory() async -> URL { await store.directory }

    /// What holds capture, in order, before whether Within is ready.
    func meetingStartRefusal() -> String? {
        if let holder = meetingCaptureHolder { return holder }
        refreshPermissions(mayRegisterShortcut: true)
        return meetingReadinessRefusal
    }
    fileprivate var meetingCaptureHolder: String? {
        if isRecordingNote { return "Stop your note recording to start meeting notes." }
        if phase == .preparing || phase == .recording || phase == .transcribing { return "Finish dictating to start meeting notes." }
        if phase == .recovery { return "Review your pending dictation first." }
        if hasActivePracticeSession || editingShortcut { return "Finish practice or the shortcut change first." }
        return nil
    }
    fileprivate var meetingReadinessRefusal: String? {
        guard !canStart else { return nil }
        return modelBusy || workerBusy ? readinessWaitMessage : !modelInstalled || !microphoneAllowed ? "Finish setup before recording."
            : !selectedInputAvailable ? "Your selected microphone is unavailable." : "Check the local speech model in Settings."
    }

    func claimCapture() -> UUID? {
        guard !workerBusy, !modelBusy, let id = session.begin() else { return nil }
        meetingWatcher.captureStarted()
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
