import AppKit
import WithinCore

/// A named fixture pasteboard that refuses every write, for the copy-failure paths.
private final class RefusingPasteboard: NSPasteboard {
    override func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool { false }
}

/// Uses a uniquely named, synthetic pasteboard. Never reads the user's clipboard.
@MainActor
func nativeChecks(to output: URL) throws {
    _ = NSApplication.shared
    let manifest = try loadManifest()
    let preferenceKeys = ["soundsEnabled", "compatibilityPaste", "activationMode", "alternateShortcut", "dictationShortcut", "microphoneUID", "setupComplete", "historyRetention", "automaticUpdateChecks", "lastUpdateCheck", "muteOutputWhileDictating", "outputMuteRecord", "showPersonalDictionary"]
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
    // Personal dictionary storage in a temporary folder with synthetic words: owner-only, atomic, kept in backups.
    func mode(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue }
    func names(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    let dictionaryFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Within.DictionaryFixture.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dictionaryFolder) }
    let dictionaryStore = DictionaryStore(directory: dictionaryFolder)
    let dictionaryFile = dictionaryFolder.appendingPathComponent("personal-dictionary.json")
    let words = PersonalDictionary(entries: [DictionaryEntry(heardAs: ["synthetic word"], writeAs: "Synthetic", created: Date(timeIntervalSince1970: 1_800_000_000))])
    var olderWords = words
    olderWords.version = 0
    try dictionaryStore.save(olderWords)
    let dictionaryOwnerOnly = mode(dictionaryFile) == 0o600 && mode(dictionaryFolder) == 0o700
    let dictionaryInBackups = try dictionaryFolder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true
        && dictionaryFile.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true
    let dictionaryReloaded = dictionaryStore.load() == .loaded(words) && names(dictionaryFolder) == ["personal-dictionary.json"]
    let staleStaging = dictionaryFolder.appendingPathComponent(".personal-dictionary-\(UUID().uuidString).tmp")
    FileManager.default.createFile(atPath: staleStaging.path, contents: Data("{".utf8))
    let staleSwept = dictionaryStore.load() == .loaded(words) && names(dictionaryFolder) == ["personal-dictionary.json"]
    // Too large, broken or newer files are reported and left byte for byte; the size limit itself still loads.
    let saved = try Data(contentsOf: dictionaryFile)
    let padded = { (size: Int) in saved + Data(repeating: 0x20, count: size - saved.count) }
    var dictionaryLoadsPassed = true
    for (bytes, expected) in [(padded(PersonalDictionary.maximumFileSize), DictionaryStore.Loaded.loaded(words)),
                              (padded(PersonalDictionary.maximumFileSize + 1), .unreadable),
                              (Data(#"{"version": 1, "enabled": tru"#.utf8), .unreadable),
                              (Data(#"{"version": 2, "words": {"synthetic": [1]}}"#.utf8), .newerVersion)] {
        try bytes.write(to: dictionaryFile)
        dictionaryLoadsPassed = dictionaryStore.load() == expected && (try? Data(contentsOf: dictionaryFile)) == bytes && dictionaryLoadsPassed
    }
    // Every save makes the folder owner-only again, whatever it was left as.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dictionaryFolder.path)
    try dictionaryStore.save(words)
    let folderTightened = mode(dictionaryFolder) == 0o700
    let firstAside = try dictionaryStore.setAside()
    try dictionaryStore.save(words)
    let secondAside = try dictionaryStore.setAside()
    let setAsideKept = firstAside != secondAside && !FileManager.default.fileExists(atPath: dictionaryFile.path)
        && dictionaryStore.setAsideFiles().map(\.lastPathComponent) == [firstAside, secondAside].map(\.lastPathComponent).sorted()
        && [firstAside, secondAside].allSatisfy { mode($0) == 0o600 && (try? Data(contentsOf: $0)).map(PersonalDictionary.decode) == .loaded(words) }
    try dictionaryStore.save(words)
    FileManager.default.createFile(atPath: staleStaging.path, contents: nil)
    try dictionaryStore.removeAll()
    let dictionaryRemoved = names(dictionaryFolder).isEmpty && dictionaryStore.load() == .missing
    // First launch: no folder at all is an empty dictionary, and deleting it is not a failure.
    let absent = DictionaryStore(directory: dictionaryFolder.appendingPathComponent("Absent.noindex", isDirectory: true))
    let firstLaunchEmpty = absent.load() == .missing && (try? absent.removeAll()) != nil && names(dictionaryFolder).isEmpty
    let dictionaryStorePassed = dictionaryOwnerOnly && dictionaryInBackups && dictionaryReloaded && staleSwept
        && dictionaryLoadsPassed && folderTightened && setAsideKept && dictionaryRemoved && firstLaunchEmpty
    // A file Within can't use is never written over by any change the model offers. Once set aside, saving works again.
    let protectedBase = FileManager.default.temporaryDirectory.appendingPathComponent("Within.DictionaryProtectedFixture.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: protectedBase) }
    let protectedFolder = protectedBase.appendingPathComponent("Dictionary.noindex", isDirectory: true)
    let protectedFile = protectedFolder.appendingPathComponent("personal-dictionary.json")
    try FileManager.default.createDirectory(at: protectedFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var dictionaryProtectedPassed = true
    for (bytes, state) in [(Data(#"{"version": 1, "enabled": tru"#.utf8), DictionaryState.unreadable),
                           (Data(#"{"version": 2, "words": {"synthetic": [1]}}"#.utf8), .newerVersion)] {
        // A hand-made file is often 0644; once set aside it is owner-only.
        try bytes.write(to: protectedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: protectedFile.path)
        let model = AppModel(manifest: manifest, base: protectedBase, dictionaryFixture: true)
        let opened = model.dictionaryState == state && model.dictionaryStore != nil && model.dictionaryMatcher.isEmpty
        model.setDictionaryEnabled(false)
        _ = model.addDictionaryEntry(heardAs: ["synthetic word"], writeAs: "Synthetic")
        _ = model.updateDictionaryEntry(UUID(), heardAs: ["synthetic word"], writeAs: "Synthetic")
        model.setDictionaryEntry(UUID(), enabled: false)
        model.deleteDictionaryEntry(UUID())
        model.deleteAllDictionaryEntries()
        let untouched = (try? Data(contentsOf: protectedFile)) == bytes && names(protectedFolder) == ["personal-dictionary.json"]
            && model.dictionaryState == state && model.dictionary == PersonalDictionary() && model.dictionaryMatcher.isEmpty
        model.startNewDictionary()
        let aside = model.dictionaryStore?.setAsideFiles() ?? []
        let keptAside = aside.count == 1 && (try? Data(contentsOf: aside[0])) == bytes && mode(aside[0]) == 0o600
            && model.dictionaryHasSetAside && model.dictionaryState == .missing
        let savesAgain = model.addDictionaryEntry(heardAs: ["synthetic word"], writeAs: "Synthetic").isEmpty && model.dictionaryState == .loaded
            && model.dictionaryStore?.load() == .loaded(model.dictionary) && !model.dictionaryMatcher.isEmpty
        model.deleteDictionaryFiles()
        let cleared = names(protectedFolder).isEmpty && model.dictionaryState == .missing && !model.dictionaryHasSetAside
        dictionaryProtectedPassed = opened && untouched && keptAside && savesAgain && cleared && dictionaryProtectedPassed
    }
    // A folder Within can't search is not an empty dictionary: nothing is saved over the file, and nothing claims it was deleted.
    try DictionaryStore(directory: protectedFolder).save(words)
    let reachable = try Data(contentsOf: protectedFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: protectedFolder.path)
    let blocked = AppModel(manifest: manifest, base: protectedBase, dictionaryFixture: true)
    let blockedOpened = blocked.dictionaryState == .unreadable && blocked.dictionaryMatcher.isEmpty
        && (try? DictionaryStore(directory: protectedFolder).removeAll()) == nil
    blocked.setDictionaryEnabled(false)
    _ = blocked.addDictionaryEntry(heardAs: ["synthetic word"], writeAs: "Synthetic")
    blocked.deleteDictionaryFiles()
    // Restored before anything is read back, and so the folder can be removed; nothing since the change above can throw.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedFolder.path)
    let unreachableKept = blockedOpened && (try? Data(contentsOf: protectedFile)) == reachable && names(protectedFolder) == ["personal-dictionary.json"]
        && blocked.dictionaryState == .unreadable && blocked.dictionaryMessage.contains("couldn’t be deleted")
    dictionaryProtectedPassed = unreachableKept && dictionaryProtectedPassed
    // Previews change the dictionary in memory only: no store, no file under the unused base, no preference written.
    let dictionaryPreview = fixture("ready")
    let unusedDictionary = output.deletingLastPathComponent().appendingPathComponent("unused").appendingPathComponent("Dictionary.noindex")
    let offStaysEmpty = dictionaryPreview.addDictionaryEntry(heardAs: ["synthetic word"], writeAs: "Synthetic").isEmpty
        && dictionaryPreview.dictionary.entries.count == 1 && dictionaryPreview.dictionaryMatcher.isEmpty
    dictionaryPreview.previewDictionary(.missing)
    let typedSaved = dictionaryPreview.addDictionaryEntry(heardAs: ["  synthetic   word ", "", "synthetic wurd"], writeAs: " Synthetic ").isEmpty
    let typed = dictionaryPreview.dictionary.entries.first
    let normalizedSaved = dictionaryPreview.dictionary.entries.count == 1 && typed?.writeAs == "Synthetic"
        && typed?.heardAs == ["synthetic word", "synthetic wurd"] && dictionaryPreview.dictionaryMatcher.apply(to: "a synthetic wurd").text == "a Synthetic"
    let rawRefused = dictionaryPreview.addDictionaryEntry(heardAs: ["", "other\tword"], writeAs: "Other\t") == [.multilineWriteAs, .phraseCharacters(1)]
    let typedID = typed?.id ?? UUID()
    let updated = dictionaryPreview.updateDictionaryEntry(typedID, heardAs: ["synthetic phrase"], writeAs: "Synthetic").isEmpty
        && dictionaryPreview.dictionaryMatcher.apply(to: "a synthetic phrase").text == "a Synthetic"
    dictionaryPreview.setDictionaryEntry(typedID, enabled: false)
    let entryOff = dictionaryPreview.dictionary.entries.first?.enabled == false && dictionaryPreview.dictionaryMatcher.isEmpty
    dictionaryPreview.deleteDictionaryEntry(typedID)
    let entryDeleted = dictionaryPreview.dictionary.entries.isEmpty
    _ = dictionaryPreview.addDictionaryEntry(heardAs: ["synthetic word"], writeAs: "Synthetic")
    dictionaryPreview.setDictionaryEnabled(false)
    let switchedOff = !dictionaryPreview.dictionary.enabled && dictionaryPreview.dictionary.entries.count == 1 && dictionaryPreview.dictionaryMatcher.isEmpty
    dictionaryPreview.deleteAllDictionaryEntries()
    let previewCleared = dictionaryPreview.dictionary == PersonalDictionary() && dictionaryPreview.dictionaryState == .missing
    _ = dictionaryPreview.addDictionaryEntry(heardAs: ["synthetic word"], writeAs: "Synthetic")
    dictionaryPreview.configurePreview("ready")
    let previewReset = dictionaryPreview.dictionary == PersonalDictionary() && !dictionaryPreview.showsPersonalDictionary
    let dictionaryPreviewPassed = offStaysEmpty && typedSaved && normalizedSaved && rawRefused && updated && entryOff && entryDeleted
        && switchedOff && previewCleared && previewReset && dictionaryPreview.dictionaryStore == nil
        && !FileManager.default.fileExists(atPath: unusedDictionary.path)
    // The dictionary at the speech-result boundary: synthetic entries, preview models and named pasteboards only.
    let transcribed = "I moved the ticket to gira and asked shivon to review it."
    let spellings = "I moved the ticket to Jira and asked Siobhan to review it."
    let recoveryLiteral = "The best ideas often start as a few ordinary words. Let’s make a little room for them."
    let dictionaryBoard = NSPasteboard(name: .init("Within.DictionaryFixture.\(UUID().uuidString)"))
    defer { dictionaryBoard.releaseGlobally() }
    let refusingBoard = NSPasteboard(name: .init("Within.DictionaryFixture.\(UUID().uuidString)"))
    defer { refusingBoard.releaseGlobally() }
    object_setClass(refusingBoard, RefusingPasteboard.self)
    // Recovery keeps both versions across pages; the switch swaps them and Discard clears both.
    let switching = fixture("recovery-dictionary")
    var recoverySwitchPassed = switching.pendingText == spellings && switching.session.originalTranscription == transcribed
        && switching.session.dictionaryChanges.map(\.written) == ["Jira", "Siobhan"] && !switching.session.showingOriginal
    switching.switchPendingWords()
    recoverySwitchPassed = switching.pendingText == transcribed && switching.session.showingOriginal
        && switching.session.originalTranscription == nil && recoverySwitchPassed
    let switchNavigation = AppNavigation()
    for page: AppPage in [.recovery, .home, .settings, .help, .recovery] {
        recoverySwitchPassed = switchNavigation.navigate(to: page, model: switching, blocked: false, confirmPracticeExit: { false })
            && switching.pendingText == transcribed && switching.session.alternateTranscript == spellings && recoverySwitchPassed
    }
    switching.switchPendingWords()
    recoverySwitchPassed = switching.pendingText == spellings && switching.session.originalTranscription == transcribed && recoverySwitchPassed
    let unchangedRecovery = fixture("recovery")
    unchangedRecovery.switchPendingWords()
    switching.discard()
    let dictionaryRecoverySwitchPassed = recoverySwitchPassed && unchangedRecovery.pendingText == recoveryLiteral && !unchangedRecovery.session.showingOriginal
        && switching.pendingText.isEmpty && switching.session.alternateTranscript == nil && switching.session.dictionaryChanges.isEmpty
        && switching.lastDictationChange == nil && switching.phase == .ready
    // Copy from recovery keeps the original transcription in memory; Copy original transcription clears it only when the write succeeds.
    let copying = fixture("recovery-dictionary")
    let copiedSession = copying.session.id
    copying.copyPending(pasteboard: dictionaryBoard)
    let held = copying.lastDictationChange
    var copyOriginalPassed = dictionaryBoard.string(forType: .string) == spellings && copying.phase == .ready
        && held?.original == transcribed && held?.sessionID == copiedSession && held?.changes.count == 2
    copying.copyLastOriginal(pasteboard: refusingBoard)
    copyOriginalPassed = copying.lastDictationChange == held && copying.lastChangeCopyFailed && copyOriginalPassed
    copying.copyLastOriginal(pasteboard: dictionaryBoard)
    copyOriginalPassed = dictionaryBoard.string(forType: .string) == transcribed && copying.lastDictationChange == nil
        && !copying.lastChangeCopyFailed && copying.message.hasPrefix("Copied the original transcription") && copyOriginalPassed
    // An earlier dictation's timer never clears a later one. Expiring while the row has focus drops the words and keeps the row until focus leaves.
    let earlier = LastDictationChange(sessionID: UUID(), original: transcribed, changes: held?.changes ?? [], time: Date())
    let later = LastDictationChange(sessionID: UUID(), original: "synthetic later words", changes: held?.changes ?? [], time: Date())
    let timed = fixture("ready")
    timed.previewLastDictationChange(earlier); timed.previewLastDictationChange(later)
    timed.expireLastDictationChange(sessionID: earlier.sessionID)
    let earlierTimerIgnored = timed.lastDictationChange == later
    timed.expireLastDictationChange(sessionID: later.sessionID)
    let ownTimerCleared = timed.lastDictationChange == nil && !timed.lastChangeExpiredWhileFocused
    timed.previewLastDictationChange(later); timed.lastChangeRowHasFocus = true
    timed.expireLastDictationChange(sessionID: later.sessionID)
    let focusedExpiry = timed.lastDictationChange == nil && timed.lastChangeExpiredWhileFocused
    timed.lastChangeRowLostFocus()
    copyOriginalPassed = earlierTimerIgnored && ownTimerCleared && focusedExpiry && !timed.lastChangeExpiredWhileFocused && copyOriginalPassed
    // Only a later dictation that changed words replaces it: not one without changes, and not one where the original transcription was used.
    let noChange = fixture("recovery")
    noChange.previewLastDictationChange(earlier); noChange.copyPending(pasteboard: dictionaryBoard)
    let replacing = fixture("recovery-dictionary")
    let replacingSession = replacing.session.id
    replacing.previewLastDictationChange(earlier); replacing.copyPending(pasteboard: dictionaryBoard)
    let originalUsed = fixture("recovery-dictionary")
    originalUsed.previewLastDictationChange(earlier); originalUsed.switchPendingWords(); originalUsed.copyPending(pasteboard: dictionaryBoard)
    copyOriginalPassed = noChange.lastDictationChange == earlier && replacing.lastDictationChange?.sessionID == replacingSession
        && originalUsed.lastDictationChange == earlier && dictionaryBoard.string(forType: .string) == transcribed && copyOriginalPassed
    // Hide, clearing or deleting history, history Off, and lock or sleep (dictation and note) clear it; another retention keeps it.
    let clears: [(AppModel) -> Void] = [{ $0.dismissLastDictationChange() }, { $0.clearHistory() }, { $0.deleteHistoryEntry(UUID()) },
                                         { $0.chooseHistoryRetention(.off) }, { $0.cancelForBoundary() }]
    for clear in clears {
        let model = fixture("inserted-dictionary")
        let seeded = model.lastDictationChange != nil
        clear(model)
        copyOriginalPassed = seeded && model.lastDictationChange == nil && copyOriginalPassed
    }
    let keptByWeek = fixture("inserted-dictionary")
    keptByWeek.chooseHistoryRetention(.week)
    let noteBoundary = fixture("note-recording")
    noteBoundary.soundsEnabled = false
    noteBoundary.previewLastDictationChange(earlier); noteBoundary.cancelForBoundary()
    let dictionaryCopyOriginalPassed = keptByWeek.lastDictationChange != nil && noteBoundary.lastDictationChange == nil && copyOriginalPassed
    // Practice: Use original transcription restores exactly the appended words until any edit, even one that retypes the same text.
    let practicePrefix = "A little more room for an ordinary idea.\n"
    let restoring = fixture("practice-dictionary")
    var practiceRestorePassed = restoring.practiceText == practicePrefix + spellings && restoring.practiceChange?.restorable == true
    restoring.useOriginalPracticeText()
    practiceRestorePassed = restoring.practiceText == practicePrefix + transcribed && restoring.practiceChange == nil && practiceRestorePassed
    let retyped = fixture("practice-dictionary")
    let retypedText = retyped.practiceText
    retyped.practiceText.removeLast(); retyped.practiceText += "."
    retyped.useOriginalPracticeText()
    practiceRestorePassed = retyped.practiceText == retypedText && retyped.practiceChange?.restorable == false
        && retyped.practiceChange?.original == transcribed && practiceRestorePassed
    retyped.clearPractice()
    // Emptying the field by hand keeps the original transcription shown until Clear.
    let emptied = fixture("practice-dictionary")
    emptied.practiceText = ""
    practiceRestorePassed = emptied.practiceChange?.restorable == false && emptied.practiceChange?.original == transcribed && practiceRestorePassed
    emptied.clearPractice()
    let dictionaryPracticeRestorePassed = practiceRestorePassed && retyped.practiceText.isEmpty && retyped.practiceChange == nil
        && emptied.practiceChange == nil && fixture("practice").practiceChange == nil
    // With the developer default off, an off dictionary, every word off, or no words, dictation text is exactly as transcribed.
    let plainRecovery = fixture("recovery")
    var emptyDictionaryPassed = plainRecovery.pendingText == recoveryLiteral && plainRecovery.session.alternateTranscript == nil
        && plainRecovery.session.dictionaryChanges.isEmpty && !plainRecovery.showsPersonalDictionary && plainRecovery.dictionaryMatcher.isEmpty
    plainRecovery.copyPending(pasteboard: dictionaryBoard)
    emptyDictionaryPassed = dictionaryBoard.string(forType: .string) == recoveryLiteral && plainRecovery.lastDictationChange == nil && emptyDictionaryPassed
    let defaultOff = fixture("ready")
    _ = defaultOff.addDictionaryEntry(heardAs: ["gira"], writeAs: "Jira")
    var dictionaryOff = AppModel.previewWords
    dictionaryOff.enabled = false
    var everyWordOff = AppModel.previewWords
    for index in everyWordOff.entries.indices { everyWordOff.entries[index].enabled = false }
    var matchers = [defaultOff.dictionaryMatcher]
    for loaded in [DictionaryStore.Loaded.missing, .loaded(PersonalDictionary()), .loaded(dictionaryOff), .loaded(everyWordOff)] {
        let model = fixture("ready")
        model.previewDictionary(loaded)
        matchers.append(model.dictionaryMatcher)
    }
    let emptyDictionaryLeavesDictationUnchangedPassed = emptyDictionaryPassed && defaultOff.dictionary.entries.count == 1
        && matchers.allSatisfy { $0.isEmpty && $0.apply(to: transcribed) == DictionaryResult(unchanged: transcribed) }
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
        "dictionaryStoreOwnerOnlyAtomicKeptInBackupsPassed": dictionaryStorePassed,
        "dictionaryProtectedFileIsNeverOverwrittenPassed": dictionaryProtectedPassed,
        "dictionaryPreviewWritesNothingPassed": dictionaryPreviewPassed,
        "dictionaryRecoverySwitchPassed": dictionaryRecoverySwitchPassed,
        "dictionaryCopyOriginalPassed": dictionaryCopyOriginalPassed,
        "dictionaryPracticeRestorePassed": dictionaryPracticeRestorePassed,
        "emptyDictionaryLeavesDictationUnchangedPassed": emptyDictionaryLeavesDictationUnchangedPassed,
        "updatePreviewWithoutNetworkPassed": updatesPassed,
        "allPassed": roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed && historyStorePassed && historyPolicyPassed && notesStorePassed && notesGuardsPassed && dictionaryStorePassed && dictionaryProtectedPassed && dictionaryPreviewPassed && dictionaryRecoverySwitchPassed && dictionaryCopyOriginalPassed && dictionaryPracticeRestorePassed && emptyDictionaryLeavesDictationUnchangedPassed && updatesPassed,
        "notTested": ["live note recording with a microphone", "note lock/sleep pause on a real Mac", "live history recording after real insertion", "physical custom shortcut events", "global paste shortcut", "live app insertion", "clipboard managers", "Universal Clipboard", "VoiceOver", "modal keyboard events", "login launch", "live dictation with dictionary entries in real apps", "dictionary editor, recovery switch, Dictation row, Practice and Notes controls with VoiceOver", "Time Machine inclusion on a real backup", "Spotlight exclusion of the Dictionary.noindex folder"]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    guard roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed && historyStorePassed && historyPolicyPassed && notesStorePassed && notesGuardsPassed && dictionaryStorePassed && dictionaryProtectedPassed && dictionaryPreviewPassed && dictionaryRecoverySwitchPassed && dictionaryCopyOriginalPassed && dictionaryPracticeRestorePassed && emptyDictionaryLeavesDictationUnchangedPassed && updatesPassed else { throw CompatibilityPaste.Failure.writeFailed }
}
