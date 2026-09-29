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
    @Published var practiceText = ""
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
    private var recoveryActionEpoch = 0
    private var observers: [NSObjectProtocol] = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var pasteChosenForSession = false
    private var fromHoldShortcut = false
    private let previewMode: Bool
    private var historyStore: HistoryStore?
    private var historyTimer: Timer?
    private var notesStore: NotesStore?
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

    init(manifest: ModelManifest, base: URL, preview: Bool = false) {
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
        if preview { return }
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
        historyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneHistory() }
        }
        shortcut.activationMode = { [weak self] in self?.mode ?? .hold }
        shortcut.onDown = { [weak self] in
            guard let self, !editingShortcut else { return }
            guard !isRecordingNote else { refuseDictationDuringNote(); return }
            switch gesture.down(mode: mode, isActive: isActive) {
            case .start:
                startFromCurrentWindow(fromShortcut: true)
                shortcutActivationID = isActive ? session.id : nil
            case .stop: shortcutActivationID = nil; stop(cause: .togglePress)
            case nil: break
            }
        }
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
            guard let self, phase == .recording else { return }
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

    func startFromCurrentWindow(fromShortcut: Bool = false) {
        start(practice: startsInPractice, fromShortcut: fromShortcut)
    }
    func start(practice: Bool, fromShortcut: Bool = false) {
        guard !editingShortcut else { return }
        guard !isRecordingNote else { refuseDictationDuringNote(); return }
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
                if text.isEmpty {
                    session.finish(id)
                    message = forcedRecovery == nil ? "No speech detected. Try again when you’re ready." : "Recording stopped before any words were captured. Check the microphone and try again."
                    releaseTarget(); announce(message)
                }
                else if practice {
                    completeSetup()
                    practiceText += (practiceText.isEmpty ? "" : "\n") + text
                    session.finish(id); message = "Your words arrived. Try the shortcut in another app."; releaseTarget(); announce("Practice dictation finished")
                } else { await deliver(text, id: id) }
            } catch {
                capture.stop(reusingStoppedEngine: false); pulse?.cancel(); pulse = nil; shortcut.stopEscapeMonitor()
                restoreOutputIfNeeded()
                if session.isCurrent(id) { recordStop(.pipelineError) }
                await speech.cancel()
                // Model integrity is independent of whether the user canceled this session.
                if error is IntegrityError { invalidateModelVerification() }
                if session.isCurrent(id), case SpeechFailure.partial(let text) = error {
                    forcedRecovery = "Transcription stopped early. These are the words recovered before the error; part of your dictation may be missing."
                    await deliver(text, id: id)
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
        // A long note recording is never canceled by a global Escape.
        guard !previewMode, !isRecordingNote, isActive || phase == .transcribing else { return }
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
        guard let id = session.id else { return }
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
    private func deliver(_ text: String, id: UUID) async {
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
            session.finish(id); releaseTarget(); message = "Inserted. Microphone off."; announce("Dictation inserted")
            recordHistory(text, practice: isPracticeSession)
        } else {
            suspendEscapeShortcut()
            _ = session.recover(text, id: id)
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
                let words = pendingText
                discard(); message = "Inserted into the original field."; announce(message)
                recordHistory(words, practice: isPracticeSession)
            }
            else {
                if case .recovery(let reason) = trial.phase { recoveryReason = reason; recoveryDetail = reason.explanation }
                showRecovery?()
            }
        }
    }
    func copyPending() {
        guard phase == .recovery, !workerBusy, !returning, !pendingText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let words = pendingText
        if pasteboard.setString(words, forType: .string) {
            discard(); message = "Copied. Your clipboard may sync through macOS."; announce("Copied to clipboard")
            recordHistory(words, practice: isPracticeSession)
        }
        else { recoveryDetail = "Copy failed. Your words are still here." }
    }
    func discard() {
        guard !workerBusy else { return }
        session.cancel(); trial.discard(); releaseTarget(); recoveryReason = nil; recoveryDetail = ""
        dismissRecovery?(); message = "Ready when you are."; notify()
    }
    private func releaseTarget() { target?.stopObserving(); target = nil }

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
    private func loadNotes() {
        guard let notesStore else { return }
        let loaded = notesStore.loadAll()
        notes = loaded.notes
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
        history.removeAll { $0.id == id }; persistHistory(); announce("Dictation deleted from history")
    }
    func clearHistory() { history = []; persistHistory(); announce("History cleared") }
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
    private func recordHistory(_ text: String, practice: Bool) {
        guard !practice, let retention = historyRetention, retention.keepsHistory else { return }
        history = HistoryPolicy.adding(text, at: Date(), to: history, retention: retention)
        persistHistory()
    }
    private func notify() {
        if phase == .ready, !workerBusy, !modelBusy, message == readinessWaitMessage {
            message = canStart ? "Ready when you are. Microphone off." : !modelVerified ? modelMessage : "Check your microphone and permissions in Settings."
            announce(message)
        }
        stateChanged?()
    }
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private func installLifecycleObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancelForBoundary() } })
        }
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
    private func cancelForBoundary() {
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
    private func requestUnload() {
        capture.preventReuse()
        if workerBusy { unloadAfterSession = true; return }
        workerBusy = true
        worker = Task {
            await speech.unload()
            workerBusy = false; worker = nil; notify()
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
    private func playCue(start: Bool) {
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
            lastRecordingStartup: startupDiagnostics.latest).preview()
    }
    func configurePreview(_ state: String) {
        guard previewMode else { return }
        modelBusy = false; workerBusy = false
        mode = .toggle; dictationShortcut = .controlShiftD; microphoneUID = "preview-input"
        historyRetention = nil; history = []
        automaticUpdateChecks = nil; updateResult = nil
        if state == "update-available" {
            automaticUpdateChecks = true
            updateResult = .available(ReleaseInfo(tag: "v0.1.0-build12", title: "Within 0.1.0 (build 12)",
                notes: "Check for updates from Within, and a weekly check you can turn on.", pageURL: URL(string: "https://github.com/madeordinary/within/releases")!,
                downloadURL: URL(string: "https://github.com/madeordinary/within/releases/download/v0.1.0-build12/Within-0.1.0-build12.dmg"),
                build: 12, prerelease: true))
        }
        notes = []; selectedNoteID = nil; recordingNoteID = nil; liveConfirmed = ""; liveVolatile = ""
        if state == "notes" || state == "note-recording" || state == "note-preparing" {
            // Synthetic sample notes only; previews never read or write the Notes folder.
            let now = Date()
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
        if state == "practice" { practiceText = "A little more room for an ordinary idea."; isPracticeSession = true }
        if state == "practice-unloading" { isPracticeSession = true; workerBusy = true }
        if state == "model-busy" { modelBusy = true }
        if state == "practice-recording" || state == "practice-transcribing" {
            isPracticeSession = true; workerBusy = true
            let id = session.begin()!; _ = session.recording(id)
            if state == "practice-transcribing" { _ = session.stopped(id) }
        }
        if state == "recovery" || state == "practice-recovery" {
            isPracticeSession = state == "practice-recovery"
            let id = session.begin()!; _ = session.recover("The best ideas often start as a few ordinary words. Let’s make a little room for them.", id: id)
            recoveryReason = .focusChanged; recoveryDetail = RecoveryReason.focusChanged.explanation
        } else if state == "recording" {
            let id = session.begin()!; _ = session.recording(id); elapsed = 12; level = 0.45; audioFlowing = true
        }
        notify()
    }
    func shutdown() { flushNoteEdits(); cancel(cause: .shutdown); restoreOutputIfNeeded(); modelTask?.cancel(); shortcut.shutdown() }
}
