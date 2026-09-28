import AppKit
import WithinCore

/// Uses a uniquely named, synthetic pasteboard. Never reads the user's clipboard.
@MainActor
func nativeChecks(to output: URL) throws {
    _ = NSApplication.shared
    let manifest = try loadManifest()
    let preferenceKeys = ["soundsEnabled", "compatibilityPaste", "activationMode", "alternateShortcut", "dictationShortcut", "microphoneUID", "setupComplete", "historyRetention", "automaticUpdateChecks", "lastUpdateCheck", "muteOutputWhileDictating", "outputMuteRecord"]
    let preferencesBefore = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
    func fixture(_ state: String) -> AppModel {
        let model = AppModel(manifest: manifest, base: output.deletingLastPathComponent().appendingPathComponent("unused"), preview: true)
        model.configurePreview(state)
        return model
    }
    var readinessPassed = true
    for (state, expected) in [("ready", true), ("setup", false), ("model-error", false), ("missing-input", false), ("permission", true), ("recovery", false), ("recording", false)] {
        let model = fixture(state)
        readinessPassed = readinessPassed && model.canStart == expected
    }
    let invalidated = fixture("ready")
    let initiallyReady = invalidated.canStart
    invalidated.invalidateModelVerification()
    var openedModelSettings = false
    invalidated.showModelSettings = { openedModelSettings = true; invalidated.settingsSection = "Model" }
    invalidated.start(practice: true)
    let invalidationPassed = initiallyReady && invalidated.modelInstalled && !invalidated.modelVerified
        && !invalidated.canStart && invalidated.phase == .ready && !invalidated.workerBusy
        && openedModelSettings && invalidated.settingsSection == "Model"
    invalidated.showModelSettings = nil

    let completedPractice = fixture("practice-unloading")
    let activePractice = fixture("practice-recording")
    let finishingPractice = fixture("practice-transcribing")
    let practiceLifecyclePassed = completedPractice.workerBusy && !completedPractice.hasActivePracticeSession
        && activePractice.hasActivePracticeSession && finishingPractice.hasActivePracticeSession
    let recoveredPractice = fixture("practice-recovery")
    let practiceCloseRecheckPassed = activePractice.shouldCancelPracticeOnClose(sessionID: activePractice.session.id)
        && !activePractice.shouldCancelPracticeOnClose(sessionID: UUID())
        && !activePractice.shouldCancelPracticeOnClose(sessionID: nil)
        && !completedPractice.shouldCancelPracticeOnClose(sessionID: completedPractice.session.id)
        && !recoveredPractice.shouldCancelPracticeOnClose(sessionID: recoveredPractice.session.id)
        && !recoveredPractice.pendingText.isEmpty
    let activeMessage = activePractice.message
    activePractice.start(practice: true)
    let activeFeedbackPreserved = activePractice.message == activeMessage && activePractice.phase == .recording
    completedPractice.start(practice: true)
    let busy = fixture("model-busy")
    busy.start(practice: true)
    let busyFeedbackPassed = completedPractice.message.contains("Try again") && busy.message.contains("Try again")
        && busy.phase == .ready && !busy.workerBusy && activeFeedbackPreserved
    busy.configurePreview("ready")
    completedPractice.configurePreview("ready")
    let busyFeedbackCleared = busy.canStart && completedPractice.canStart
        && !busy.message.contains("Try again") && !completedPractice.message.contains("Try again")

    let routing = fixture("ready")
    routing.practiceAreaIsActive = { true }
    let activeWindowRoutesToPractice = routing.startsInPractice
    routing.practiceAreaIsActive = { false }
    let routingPassed = activeWindowRoutesToPractice && !routing.startsInPractice
    let setup = fixture("setup")
    setup.completeSetup()
    let setupPassed = setup.setupComplete && setup.phase == .ready && !setup.workerBusy && setup.practiceText.isEmpty

    let shortcutSetup = fixture("ready")
    let editingBegan = shortcutSetup.beginShortcutEditing()
    shortcutSetup.start(practice: true)
    let editingDidNotRecord = !shortcutSetup.canStart && shortcutSetup.phase == .ready && !shortcutSetup.workerBusy
    let shortcutChosen = shortcutSetup.chooseShortcut(.rightControl)
    shortcutSetup.endShortcutEditing()
    let validShortcutKept = shortcutSetup.dictationShortcut == .rightControl && shortcutSetup.canStart
    let invalidShortcutRejected = !shortcutSetup.chooseShortcut(DictationShortcut(keyCode: 0, modifiers: 0, keyLabel: "A"))
        && shortcutSetup.dictationShortcut == .rightControl
    _ = shortcutSetup.beginShortcutEditing(); shortcutSetup.endShortcutEditing()
    let canceledEditKept = shortcutSetup.dictationShortcut == .rightControl
    let activeShortcutRefused = !activePractice.beginShortcutEditing() && !activePractice.chooseShortcut(.rightControl)
    let shortcutEditingPassed = editingBegan && editingDidNotRecord && shortcutChosen && validShortcutKept
        && invalidShortcutRejected && canceledEditKept && activeShortcutRefused
    let microphoneSetup = fixture("ready")
    microphoneSetup.microphoneUID = "disconnected-fixture"
    let missingMicrophoneBlocked = !microphoneSetup.canStart
    microphoneSetup.microphoneUID = "preview-external"
    let microphoneSelectionPassed = missingMicrophoneBlocked && microphoneSetup.canStart
        && microphoneSetup.selectedInputName == "USB Microphone" && microphoneSetup.phase == .ready && !microphoneSetup.workerBusy
    let modifierSidePassed = ShortcutManager.modifierIsDown(keyCode: 62, eventFlags: 0x42000)
        && !ShortcutManager.modifierIsDown(keyCode: 59, eventFlags: 0x42000)
        && !ShortcutManager.modifierIsDown(keyCode: 62, eventFlags: 0x40001)
        && ShortcutManager.modifierIsDown(keyCode: 59, eventFlags: 0x40001)
    var recordedShortcut: DictationShortcut?
    var recorderReleased = false
    let recorder = ShortcutCaptureNSView { value, released, _ in recordedShortcut = value; recorderReleased = released }
    func keyEvent(_ type: NSEvent.EventType, code: UInt16, flags: UInt, text: String = "") -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    recorder.flagsChanged(with: keyEvent(.flagsChanged, code: 62, flags: 0x42000))
    let waitsForRelease = !recorderReleased && recordedShortcut == nil
    recorder.flagsChanged(with: keyEvent(.flagsChanged, code: 62, flags: 0))
    let rightControlRecorded = recorderReleased && recordedShortcut == .rightControl
    recorder.flagsChanged(with: keyEvent(.flagsChanged, code: 59, flags: 0x40001))
    recorder.flagsChanged(with: keyEvent(.flagsChanged, code: 59, flags: 0))
    let leftControlRecorded = recorderReleased && recordedShortcut?.keyCode == 59
    recorder.keyDown(with: keyEvent(.keyDown, code: 2, flags: 0x60003, text: "D"))
    recorder.keyUp(with: keyEvent(.keyUp, code: 2, flags: 0x60003, text: "D"))
    let chordWaitsForRelease = !recorderReleased && recordedShortcut == .controlShiftD
    recorder.flagsChanged(with: keyEvent(.flagsChanged, code: 59, flags: 0))
    let chordRecorded = recorderReleased && recordedShortcut == .controlShiftD
    recorder.keyDown(with: keyEvent(.keyDown, code: 0, flags: 0, text: "a"))
    recorder.keyUp(with: keyEvent(.keyUp, code: 0, flags: 0, text: "a"))
    let recorderEventsPassed = waitsForRelease && rightControlRecorded && leftControlRecorded && chordWaitsForRelease
        && chordRecorded && recordedShortcut == nil && recorderReleased

    let home = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let shortcutSheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let homeWithoutSheet = AppDelegate.presentationWindow(requested: home, windows: [home, settings]) === home
    settings.beginSheet(shortcutSheet)
    let reopenedToSheet = AppDelegate.presentationWindow(requested: home, windows: [home, settings, shortcutSheet]) === shortcutSheet
    let settingsKeepsSheet = AppDelegate.presentationWindow(requested: settings, windows: [home, settings, shortcutSheet]) === shortcutSheet
    settings.endSheet(shortcutSheet); shortcutSheet.orderOut(nil)
    let homeAfterSheet = AppDelegate.presentationWindow(requested: home, windows: [home, settings]) === home
    home.orderOut(nil); settings.orderOut(nil)
    let sheetRoutingPassed = homeWithoutSheet && reopenedToSheet && settingsKeepsSheet && homeAfterSheet

    let recoveryWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    let escapeScopePassed = AppDelegate.canHideRecovery(for: recoveryWindow, recovery: recoveryWindow)
        && !AppDelegate.canHideRecovery(for: otherWindow, recovery: recoveryWindow)
        && !AppDelegate.canHideRecovery(for: nil, recovery: recoveryWindow)
        && !AppDelegate.canHideRecovery(for: otherWindow, recovery: nil)

    let navigation = AppNavigation()
    let navigationModel = fixture("ready")
    navigationModel.practiceText = "Synthetic practice retained across pages."
    func navigate(_ page: AppPage, practice: Bool? = nil, blocked: Bool = false, back: Bool = false) -> Bool {
        navigation.navigate(to: page, practice: practice, back: back, model: navigationModel,
            blocked: blocked, confirmPracticeExit: { false })
    }
    var navigationPassed = navigate(.home, practice: true)
        && AppDelegate.practiceIsActive(navigation: navigation, windowIsKey: true, appIsActive: true, hasDialog: false)
        && !AppDelegate.practiceIsActive(navigation: navigation, windowIsKey: false, appIsActive: true, hasDialog: false)
        && !AppDelegate.practiceIsActive(navigation: navigation, windowIsKey: true, appIsActive: false, hasDialog: false)
        && !AppDelegate.practiceIsActive(navigation: navigation, windowIsKey: true, appIsActive: true, hasDialog: true)
    navigationPassed = !navigate(.settings, blocked: true) && navigation.page == .home && navigationPassed
    _ = navigationModel.beginShortcutEditing()
    navigationPassed = !navigate(.help) && navigation.page == .home && navigationPassed
    navigationModel.endShortcutEditing()
    navigationPassed = navigate(.settings) && !AppDelegate.practiceIsActive(navigation: navigation,
        windowIsKey: true, appIsActive: true, hasDialog: false) && navigationPassed
    navigationPassed = navigate(.help) && navigation.backDestination == .settings && navigationPassed
    navigationPassed = navigate(navigation.backDestination, back: true) && navigation.page == .settings && navigationPassed
    navigationPassed = navigate(.home, practice: false) && !navigation.showsPractice && navigationPassed
    navigationPassed = navigate(.setup) && navigationPassed
    navigation.setupStep = 3
    navigationPassed = navigate(.settings) && navigate(navigation.backDestination, back: true)
        && navigation.page == .setup && navigation.setupStep == 3 && navigationPassed
    navigationPassed = navigationModel.phase == .ready && !navigationModel.workerBusy
        && navigationModel.practiceText == "Synthetic practice retained across pages." && navigationPassed

    let leavingPractice = fixture("practice-recording")
    let practiceNavigation = AppNavigation()
    _ = practiceNavigation.navigate(to: .home, practice: true, model: leavingPractice, blocked: false, confirmPracticeExit: { false })
    let stayedInPractice = !practiceNavigation.navigate(to: .settings, model: leavingPractice, blocked: false, confirmPracticeExit: { false })
        && practiceNavigation.showsPractice && leavingPractice.phase == .recording
    let canceledOnCollapse = practiceNavigation.navigate(to: .home, practice: false, model: leavingPractice, blocked: false, confirmPracticeExit: { true })
        && !practiceNavigation.showsPractice && leavingPractice.phase == .ready
    let completingPractice = fixture("practice-transcribing")
    let recoveredDuringAlert = !practiceNavigation.allowPracticeExit(model: completingPractice) {
        completingPractice.cancel(); completingPractice.configurePreview("practice-recovery"); return true
    } && completingPractice.phase == .recovery && !completingPractice.pendingText.isEmpty
    completingPractice.cancel(); completingPractice.configurePreview("practice-recording")
    let laterSessionKept = !practiceNavigation.allowPracticeExit(model: completingPractice) {
        completingPractice.cancel(); completingPractice.configurePreview("practice-recording"); return true
    } && completingPractice.phase == .recording
    let completedDuringAlert = practiceNavigation.allowPracticeExit(model: completingPractice) {
        completingPractice.cancel(); completingPractice.configurePreview("practice-unloading"); return true
    } && completingPractice.phase == .ready && completingPractice.workerBusy
    let practiceNavigationPassed = stayedInPractice && canceledOnCollapse && recoveredDuringAlert && laterSessionKept && completedDuringAlert

    let recoveryNavigation = AppNavigation()
    let pending = fixture("recovery")
    let pendingWords = pending.pendingText
    var recoveryNavigationPassed = true
    for page: AppPage in [.recovery, .home, .settings, .help, .recovery] {
        recoveryNavigationPassed = recoveryNavigation.navigate(to: page, model: pending, blocked: false, confirmPracticeExit: { false })
            && pending.pendingText == pendingWords && pending.phase == .recovery && !pending.canStart && recoveryNavigationPassed
    }
    recoveryNavigation.recoveryDismissed()
    recoveryNavigationPassed = recoveryNavigation.page == .home && pending.pendingText == pendingWords && recoveryNavigationPassed
    // Optional history storage, exercised only in a temporary folder with synthetic text.
    let historyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Within.HistoryFixture.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: historyFolder) }
    let historyStore = HistoryStore(directory: historyFolder)
    let historyFile = historyFolder.appendingPathComponent("dictation-history.json")
    let sample = HistoryPolicy.adding("synthetic history words", at: Date(), to: [], retention: .week)
    try historyStore.save(sample)
    let fileMode = (try FileManager.default.attributesOfItem(atPath: historyFile.path)[.posixPermissions] as? NSNumber)?.intValue
    let folderMode = (try FileManager.default.attributesOfItem(atPath: historyFolder.path)[.posixPermissions] as? NSNumber)?.intValue
    let excludedFromBackup = try historyFolder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    let reloaded = try historyStore.load() == sample
    let noStagingLeft = try FileManager.default.contentsOfDirectory(atPath: historyFolder.path) == ["dictation-history.json"]
    try historyStore.save([])
    let historyStorePassed = fileMode == 0o600 && folderMode == 0o700 && excludedFromBackup && reloaded && noStagingLeft
        && !FileManager.default.fileExists(atPath: historyFile.path)
    // Previews never save history; choosing Off clears the in-memory list, shorter retention prunes it.
    let historyPreview = fixture("history")
    let fixtureCount = historyPreview.history.count
    historyPreview.chooseHistoryRetention(.day)
    let prunedToDay = historyPreview.history.count < fixtureCount && !historyPreview.history.isEmpty
    historyPreview.chooseHistoryRetention(.off)
    let unchosen = fixture("ready")
    let historyPolicyPassed = prunedToDay && historyPreview.history.isEmpty && unchosen.historyRetention == nil
        && unchosen.privacySummary.contains("No recordings or dictation history saved")
    // Notes storage in a temporary folder: owner-only, atomic, per-note files kept in backups.
    let notesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Within.NotesFixture.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: notesFolder) }
    let notesStore = NotesStore(directory: notesFolder)
    var fixtureNote = Note(title: "Synthetic", created: Date(), body: "synthetic note words")
    try notesStore.save(fixtureNote)
    fixtureNote.body = NoteText.appending("more synthetic words", to: fixtureNote.body)
    try notesStore.save(fixtureNote)
    let noteFile = notesFolder.appendingPathComponent("\(fixtureNote.id.uuidString).json")
    let noteMode = (try FileManager.default.attributesOfItem(atPath: noteFile.path)[.posixPermissions] as? NSNumber)?.intValue
    let notesFolderMode = (try FileManager.default.attributesOfItem(atPath: notesFolder.path)[.posixPermissions] as? NSNumber)?.intValue
    let notesInBackups = try notesFolder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true
    let reloadedNotes = notesStore.loadAll()
    try notesStore.delete(fixtureNote.id)
    let notesFolderEmpty = try FileManager.default.contentsOfDirectory(atPath: notesFolder.path).isEmpty
    let notesStorePassed = noteMode == 0o600 && notesFolderMode == 0o700 && notesInBackups
        && reloadedNotes.notes == [fixtureNote] && reloadedNotes.unreadable == 0 && notesFolderEmpty
    // One capture at a time: while a note records, dictation refuses and cancel keeps the note.
    let noteSession = fixture("note-recording")
    noteSession.start(practice: false)
    let dictationRefused = noteSession.message.contains("Stop your note recording") && noteSession.isRecordingNote && noteSession.phase == .recording
    noteSession.startNoteRecording(noteSession.notes[1].id)
    let secondRecordingRefused = noteSession.recordingNoteID == noteSession.notes[0].id
    // Canceling while a note is still preparing ends cleanly instead of bouncing between stop and cancel.
    let preparingNote = fixture("note-preparing")
    preparingNote.cancel(cause: .cancelButton)
    let preparingCancelEnded = preparingNote.phase == .ready && preparingNote.message.contains("canceled before it started")
    let notesGuardsPassed = dictationRefused && secondRecordingRefused && !noteSession.canStart && preparingCancelEnded
    // Previews never reach the network or store update choices.
    let updatePreview = fixture("update-available")
    updatePreview.checkForUpdates()
    updatePreview.setAutomaticUpdateChecks(false)
    // Mute is opt-in and a preview never changes it or touches the output device.
    let mutePreview = fixture("ready")
    let muteDefaultOff = !mutePreview.muteOutputWhileDictating
    mutePreview.muteOutputWhileDictating = true
    let updatesPassed = muteDefaultOff && updatePreview.availableUpdate?.build == 12 && !updatePreview.checkingForUpdates
        && updatePreview.automaticUpdateChecks == false && fixture("ready").automaticUpdateChecks == nil
        && fixture("ready").updateSummary == "Not checked yet."
    let previewPreferencesUnchanged = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) as? NSObject } == preferencesBefore
    let transitionsPassed = invalidationPassed && practiceLifecyclePassed && practiceCloseRecheckPassed && busyFeedbackPassed && busyFeedbackCleared && routingPassed && setupPassed && escapeScopePassed && shortcutEditingPassed && microphoneSelectionPassed && modifierSidePassed && recorderEventsPassed && sheetRoutingPassed && navigationPassed && practiceNavigationPassed && recoveryNavigationPassed
    let board = NSPasteboard(name: .init("Within.Fixture.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.clearContents()
    let plain = NSPasteboardItem(); plain.setString("synthetic prior text", forType: .string)
    plain.setData(Data("{\\rtf1 synthetic prior text}".utf8), forType: .rtf)
    let second = NSPasteboardItem(); second.setData(Data([0, 1, 2, 3, 255]), forType: .init("com.madeordinary.fixture"))
    guard board.writeObjects([plain, second]) else { throw CompatibilityPaste.Failure.writeFailed }
    let snapshot = try CompatibilityPaste.snapshot(board)
    board.clearContents(); board.setString("synthetic transcript", forType: .string)
    let lease = ClipboardLease(ownedChangeCount: board.changeCount)
    let restored = CompatibilityPaste.restore(snapshot, to: board, lease: lease)
    let roundtrip = restored && board.pasteboardItems?.count == 2
        && board.string(forType: .string) == "synthetic prior text"
        && board.pasteboardItems?.first?.data(forType: .rtf) == Data("{\\rtf1 synthetic prior text}".utf8)
        && board.pasteboardItems?.last?.data(forType: .init("com.madeordinary.fixture")) == Data([0, 1, 2, 3, 255])
    let old = try CompatibilityPaste.snapshot(board)
    board.clearContents(); board.setString("temporary dictation", forType: .string)
    let oldLease = ClipboardLease(ownedChangeCount: board.changeCount)
    board.clearContents(); board.setString("new user copy", forType: .string)
    _ = CompatibilityPaste.restore(old, to: board, lease: oldLease)
    let userCopyPreserved = board.string(forType: .string) == "new user copy"
    board.clearContents()
    board.setData(Data(repeating: 1, count: 8_388_609), forType: .init("public.data"))
    var oversizeRefused = false
    do { _ = try CompatibilityPaste.snapshot(board) } catch { oversizeRefused = true }
    let report: [String: Any] = ["syntheticNamedPasteboardOnly": true, "multiItemMultiFormatRestored": roundtrip, "restorationWriteSucceeded": restored,
        "newUserCopyPreserved": userCopyPreserved, "oversizedSnapshotRefused": oversizeRefused,
        "readinessStatesPassed": readinessPassed, "previewPreferencesUnchanged": previewPreferencesUnchanged,
        "modelInvalidationAndRepairPassed": invalidationPassed, "practiceLifecyclePassed": practiceLifecyclePassed,
        "busyFeedbackPassed": busyFeedbackPassed, "practiceRoutingPassed": routingPassed,
        "busyFeedbackCleared": busyFeedbackCleared,
        "practiceCloseRecheckPassed": practiceCloseRecheckPassed,
        "setupWithoutRecordingPassed": setupPassed, "recoveryEscapeScopePassed": escapeScopePassed,
        "shortcutEditingWithoutRecordingPassed": shortcutEditingPassed, "microphoneSelectionWithoutRecordingPassed": microphoneSelectionPassed,
        "modifierSideEventFlagsPassed": modifierSidePassed,
        "syntheticShortcutRecorderEventsPassed": recorderEventsPassed,
        "reopenAndNavigationPreserveSheetPassed": sheetRoutingPassed,
        "singleWindowNavigationWithoutRecordingPassed": navigationPassed,
        "practiceExitConfirmationAndRacesPassed": practiceNavigationPassed,
        "navigationPreservesPendingWordsPassed": recoveryNavigationPassed,
        "historyStoreOwnerOnlyBackupExcludedPassed": historyStorePassed,
        "historyRetentionPreviewPassed": historyPolicyPassed,
        "notesStoreOwnerOnlyAtomicPassed": notesStorePassed,
        "notesOneCaptureAtATimePassed": notesGuardsPassed,
        "updatePreviewWithoutNetworkPassed": updatesPassed,
        "allPassed": roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed && historyStorePassed && historyPolicyPassed && notesStorePassed && notesGuardsPassed && updatesPassed,
        "notTested": ["live note recording with a microphone", "note lock/sleep pause on a real Mac", "live history recording after real insertion", "physical custom shortcut events", "global paste shortcut", "live app insertion", "clipboard managers", "Universal Clipboard", "VoiceOver", "modal keyboard events", "login launch"]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    guard roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed && historyStorePassed && historyPolicyPassed && notesStorePassed && notesGuardsPassed && updatesPassed else { throw CompatibilityPaste.Failure.writeFailed }
}
