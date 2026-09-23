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
    @Published var soundsEnabled: Bool { didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") } }
    private var lastErrorCode = "none"
    private var lastModelCheck = "not_checked"
    @Published var practiceText = ""
    @Published var compatibilityPaste: Bool { didSet { UserDefaults.standard.set(compatibilityPaste, forKey: "compatibilityPaste") } }
    @Published var mode: ActivationMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "activationMode") } }
    @Published var alternateShortcut: Bool { didSet { UserDefaults.standard.set(alternateShortcut, forKey: "alternateShortcut"); registerShortcut() } }
    @Published var microphoneUID: String { didSet { UserDefaults.standard.set(microphoneUID, forKey: "microphoneUID") } }
    @Published private(set) var recoveryReason: RecoveryReason?
    @Published private(set) var recoveryDetail = ""
    @Published private(set) var returning = false

    let manifest: ModelManifest
    let store: ModelStore
    private let speech = LocalSpeech()
    private let capture = CaptureEngine()
    private lazy var shortcut = ShortcutManager()
    private var gesture = ShortcutGesture()
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
    var stateChanged: (() -> Void)?
    var showMain: (() -> Void)?
    var showRecovery: (() -> Void)?
    var dismissRecovery: (() -> Void)?

    var phase: DictationPhase { session.phase }
    var pendingText: String { session.transcript ?? "" }
    var shortcutLabel: String { alternateShortcut ? "⌃ ⇧ D" : "⌃ ⇧ Space" }
    var canStart: Bool { phase == .ready && !workerBusy && modelInstalled && !modelBusy && microphoneAllowed }
    var targetName: String { target?.appName ?? "original app" }
    var canReturn: Bool { recoveryReason?.permitsReturn == true && target != nil && !returning }
    var isActive: Bool { phase == .preparing || phase == .recording }

    init(manifest: ModelManifest, base: URL, preview: Bool = false) {
        self.manifest = manifest
        previewMode = preview
        store = ModelStore(manifest: manifest, base: base)
        soundsEnabled = UserDefaults.standard.bool(forKey: "soundsEnabled")
        compatibilityPaste = UserDefaults.standard.bool(forKey: "compatibilityPaste")
        mode = ActivationMode(rawValue: UserDefaults.standard.string(forKey: "activationMode") ?? "hold") ?? .hold
        alternateShortcut = UserDefaults.standard.bool(forKey: "alternateShortcut")
        microphoneUID = UserDefaults.standard.string(forKey: "microphoneUID") ?? ""
        if preview { return }
        shortcut.onDown = { [weak self] in
            guard let self else { return }
            switch gesture.down(mode: mode, isActive: isActive) {
            case .start: start(practice: false, fromShortcut: true)
            case .stop: stop()
            case nil: break
            }
        }
        shortcut.onUp = { [weak self] in
            guard let self else { return }
            if gesture.up() == .stop { stop() }
        }
        capture.onConfigurationChanged = { [weak self] in
            guard let self, phase == .recording else { return }
            forcedRecovery = "The microphone changed or disconnected. Review the words captured before it stopped."; stop()
        }
        registerShortcut()
        refreshPermissions()
        installLifecycleObservers()
        modelTask = Task { [weak self] in
            guard let self else { return }
            try? await store.cleanInterruptedDownloads()
            modelInstalled = await store.isInstalled()
            modelMessage = modelInstalled ? "Preparing local speech…" : "One local model. No account."
            if modelInstalled {
                modelBusy = true
                do { try await speech.prepare(directory: store.directory, manifest: manifest); modelMessage = "Verified and ready · runs offline"; lastModelCheck = "passed" }
                catch { lastModelCheck = "failed_or_unavailable"; modelMessage = "Model unavailable. Remove it and download a fresh copy." }
                modelBusy = false
            }
            modelTask = nil; notify()
        }
    }

    func registerShortcut() { shortcutAvailable = shortcut.register(alternate: alternateShortcut) }
    func refreshPermissions() {
        guard !previewMode else { return }
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
        loginEnabled = SMAppService.mainApp.status == .enabled
        devices = CaptureEngine.devices()
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
                modelMessage = "Verified and ready · runs offline"; lastModelCheck = "passed"
            } catch is CancellationError { modelMessage = "Download canceled. Temporary files removed." }
            catch { modelMessage = Task.isCancelled ? "Download canceled. Temporary files removed." : "Download couldn’t be verified. Check your connection and try again." }
            modelBusy = false; modelDownloading = false; modelTask = nil; notify()
        }
    }
    func cancelDownload() { modelTask?.cancel() }
    func removeModel() {
        guard !modelBusy, !workerBusy, phase == .ready else { return }
        modelBusy = true
        modelTask = Task { [weak self] in
            guard let self else { return }
            await speech.unload()
            do { try await store.remove(); modelInstalled = false; modelMessage = "Model removed from this Mac." }
            catch { modelMessage = "The model couldn’t be removed. Try again after restarting Within." }
            modelBusy = false; modelDownloading = false; modelTask = nil; notify()
        }
    }

    func start(practice: Bool, fromShortcut: Bool = false) {
        refreshPermissions()
        guard canStart else {
            if phase == .recovery { showRecovery?() }
            else if !modelInstalled || !microphoneAllowed { message = "Finish setup before you dictate."; showMain?() }
            return
        }
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
        guard let id = session.begin() else { return }
        trial.discard(); workerBusy = true; message = "Preparing local speech…"; elapsed = 0; level = 0
        notify()
        shortcut.monitorEscape { [weak self] in
            guard let self else { return }
            if phase == .recovery { dismissRecovery?() } else { cancel() }
        }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = await store.directory
                try await speech.prepare(directory: directory, manifest: manifest)
                lastModelCheck = "passed"
                try Task.checkCancellation()
                guard session.isCurrent(id) else { throw CancellationError() }
                try await speech.begin()
                try Task.checkCancellation()
                guard session.isCurrent(id) else { throw CancellationError() }
                guard !IsSecureEventInputEnabled() else { throw CaptureFailure.protectedInput }
                if let target, target.evidence(forCompatibilityPaste: pasteChosenForSession).blockReason != nil { throw CaptureFailure.targetChanged }
                let ring = try capture.start(deviceUID: microphoneUID)
                let rate = capture.sampleRate
                guard session.recording(id) else { capture.stop(); throw CancellationError() }
                message = "Starting microphone…"; notify()
                startPulse(ring: ring, sampleRate: rate, id: id)
                let text = try await speech.consume(ring, sampleRate: rate)
                try Task.checkCancellation()
                guard session.isCurrent(id) else { throw CancellationError() }
                capture.stop(); pulse?.cancel(); pulse = nil
                if ring.status == 2 { forcedRecovery = "Recording stopped because speech processing fell behind. These are the words captured before the stop." }
                if phase == .recording { _ = session.stopped(id) }
                if text.isEmpty { session.finish(id); message = "No speech detected. Try again when you’re ready."; releaseTarget(); announce(message) }
                else if practice {
                    UserDefaults.standard.set(true, forKey: "setupComplete")
                    practiceText += (practiceText.isEmpty ? "" : "\n") + text
                    session.finish(id); message = "Your words arrived. Try the shortcut in another app."; releaseTarget(); announce("Practice dictation finished")
                } else { await deliver(text, id: id) }
            } catch {
                capture.stop(); pulse?.cancel(); pulse = nil; shortcut.stopEscapeMonitor()
                await speech.cancel()
                if session.isCurrent(id), case SpeechFailure.partial(let text) = error {
                    forcedRecovery = "Transcription stopped early. These are the words recovered before the error; part of your dictation may be missing."
                    await deliver(text, id: id)
                } else if session.isCurrent(id) {
                    session.finish(id); releaseTarget()
                    lastErrorCode = error is IntegrityError ? "model_integrity" : "capture_or_inference"
                    if error is IntegrityError { lastModelCheck = "failed"; modelMessage = "Model files failed verification. Remove the model and download a fresh copy." }
                    message = error is CancellationError ? "Canceled. Microphone off." : "Dictation stopped. Audio was discarded. Check the microphone and local model, then try again."
                    if case CaptureFailure.protectedInput = error { message = "Protected input is active. Microphone off." }
                    if case CaptureFailure.targetChanged = error { message = "The destination changed before recording. Choose your text field and try again." }
                    announce(message)
                }
            }
            if unloadAfterSession { await speech.unload(); unloadAfterSession = false }
            shortcut.stopEscapeMonitor()
            workerBusy = false; worker = nil; notify()
        }
    }

    private func startPulse(ring: AudioRing, sampleRate: Double, id: UUID) {
        pulse?.cancel()
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(300))
        pulse = Task { [weak self] in
            var lastSampleCount: UInt64 = 0
            var lastAudioProgress = started
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, session.isCurrent(id), phase == .recording else { return }
                level = min(1, ring.level * 7); elapsed = Double(ring.samplesCaptured) / sampleRate
                if ring.samplesCaptured != lastSampleCount { lastSampleCount = ring.samplesCaptured; lastAudioProgress = .now }
                if audioFlowing, ContinuousClock.now >= lastAudioProgress.advanced(by: .seconds(5)) {
                    forcedRecovery = "The microphone stopped sending audio. Review the words captured before it stopped."; stop(); return
                }
                if !audioFlowing, ring.samplesCaptured > 0 { audioFlowing = true; message = "Listening"; announce("Recording started"); playCue(start: true) }
                if !audioFlowing, ContinuousClock.now >= started.advanced(by: .seconds(5)) { cancel(reason: "No audio arrived from the microphone. Check the selected input and try again."); return }
                if fromHoldShortcut && !shortcut.physicalChordHeld(alternate: alternateShortcut) { stop(); return }
                if IsSecureEventInputEnabled() { cancel(reason: "Protected input became active. Recording canceled."); return }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { cancel(reason: "Microphone access changed. Recording canceled."); return }
                if ring.status != 0 || ContinuousClock.now >= deadline {
                    if ring.status == 2 { forcedRecovery = "Recording stopped because speech processing fell behind. Review the captured words before using them." }
                    else { message = "Five-minute limit reached. Finishing your words…"; announce("Five-minute limit reached. Recording stopped") }
                    stop(); return
                }
            }
        }
    }
    func stop() {
        guard let id = session.id else { return }
        if phase == .preparing { cancel(); return }
        guard phase == .recording else { return }
        capture.stop(); pulse?.cancel(); pulse = nil
        _ = session.stopped(id); playCue(start: false); level = 0; message = "Finishing on this Mac…"; notify(); announce("Recording stopped. Transcribing")
    }
    func cancel() { cancel(reason: "Canceled. Microphone off.") }
    private func cancel(reason: String) {
        capture.stop(); pulse?.cancel(); pulse = nil; shortcut.stopEscapeMonitor()
        worker?.cancel(); session.cancel(); trial.discard(); releaseTarget()
        recoveryReason = nil; recoveryDetail = ""; level = 0; message = reason
        dismissRecovery?(); notify(); announce(message)
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
        } else {
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
            if trial.phase == .inserted { discard(); message = "Inserted into the original field."; announce(message) }
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
        if pasteboard.setString(pendingText, forType: .string) { discard(); message = "Copied. Your clipboard may sync through macOS."; announce("Copied to clipboard") }
        else { recoveryDetail = "Copy failed. Your words are still here." }
    }
    func discard() {
        guard !workerBusy else { return }
        session.cancel(); trial.discard(); releaseTarget(); recoveryReason = nil; recoveryDetail = ""
        dismissRecovery?(); message = "Ready when you are."; notify()
    }
    private func releaseTarget() { target?.stopObserving(); target = nil }
    private func notify() { stateChanged?() }
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
        if session.interruptForSystemBoundary() { cancel() }
        else if phase == .recovery {
            recoveryActionEpoch += 1; returning = false
            target?.markFocusChanged(); dismissRecovery?()
            message = "Your pending words are still here. Review when you’re ready."; notify()
        }
        requestUnload()
    }
    private func requestUnload() {
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
            modelInstalled: modelInstalled, modelRevision: manifest.revision, lastModelCheck: lastModelCheck, lastErrorCode: lastErrorCode).preview()
    }
    func configurePreview(_ state: String) {
        modelInstalled = state != "setup"; microphoneAllowed = state != "setup"; accessibilityAllowed = state != "setup"
        modelMessage = "One local model. No account."; shortcutAvailable = true
        if state == "recovery" {
            let id = session.begin()!; _ = session.recover("The best ideas often start as a few ordinary words. Let’s make a little room for them.", id: id)
            recoveryReason = .focusChanged; recoveryDetail = RecoveryReason.focusChanged.explanation
        } else if state == "recording" {
            let id = session.begin()!; _ = session.recording(id); elapsed = 12; level = 0.45; audioFlowing = true
        }
    }
    func shutdown() { cancel(); modelTask?.cancel(); shortcut.shutdown() }
}
