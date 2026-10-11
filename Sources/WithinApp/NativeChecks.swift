import AppKit
import SwiftUI
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
    let preferenceKeys = ["soundsEnabled", "compatibilityPaste", "activationMode", "alternateShortcut", "dictationShortcut", "microphoneUID", "setupComplete", "historyRetention", "automaticUpdateChecks", "lastUpdateCheck", "muteOutputWhileDictating", "outputMuteRecord", "showPersonalDictionary", "showMeetingsSpace", "meetingRetention", "meetingBackups"]
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
        && reloadedNotes.documents == [fixtureNote] && reloadedNotes.unreadable == 0 && notesFolderEmpty
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
    // Show in Finder can't see the file in a folder Within can't search, so it selects the folder.
    let blockedShowsFolder = DictionaryStore(directory: protectedFolder).shownInFinder(setAside: false) == [protectedFolder]
    // Restored before anything is read back, and so the folder can be removed; nothing since the change above can throw.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedFolder.path)
    let unreachableKept = blockedOpened && (try? Data(contentsOf: protectedFile)) == reachable && names(protectedFolder) == ["personal-dictionary.json"]
        && blocked.dictionaryState == .unreadable && blocked.dictionaryMessage.contains("couldn’t be deleted")
        && blockedShowsFolder && DictionaryStore(directory: protectedFolder).shownInFinder(setAside: false) == [protectedFile]
    dictionaryProtectedPassed = unreachableKept && dictionaryProtectedPassed
    // Meeting storage in a temporary folder: the first save, the only call, leaves the folder out of backups
    // however the store was built; owner-only, atomic, crash leftovers swept, a folder that can't be listed
    // reported, and a deleted meeting never brought back by a late checkpoint.
    let meetingsBase = FileManager.default.temporaryDirectory.appendingPathComponent("Within.MeetingsFixture.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: meetingsBase) }
    func outOfBackups(_ folder: URL) -> Bool { (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true }
    let meetingStore = MeetingStore(meetingsIn: meetingsBase)
    let meetingsFolder = meetingStore.directory
    var fixtureMeeting = Meeting(title: "Synthetic", created: Date(timeIntervalSince1970: 1_800_000_000), appName: "Zoom",
        segments: [MeetingSegment(source: .others, offset: 2, text: "synthetic meeting words"),
                   MeetingSegment(source: .you, offset: 5, text: "synthetic wurd reply")],
        notes: "synthetic notes", stretches: [MeetingStretch(start: 0, sources: [.you, .others])])
    let meetingsFolderAbsent = !FileManager.default.fileExists(atPath: meetingsFolder.path)
    var checkpoints = MeetingCheckpointGate()
    if checkpoints.admit(fixtureMeeting.id, revision: 1) { try meetingStore.save(fixtureMeeting) }
    let meetingFile = meetingsFolder.appendingPathComponent("\(fixtureMeeting.id.uuidString).json")
    let spelledOut = MeetingStore(directory: meetingsBase.appendingPathComponent("Spelled", isDirectory: true).appendingPathComponent("Meetings.noindex", isDirectory: true))
    try spelledOut.save(fixtureMeeting)
    let meetingsExcludedFirst = meetingsFolderAbsent && outOfBackups(meetingsFolder) && meetingsFolder.lastPathComponent == "Meetings.noindex"
        && outOfBackups(spelledOut.directory) && names(spelledOut.directory) == [meetingFile.lastPathComponent] && Meeting.excludedFromBackup
    let meetingOwnerOnly = mode(meetingFile) == 0o600 && mode(meetingsFolder) == 0o700 && names(meetingsFolder) == [meetingFile.lastPathComponent]
    let staleMeetingStaging = meetingsFolder.appendingPathComponent(".\(fixtureMeeting.id.uuidString)-\(UUID().uuidString).tmp")
    FileManager.default.createFile(atPath: staleMeetingStaging.path, contents: Data("{".utf8))
    let reloadedMeetings = meetingStore.loadAll()
    let meetingReloaded = reloadedMeetings.documents == [fixtureMeeting] && reloadedMeetings.unreadable == 0 && !reloadedMeetings.unlistable
        && names(meetingsFolder) == [meetingFile.lastPathComponent]
    let unlistableFolder = meetingsBase.appendingPathComponent("Unlistable", isDirectory: true)
    try FileManager.default.createDirectory(at: unlistableFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o000])
    let unlistable = MeetingStore(directory: unlistableFolder).loadAll()
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unlistableFolder.path)
    let missing = MeetingStore(directory: meetingsBase.appendingPathComponent("Missing", isDirectory: true)).loadAll()
    let unlistableReported = unlistable.unlistable && unlistable.documents.isEmpty && !missing.unlistable && missing.documents.isEmpty
    let olderRefused = !checkpoints.admit(fixtureMeeting.id, revision: 1)
    checkpoints.delete(fixtureMeeting.id)
    try meetingStore.delete(fixtureMeeting.id)
    fixtureMeeting.notes = "later synthetic notes"
    if checkpoints.admit(fixtureMeeting.id, revision: 2) { try meetingStore.save(fixtureMeeting) }
    let meetingNotResurrected = olderRefused && names(meetingsFolder).isEmpty
    // Backup exclusion belongs to the kind of document: notes stay in backups.
    let meetingsStorePassed = meetingsExcludedFirst && meetingOwnerOnly && meetingReloaded && unlistableReported && meetingNotResurrected
        && !Note.excludedFromBackup && notesInBackups
    // The meetings backup choice, in temporary folders: out of backups from the first save by default; a store that
    // includes them leaves its new folder in; a choice applied to an existing folder sets or clears it, and clears a
    // file's own exclusion when including; a store built with an older choice never undoes it; no folder, nothing made.
    // Read from the extended attribute that holds the exclusion, on the item and its folder (a file in an excluded folder
    // is excluded): reading `isExcludedFromBackup` through URL resource values keeps the value in this process, and a
    // later write of it can then do nothing. The mark can also land a few milliseconds after a write returns, so each
    // check waits up to a second for the state it expects; a choice that never lands still fails.
    func excludedMark(_ url: URL) -> Bool { getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) >= 0 }
    func settles(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline { usleep(5_000) }
        return condition()
    }
    func inBackups(_ url: URL) -> Bool { settles { !excludedMark(url) && !excludedMark(url.deletingLastPathComponent()) } }
    func leftOutOfBackups(_ url: URL) -> Bool { settles { excludedMark(url) || excludedMark(url.deletingLastPathComponent()) } }
    /// A file's own exclusion, as another app would leave it, landed before the store is asked to clear it.
    func markOwn(_ url: URL) throws {
        var item = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try item.setResourceValues(values)
        _ = settles { excludedMark(url) }
    }
    let choiceBase = meetingsBase.appendingPathComponent("Choice", isDirectory: true)
    let defaultChoice = MeetingStore(meetingsIn: choiceBase.appendingPathComponent("Default", isDirectory: true))
    try defaultChoice.save(fixtureMeeting)
    let choiceFile = defaultChoice.directory.appendingPathComponent(meetingFile.lastPathComponent)
    let excludedByDefault = defaultChoice.excludedFromBackup && leftOutOfBackups(defaultChoice.directory) && leftOutOfBackups(choiceFile)
    let includedChoice = MeetingStore(meetingsIn: choiceBase.appendingPathComponent("Included", isDirectory: true), excludedFromBackup: false)
    try includedChoice.save(fixtureMeeting)
    let includedFromFirstSave = inBackups(includedChoice.directory) && inBackups(includedChoice.directory.appendingPathComponent(meetingFile.lastPathComponent))
    let including = MeetingStore(directory: defaultChoice.directory, excludedFromBackup: false)
    let included = try including.applyBackupChoice() && inBackups(defaultChoice.directory) && inBackups(choiceFile)
    try defaultChoice.save(fixtureMeeting)
    let olderChoiceKept = inBackups(defaultChoice.directory) && names(defaultChoice.directory) == [meetingFile.lastPathComponent]
    let excludedAgain = try defaultChoice.applyBackupChoice() && leftOutOfBackups(defaultChoice.directory) && leftOutOfBackups(choiceFile)
    try markOwn(choiceFile)
    let ownExclusionCleared = try including.applyBackupChoice() && inBackups(defaultChoice.directory) && inBackups(choiceFile)
    let absentBase = choiceBase.appendingPathComponent("Absent", isDirectory: true)
    let absentLeftAlone = try !MeetingStore(meetingsIn: absentBase, excludedFromBackup: false).applyBackupChoice()
        && !MeetingStore(meetingsIn: absentBase).applyBackupChoice() && !FileManager.default.fileExists(atPath: absentBase.path)
    let meetingsBackupChoicePassed = excludedByDefault && includedFromFirstSave && included && olderChoiceKept && excludedAgain
        && ownExclusionCleared && absentLeftAlone && notesInBackups && !Note.excludedFromBackup
    // A preview meeting controller reports the phase `configurePreview` gave it, and never starts anything.
    let previewMeetings = MeetingController(preview: true)
    let previewMeeting = Meeting(title: "Synthetic", created: Date(timeIntervalSince1970: 1_800_000_000), appName: "Zoom",
        segments: [MeetingSegment(source: .others, offset: 2, text: "synthetic meeting words")], notes: "",
        stretches: [MeetingStretch(start: 0, sources: [.you, .others])])
    var meetingPreviewPassed = true
    let previewPhases: [(MeetingLifecycle.Phase, open: Bool, capturing: Bool)] = [(.idle, false, false), (.preparing, true, true), (.recording, true, true),
        (.pausing, true, true), (.paused, true, false), (.finishing, true, true), (.discarding, true, true), (.finished, false, false)]
    for (phase, open, capturing) in previewPhases {
        previewMeetings.configurePreview(previewMeeting, phase: phase, needsAcknowledgment: phase == .paused)
        meetingPreviewPassed = meetingPreviewPassed && previewMeetings.phase == phase && previewMeetings.isOpen == open
            && previewMeetings.isCapturing == capturing && previewMeetings.needsAcknowledgment == (phase == .paused)
        if phase == .paused { meetingPreviewPassed = meetingPreviewPassed && !previewMeetings.resume(acknowledged: true) }
    }
    meetingPreviewPassed = meetingPreviewPassed && !previewMeetings.start(app: nil, acknowledged: true)
        && !previewMeetings.continueMeeting(app: nil, acknowledged: true) && previewMeetings.meeting == previewMeeting && previewMeetings.phase == .finished
    // One capture at a time with a preview meeting, recording or paused: dictation, the shortcut and notes are refused
    // with their own sentences; Stop, Cancel, Escape, lock and model removal leave the session and the meeting's phase
    // as they were, and the model's status line alone; no pill; a quit waits for the meeting. The preview controller
    // has no rings, so whether Stop and Cancel leave a live meeting's rings open is listed under meetingsNotTested.
    var meetingRefusesCapturePassed = true
    for state in ["home-meeting-recording", "home-meeting-paused"] {
        let model = fixture(state)
        let meetingPhase = model.meetings.phase, sessionPhase = model.phase
        let blocked = model.activeCapture == .meeting && !model.canStartDictation && model.canStart == (state == "home-meeting-paused")
        model.start(practice: true)
        let dictationRefused = model.message == AppModel.meetingDictationRefusal && !model.isPracticeSession
        let pressed = fixture(state)
        pressed.shortcutPressed()
        let shortcutRefused = pressed.message == AppModel.meetingDictationRefusal && pressed.phase == sessionPhase
        model.startNoteRecording(model.newNote())
        let noteRefused = model.notesMessage == AppModel.meetingNoteRefusal && !model.isRecordingNote
        model.stop(); model.cancel(); model.cancel(cause: .escape)
        let modelStatus = model.modelMessage
        model.removeModel()
        let modelKept = model.modelInstalled && !model.modelBusy && model.modelMessage == modelStatus
        model.cancelForBoundary()
        meetingRefusesCapturePassed = blocked && dictationRefused && shortcutRefused && noteRefused && modelKept && model.meetingNeedsSaveToQuit
            && model.meetings.phase == meetingPhase && model.phase == sessionPhase && model.activeCapture == .meeting
            && model.activeCapture != .dictation && pressed.activeCapture != .dictation && meetingRefusesCapturePassed
    }
    // A meeting is refused while something else holds capture, with a sentence that names it, and only then for readiness.
    let editingShortcut = fixture("ready")
    _ = editingShortcut.beginShortcutEditing()
    let meetingRefusals: [(AppModel, String?)] = [
        (fixture("note-recording"), "Stop your note recording to start meeting notes."),
        (fixture("recording"), "Finish dictating to start meeting notes."),
        (fixture("practice-transcribing"), "Finish dictating to start meeting notes."),
        (fixture("recovery"), "Review your pending dictation first."),
        (editingShortcut, "Finish practice or the shortcut change first."),
        (fixture("setup"), "Finish setup before recording."),
        (fixture("model-busy"), "Local speech is busy. Try again when it’s ready."),
        (fixture("ready"), nil)]
    let meetingStartRefusalsPassed = meetingRefusals.allSatisfy { $0.0.meetingStartRefusal() == $0.1 }
    // Draining after the sources stopped never reads as listening, and the session is transcribing as a stretch's would be.
    let finishing = fixture("home-meeting-finishing")
    let recordingMeeting = fixture("home-meeting-recording")
    let meetingWordsHonest = finishing.meetings.homeStatus == "Finishing meeting notes" && !finishing.meetings.listening && finishing.phase == .transcribing
        && recordingMeeting.meetings.homeStatus == "Meeting notes are on" && recordingMeeting.meetings.listening && recordingMeeting.phase == .recording
        && fixture("home-meeting-paused").meetings.homeStatus == "Meeting notes are paused" && !fixture("home-meeting-paused").meetings.listening
    // An unload asked for between a meeting's stretches, when no session is held, waits for the next stretch to end
    // instead of failing its start; while paused it runs at once.
    let betweenStretches = fixture("home-meeting-between-stretches")
    let betweenIdle = !betweenStretches.workerBusy && betweenStretches.meetings.isCapturing && betweenStretches.phase == .ready
    betweenStretches.requestUnload()
    let pausedMeeting = fixture("home-meeting-paused")
    pausedMeeting.requestUnload()
    let meetingUnloadPassed = betweenIdle && !betweenStretches.workerBusy && pausedMeeting.workerBusy
    // With the developer default off, every existing state is unchanged: no meeting, no store, and dictation's own rules.
    var meetingsDefaultOffPassed = true
    for state in ["setup", "ready", "model-error", "missing-input", "permission", "recovery", "recording", "practice", "practice-empty", "practice-empty-toggle",
                  "history", "history-empty", "history-off", "notes", "note-recording", "note-preparing", "notes-empty", "update-available", "recovery-dictionary",
                  "inserted-dictionary", "practice-dictionary", "dictionary", "dictionary-empty", "dictionary-unreadable", "dictionary-recording",
                  "dictation-dictionary-unreadable", "practice-recording", "practice-transcribing", "practice-unloading", "practice-recovery", "model-busy"] {
        let model = fixture(state)
        let idle = (model.phase == .ready || model.phase == .recovery) && !model.isRecordingNote
        meetingsDefaultOffPassed = meetingsDefaultOffPassed && !model.showsMeetingsSpace && model.meetings.preview && !model.meetings.isOpen
            && model.meetingRetention == .untilDeleted && !model.meetingsUnlistable && !model.meetingNeedsSaveToQuit
            && model.meetings.meeting == nil && model.savedMeetingCount == 0 && model.canStartDictation == model.canStart
            && (idle ? model.activeCapture == .none : model.activeCapture == (model.isRecordingNote ? .note : .dictation))
    }
    // Saved meetings in Settings → Privacy: previews count in memory only; Delete all clears that count and touches no file.
    let savedPreview = fixture("settings-privacy-saved-meetings")
    let savedCounted = savedPreview.savedMeetingCount == 3 && !savedPreview.meetings.isOpen
    savedPreview.deleteAllMeetings()
    meetingsDefaultOffPassed = meetingsDefaultOffPassed && savedCounted && savedPreview.savedMeetingCount == 0
        && !FileManager.default.fileExists(atPath: output.deletingLastPathComponent().appendingPathComponent("unused").appendingPathComponent("Meetings.noindex").path)
    // Meeting upkeep on temporary folders with synthetic meetings. Without a folder it creates nothing. With one: hourly
    // pruning leaves staging files and the kept meeting alone; at launch, crash leftovers are swept, a crashed open meeting
    // is finished where its last checkpoint or words were, an empty one is deleted, an expired one is pruned, an unreadable
    // file is left, nothing starts capture and nothing else is created. Delete all keeps the folder.
    let upkeepBase = FileManager.default.temporaryDirectory.appendingPathComponent("Within.MeetingUpkeepFixture.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: upkeepBase) }
    try FileManager.default.createDirectory(at: upkeepBase, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let upkeepNow = Date(timeIntervalSince1970: 1_800_000_000)
    let startsBefore = [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts]
    let upkeepWithoutFolder = MeetingUpkeep.atLaunch(base: upkeepBase, retention: .days30, now: upkeepNow) == nil
        && MeetingUpkeep.prune(base: upkeepBase, retention: .days30, now: upkeepNow, keeping: []) == nil && names(upkeepBase).isEmpty
    let upkeepStore = MeetingStore(meetingsIn: upkeepBase)
    let expiredMeeting = Meeting(title: "Synthetic expired", created: upkeepNow.addingTimeInterval(-40 * 86_400), appName: "Zoom",
        segments: [MeetingSegment(source: .you, offset: 3, text: "synthetic older words")],
        stretches: [MeetingStretch(start: 0, sources: [.you], end: 60, ended: .finished)], state: .finished)
    var crashedStretch = MeetingStretch(start: 10, sources: [.you, .others])
    crashedStretch.lastCheckpoint = 42
    let crashedMeeting = Meeting(created: upkeepNow.addingTimeInterval(-3600), appName: "Zoom",
        segments: [MeetingSegment(source: .others, offset: 30, text: "synthetic crashed words")], stretches: [crashedStretch])
    let emptyMeeting = Meeting(created: upkeepNow.addingTimeInterval(-600), appName: Meeting.microphoneOnly, stretches: [MeetingStretch(start: 0, sources: [.you])])
    let recentMeeting = Meeting(title: "Synthetic recent", created: upkeepNow.addingTimeInterval(-86_400), appName: Meeting.microphoneOnly,
        segments: [MeetingSegment(source: .you, offset: 4, text: "synthetic recent words")],
        stretches: [MeetingStretch(start: 0, sources: [.you], end: 30, ended: .finished)], state: .finished)
    for meeting in [expiredMeeting, crashedMeeting, emptyMeeting, recentMeeting] { try upkeepStore.save(meeting) }
    let unreadableMeeting = upkeepStore.directory.appendingPathComponent("\(UUID().uuidString).json")
    try Data("{".utf8).write(to: unreadableMeeting)
    let upkeepStaging = upkeepStore.directory.appendingPathComponent(".\(crashedMeeting.id.uuidString)-\(UUID().uuidString).tmp")
    FileManager.default.createFile(atPath: upkeepStaging.path, contents: Data("{".utf8))
    let hourly = MeetingUpkeep.prune(base: upkeepBase, retention: .days30, now: upkeepNow, keeping: [expiredMeeting.id])
    let hourlyLeftAlone = hourly == MeetingUpkeep.Result(saved: 5) && FileManager.default.fileExists(atPath: upkeepStaging.path)
    let launched = MeetingUpkeep.atLaunch(base: upkeepBase, retention: .days30, now: upkeepNow)
    let remaining = upkeepStore.loadAll(sweepingStaging: false)
    let recovered = remaining.documents.first { $0.id == crashedMeeting.id }
    let crashFinished = recovered?.state == .finished && recovered?.stretches.last?.end == 42 && recovered?.stretches.last?.ended == .unexpectedExit
        && recovered?.segments == crashedMeeting.segments
    let upkeepFiles = [crashedMeeting.id, recentMeeting.id].map { "\($0.uuidString).json" } + [unreadableMeeting.lastPathComponent]
    let upkeepLaunchPassed = launched == MeetingUpkeep.Result(saved: 3, recovered: 1, deleted: 1, pruned: 1, recoveredIDs: [crashedMeeting.id]) && crashFinished
        && Set(remaining.documents.map(\.id)) == [crashedMeeting.id, recentMeeting.id] && remaining.unreadable == 1
        && names(upkeepStore.directory) == upkeepFiles.sorted() && names(upkeepBase) == ["Meetings.noindex"]
        && mode(upkeepStore.directory.appendingPathComponent("\(crashedMeeting.id.uuidString).json")) == 0o600
    try upkeepStore.removeAll()
    let deleteAllKeepsFolder = names(upkeepStore.directory).isEmpty && upkeepStore.exists && names(upkeepBase) == ["Meetings.noindex"]
        && upkeepStore.fileCount == 0
    // A file that can't be removed (user-immutable here) doesn't stop the rest, and is the only one left.
    for meeting in [expiredMeeting, recentMeeting, crashedMeeting] { try upkeepStore.save(meeting) }
    let lockedMeeting = upkeepStore.directory.appendingPathComponent("\(recentMeeting.id.uuidString).json")
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedMeeting.path)
    let deleteAllThrew = (try? upkeepStore.removeAll()) == nil
    let deleteAllWentPast = deleteAllThrew && names(upkeepStore.directory) == [lockedMeeting.lastPathComponent] && upkeepStore.fileCount == 1
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: lockedMeeting.path)
    try upkeepStore.removeAll()
    // A folder that exists but can't be listed is reported as such, never as no meetings.
    try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: upkeepStore.directory.path)
    let upkeepUnlistable = MeetingUpkeep.prune(base: upkeepBase, retention: .days30, now: upkeepNow, keeping: [])
    let upkeepUnlistableReported = upkeepUnlistable?.unlistable == true && upkeepUnlistable?.saved == 0 && upkeepStore.fileCount == nil
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: upkeepStore.directory.path)
    let meetingUpkeepPassed = upkeepWithoutFolder && hourlyLeftAlone && upkeepLaunchPassed && deleteAllKeepsFolder && deleteAllWentPast && upkeepUnlistableReported
        && MeetingStore(meetingsIn: upkeepBase.appendingPathComponent("absent")).fileCount == 0
        && [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts] == startsBefore
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
    // The Dictation space says when the dictionary can't be used, with a way to open it. Counts only, never words.
    let unreadableLine = fixture("dictation-dictionary-unreadable")
    var openedDictionary = false
    unreadableLine.showDictionarySettings = { openedDictionary = true; unreadableLine.settingsSection = "Dictionary" }
    let unreadableText = unreadableLine.dictionaryAttentionLine
    unreadableLine.openDictionarySettings()
    unreadableLine.showDictionarySettings = nil
    let newerLine = fixture("ready")
    newerLine.previewDictionary(.newerVersion)
    let dictionaryUnreadableLineShownPassed = unreadableText == "Your dictionary couldn’t be read, so words are written as transcribed."
        && unreadableLine.dictionaryState == .unreadable && openedDictionary && unreadableLine.settingsSection == "Dictionary"
        && newerLine.dictionaryAttentionLine == unreadableText
        && fixture("dictionary").dictionaryAttentionLine == "1 dictionary word needs attention and isn’t being used."
        && fixture("dictionary-empty").dictionaryAttentionLine == nil && fixture("ready").dictionaryAttentionLine == nil
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
    // The Meetings space. With the developer default off: no row, .meetings refused, and nothing loaded, created or started.
    let meetingSpaceStartsBefore = [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts]
    let unusedMeetings = output.deletingLastPathComponent().appendingPathComponent("unused").appendingPathComponent("Meetings.noindex")
    /// Lays the window out and draws it once, then lets its appear actions and tasks run.
    func hostWindow(_ model: AppModel, _ navigation: AppNavigation, width: CGFloat = 900) {
        let host = NSHostingView(rootView: AppWindowView(model: model, navigation: navigation, togglePractice: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView = nil; window.orderOut(nil)
    }
    var meetingsSpaceHiddenPassed = true
    for state in ["ready", "notes", "recording", "recovery", "settings-privacy-saved-meetings"] {
        let model = fixture(state)
        let hidden = AppNavigation()
        model.loadMeetingLibrary(); model.newMeeting()
        let refused = !hidden.navigate(to: .meetings, model: model, blocked: false, confirmPracticeExit: { false }) && hidden.page != .meetings
        hostWindow(model, hidden)
        meetingsSpaceHiddenPassed = meetingsSpaceHiddenPassed && refused && !model.showsMeetingsSpace && model.meetingLibrary.isEmpty
            && model.meetingsRoute == .library && !model.openMeeting(MeetingPreviews.finished.id) && !model.startMeeting(title: "", acknowledged: true)
            && model.meetings.meeting == nil && model.meetingsToReview.isEmpty
    }
    meetingsSpaceHiddenPassed = meetingsSpaceHiddenPassed && !FileManager.default.fileExists(atPath: unusedMeetings.path)
    // Setup: Start waits for the acknowledgment and says so; what holds capture is named first, even when checked.
    let setupModel = fixture("meeting-setup")
    let startBlockersMatch = ["ready", "recording", "note-recording", "recovery", "practice-transcribing", "model-error", "missing-input", "setup"]
        .allSatisfy { fixture($0).meetingStartBlocker == fixture($0).meetingStartRefusal() }
    let meetingStartNeedsAcknowledgmentPassed = setupModel.meetingsRoute == .setup && startBlockersMatch
        && MeetingAcknowledgment.blocker(acknowledged: false, refusal: setupModel.meetingStartBlocker) == "Check the box above to start."
        && MeetingAcknowledgment.blocker(acknowledged: true, refusal: setupModel.meetingStartBlocker) == nil
        && MeetingAcknowledgment.blocker(acknowledged: true, refusal: fixture("recording").meetingStartBlocker) == "Finish dictating to start meeting notes."
        && !setupModel.startMeeting(title: "Synthetic", acknowledged: false) && setupModel.meetingsRoute == .setup && !setupModel.meetings.isOpen
        && fixture("meeting-mic-only").meetingAppSoundSupported == false && fixture("meeting-setup-computer-audio-intro").includeZoomSound
    // Navigating to and around the space, with the window drawn each time, never starts capture or writes a file.
    let around = fixture("meetings-library")
    let aroundNavigation = AppNavigation()
    var navigationNeverCapturesPassed = aroundNavigation.navigate(to: .meetings, model: around, blocked: false, confirmPracticeExit: { false })
    hostWindow(around, aroundNavigation)
    around.newMeeting(); around.includeZoomSound = true; hostWindow(around, aroundNavigation)
    navigationNeverCapturesPassed = navigationNeverCapturesPassed && around.meetingsRoute == .setup
    around.showAllMeetings(); hostWindow(around, aroundNavigation, width: 720)
    navigationNeverCapturesPassed = navigationNeverCapturesPassed && around.openMeeting(MeetingPreviews.recovered.id) && around.meetingsRoute == .meeting
        && around.meetingsToReview.isEmpty && around.meetings.phase == .finished
    hostWindow(around, aroundNavigation)
    around.closeRecoveryNotice(MeetingPreviews.recovered.id); around.setShowingOriginalTranscription(true)
    _ = aroundNavigation.navigate(to: .home, model: around, blocked: false, confirmPracticeExit: { false })
    _ = aroundNavigation.navigate(to: .meetings, model: around, blocked: false, confirmPracticeExit: { false })
    hostWindow(around, aroundNavigation)
    around.showAllMeetings()
    _ = around.searchMeetings("planning")
    hostWindow(around, aroundNavigation)
    navigationNeverCapturesPassed = navigationNeverCapturesPassed && around.phase == .ready && !around.workerBusy && !around.meetings.isOpen
        && around.meetingsRoute == .library && (around.meetingsFocusRequest == .row(MeetingPreviews.recovered.id) || around.meetingsFocusRequest == nil)
    // An open meeting keeps the space on it: no library, setup or other meeting, and its phase and session stay as they were.
    for state in ["meeting-recording", "meeting-paused"] {
        let model = fixture(state)
        let openNavigation = AppNavigation()
        let phase = model.meetings.phase, session = model.phase
        let navigated = openNavigation.navigate(to: .meetings, model: model, blocked: false, confirmPracticeExit: { false })
        model.showAllMeetings(); model.newMeeting()
        hostWindow(model, openNavigation); hostWindow(model, openNavigation, width: 720)
        navigationNeverCapturesPassed = navigationNeverCapturesPassed && navigated && model.meetingsRoute == .meeting
            && !model.openMeeting(MeetingPreviews.finished.id) && model.meetings.phase == phase && model.phase == session
            && [MeetingPreviews.live.id, MeetingPreviews.paused(.pauseButton).id].contains(model.meetings.meeting?.id)
    }
    navigationNeverCapturesPassed = navigationNeverCapturesPassed && !FileManager.default.fileExists(atPath: unusedMeetings.path)
        && [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts] == meetingSpaceStartsBefore
    // Home during a meeting: its own status with Show meeting, never dictation's Stop or Cancel; the sidebar says the state in words.
    var meetingHomePassed = SessionStatusView.showsDictationControls(fixture("recording")) && SessionStatusView.showsDictationControls(fixture("ready"))
    for state in ["home-during-meeting", "home-meeting-recording", "home-meeting-paused", "home-meeting-finishing", "meeting-resume-acknowledge", "meeting-call-ended"] {
        let model = fixture(state)
        meetingHomePassed = meetingHomePassed && model.meetings.isOpen && model.activeCapture == .meeting && !SessionStatusView.showsDictationControls(model)
    }
    meetingHomePassed = meetingHomePassed && SidebarView.meetingsBadge(phase: .recording, toReview: 2) == "Recording"
        && SidebarView.meetingsBadge(phase: .preparing, toReview: 0) == "Recording" && SidebarView.meetingsBadge(phase: .paused, toReview: 0) == "Paused"
        && SidebarView.meetingsBadge(phase: .finished, toReview: 1) == "1 to review" && SidebarView.meetingsBadge(phase: .idle, toReview: 0) == nil
        && fixture("meetings-library").meetingsToReview == [MeetingPreviews.recovered.id]
    // Dictionary fixes in a meeting: your spellings shown, the original on the toggle, export one version, the file's text unchanged.
    let fixes = fixture("meeting-dictionary-fixes")
    let original = MeetingPreviews.fixes.segments.map(\.text)
    let shown = fixes.meetings.meeting?.segments.map(fixes.meetingTurnText) ?? []
    var meetingDictionaryFixesPassed = fixes.meetings.meeting?.id == MeetingPreviews.fixes.id && fixes.meetingFixedTurns == 3 && shown.count == 4
        && shown[0] == "Can you open the Jira board so Siobhan can see the sprint?" && shown[1] == "Sure. I’ll also run kubectl get pods to check staging."
        && shown[2] == original[2] && shown[3] == "Nothing on my side. Siobhan has the release notes."
        && fixes.meetingTurn(MeetingPreviews.fixes.segments[0]).changes.count == 2
    fixes.setShowingOriginalTranscription(true)
    let spellingsExport = fixes.meetingMarkdown(useOriginalTranscription: false) ?? "", originalExport = fixes.meetingMarkdown(useOriginalTranscription: true) ?? ""
    meetingDictionaryFixesPassed = meetingDictionaryFixesPassed && fixes.meetings.meeting?.segments.map(fixes.meetingTurnText) == original
        && fixes.meetings.meeting?.segments == MeetingPreviews.fixes.segments
        && spellingsExport.contains("Jira") && !spellingsExport.contains("gira") && originalExport.contains("gira") && !originalExport.contains("Jira")
    fixes.setShowingOriginalTranscription(false)
    let plainMeeting = fixture("meeting-finished")
    meetingDictionaryFixesPassed = meetingDictionaryFixesPassed && !fixes.showingOriginalTranscription && plainMeeting.meetingFixedTurns == 0
        && plainMeeting.meetings.meeting?.segments.map(plainMeeting.meetingTurnText) == MeetingPreviews.finished.segments.map(\.text)
    // Search finds a meeting by either spelling, and by neither once the dictionary is off.
    let meetingSearchEitherSpellingPassed = fixes.searchMeetings("jira") == [MeetingPreviews.fixes.id] && fixes.searchMeetings("GIRA") == [MeetingPreviews.fixes.id]
        && fixes.searchMeetings("siobhán") == [MeetingPreviews.fixes.id] && fixes.searchMeetings("kubectl get") == [MeetingPreviews.fixes.id]
        && plainMeeting.searchMeetings("jira").isEmpty && plainMeeting.searchMeetings("sketch it") == [MeetingPreviews.finished.id]
        && Set(plainMeeting.searchMeetings(" ")) == Set(plainMeeting.meetingLibrary.map(\.id))
    // The library's own search runs off the main actor and finds the same meetings; a cancelled one returns nothing.
    func awaitFind(_ model: AppModel, _ query: String, cancel: Bool = false) -> [UUID]?? {
        var result: [UUID]??
        let search = Task { @MainActor in result = .some(await model.findMeetings(query)) }
        if cancel { search.cancel() }
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }
    let backgroundSearchPassed = awaitFind(fixes, "jira") == .some([MeetingPreviews.fixes.id]) && awaitFind(fixes, "gira") == .some([MeetingPreviews.fixes.id])
        && awaitFind(plainMeeting, "jira") == .some([]) && awaitFind(fixes, "jira", cancel: true) == .some(nil)
    // Copy notice writes only the notice, and only to the board it is given.
    let noticeBoard = NSPasteboard(name: .init("Within.MeetingNoticeFixture.\(UUID().uuidString)"))
    defer { noticeBoard.releaseGlobally() }
    let meetingCopyNoticePassed = setupModel.copyMeetingNotice(to: noticeBoard) && noticeBoard.string(forType: .string) == AppModel.meetingNotice
        && noticeBoard.pasteboardItems?.count == 1 && !setupModel.copyMeetingNotice(to: refusingBoard)
    // Search time over a synthetic library of long meetings (counts and times only): fifty three-hour meetings of 2,000 turns each.
    let searchWords = DictionaryMatcher(PersonalDictionary(entries: (0..<500).map {
        DictionaryEntry(heardAs: ["wurd\($0)"], writeAs: "Wurd\($0)", created: Date(timeIntervalSince1970: 1_800_000_000 + Double($0)))
    }))
    let searchLibrary = (0..<50).map { meeting in
        Meeting(created: Date(timeIntervalSince1970: 1_800_000_000), appName: "Zoom", segments: (0..<2_000).map { turn in
            MeetingSegment(source: turn % 2 == 0 ? .you : .others, offset: Double(turn) * 5,
                           text: (0..<15).map { "wurd\((meeting * 7 + turn * 15 + $0) % 900)" }.joined(separator: " ") + ".")
        }, state: .finished)
    }
    func searchMilliseconds(_ dictionary: DictionaryMatcher) -> Int {
        let start = ContinuousClock.now
        _ = MeetingSearch.matching(searchLibrary, query: "absent synthetic phrase", dictionary: dictionary)
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
    let meetingSearchTiming: [String: Int] = ["meetings": searchLibrary.count, "turns": searchLibrary.count * 2_000,
        "millisecondsWithDictionary": searchMilliseconds(searchWords), "millisecondsWithoutDictionary": searchMilliseconds(.empty)]
    let meetingsSpacePassed = meetingsSpaceHiddenPassed && meetingStartNeedsAcknowledgmentPassed && navigationNeverCapturesPassed && meetingHomePassed
        && meetingDictionaryFixesPassed && meetingSearchEitherSpellingPassed && backgroundSearchPassed && meetingCopyNoticePassed
    /// Runs an async step to its end on the main run loop; nil if it took more than ten seconds.
    func finished<T>(_ body: @escaping @MainActor () async -> T) -> T? {
        var result: T?
        Task { @MainActor in result = await body() }
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }
    // Settings → Meetings and the File menu's Meeting group exist only with the developer default on; a hidden model's
    // Settings shown at "Meetings" draws nothing for it and creates nothing.
    let meetingStartsBeforeSettings = [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts]
    let baseSections = ["General", "Audio", "History", "Privacy", "Model", "About"]
    var meetingSettingsHiddenPassed = SettingsView.sections(showingDictionary: false).map(\.0) == baseSections
        && SettingsView.sections(showingDictionary: true).map(\.0) == ["General", "Audio", "Dictionary", "History", "Privacy", "Model", "About"]
        && SettingsView.sections(showingDictionary: true, showingMeetings: true).map(\.0) == ["General", "Audio", "Dictionary", "History", "Meetings", "Privacy", "Model", "About"]
        && SettingsView.sections(for: fixture("settings-meetings")).map(\.0) == ["General", "Audio", "History", "Meetings", "Privacy", "Model", "About"]
    for state in ["ready", "setup", "recording", "notes", "dictionary", "settings-privacy-saved-meetings", "settings-privacy-saved-meetings-backups"] {
        let model = fixture(state)
        meetingSettingsHiddenPassed = meetingSettingsHiddenPassed && !model.showsMeetingsSpace
            && SettingsView.sections(for: model).map(\.0) == SettingsView.sections(showingDictionary: model.showsPersonalDictionary).map(\.0)
    }
    let hiddenSettings = fixture("settings-privacy-saved-meetings")
    let hiddenSettingsNavigation = AppNavigation()
    _ = hiddenSettingsNavigation.navigate(to: .settings, model: hiddenSettings, blocked: false, confirmPracticeExit: { false })
    hiddenSettings.settingsSection = "Meetings"
    hostWindow(hiddenSettings, hiddenSettingsNavigation)
    let fileTitles = { (menu: NSMenu) in menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
    let meetingMenuTitles = ["New Meeting…", "Pause Meeting", "Finish Meeting", "Discard Meeting…", "All Meetings"]
    let menuDelegate = AppDelegate()
    let hiddenFileMenu = menuDelegate.makeFileMenu(showingMeetings: fixture("ready").showsMeetingsSpace)
    let shownFileMenu = menuDelegate.makeFileMenu(showingMeetings: fixture("meetings-library").showsMeetingsSpace)
    meetingSettingsHiddenPassed = meetingSettingsHiddenPassed && hiddenSettings.meetingRetention == .untilDeleted && !hiddenSettings.meetingBackups
        && fileTitles(hiddenFileMenu) == ["Open Within", "Practice Dictation…", "Set Up Within…", "-", "Close Window"]
        && fileTitles(shownFileMenu) == ["Open Within", "Practice Dictation…", "Set Up Within…", "-"] + meetingMenuTitles + ["-", "Close Window"]
        && shownFileMenu.items.filter { meetingMenuTitles.contains($0.title) }.allSatisfy { $0.target === menuDelegate && $0.action != nil }
        && AppDelegate.windowTitle(.meetings) == "Meetings · Within" && AppDelegate.windowTitle(.home) == "Within"
    // Each menu item says what it does now. New Meeting and Resume give a refused start's reason, in its order.
    func menuState(_ action: AppDelegate.MeetingMenuAction, _ state: String, page: AppPage = .meetings) -> AppDelegate.MeetingMenuState {
        AppDelegate.meetingMenuState(action, model: fixture(state), page: page)
    }
    let meetingMenuStatesPassed = menuState(.newMeeting, "meetings-library") == .init(title: "New Meeting…", enabled: true)
        && menuState(.newMeeting, "recording") == .init(title: "New Meeting…", enabled: false, reason: "Finish dictating to start meeting notes.")
        && menuState(.newMeeting, "note-recording").reason == "Stop your note recording to start meeting notes."
        && menuState(.newMeeting, "recovery").reason == "Review your pending dictation first."
        && menuState(.newMeeting, "setup").reason == "Finish setup before recording."
        && menuState(.newMeeting, "meeting-recording") == .init(title: "New Meeting…", enabled: false, reason: AppDelegate.meetingOpenReason)
        && menuState(.pauseOrResume, "meeting-recording") == .init(title: "Pause Meeting", enabled: true)
        && menuState(.pauseOrResume, "meeting-paused") == .init(title: "Resume Meeting", enabled: true)
        && menuState(.pauseOrResume, "meeting-resume-acknowledge") == .init(title: "Resume Meeting…", enabled: true)
        && menuState(.pauseOrResume, "meeting-finished") == .init(title: "Pause Meeting", enabled: false)
        && menuState(.finish, "meeting-paused").enabled && menuState(.finish, "meeting-recording").enabled
        && !menuState(.finish, "meeting-finished").enabled && !menuState(.finish, "home-meeting-finishing").enabled
        && menuState(.discard, "meeting-paused").enabled && !menuState(.discard, "meeting-finished").enabled
        && menuState(.allMeetings, "meeting-finished").enabled && menuState(.allMeetings, "meeting-setup").enabled
        && !menuState(.allMeetings, "meeting-finished", page: .home).enabled && !menuState(.allMeetings, "meetings-library").enabled
        && !menuState(.allMeetings, "meeting-recording").enabled
    // The backups switch: only a stored true includes meetings. Previews and the hidden space never change it or write it.
    let backupsShown = fixture("settings-meetings")
    let backupsOffByDefault = !AppModel.storedMeetingBackups(nil) && AppModel.storedMeetingBackups(true) && !AppModel.storedMeetingBackups(false)
        && !AppModel.storedMeetingBackups("true") && !backupsShown.meetingBackups && !fixture("ready").meetingBackups
    backupsShown.setMeetingBackups(true)
    let backupsTurnedOn = backupsShown.meetingBackups
    backupsShown.setMeetingBackups(false)
    let backupsHidden = fixture("settings-privacy-saved-meetings")
    backupsHidden.setMeetingBackups(true)
    // Through the controller's writer, in order with its saves, on temporary folders: with no folder nothing is made; a
    // folder a later save creates takes the newest choice; an existing folder takes it at once, its files too.
    let switchBase = meetingsBase.appendingPathComponent("Switch", isDirectory: true)
    let switchStore = MeetingStore(meetingsIn: switchBase)
    let switchWriter = MeetingCheckpointWriter(store: switchStore)
    let switchMeeting = Meeting(title: "Synthetic switch", created: Date(timeIntervalSince1970: 1_800_000_000), appName: Meeting.microphoneOnly,
        segments: [MeetingSegment(source: .you, offset: 1, text: "synthetic switch words")],
        stretches: [MeetingStretch(start: 0, sources: [.you], end: 5, ended: .finished)], state: .finished)
    let switchFile = switchStore.directory.appendingPathComponent("\(switchMeeting.id.uuidString).json")
    let switchNoFolder = finished { await switchWriter.setExcludedFromBackup(false) } == true && !FileManager.default.fileExists(atPath: switchBase.path)
    let switchCreatedIncluded = finished { await switchWriter.write(switchMeeting, revision: 1) } == MeetingCheckpointWriter.Outcome.saved && inBackups(switchStore.directory) && inBackups(switchFile)
    let switchExcluded = finished { await switchWriter.setExcludedFromBackup(true) } == true && leftOutOfBackups(switchStore.directory)
        && finished { await switchWriter.write(switchMeeting, revision: 2) } == MeetingCheckpointWriter.Outcome.saved && leftOutOfBackups(switchStore.directory)
    try markOwn(switchFile)
    let switchIncludedAgain = finished { await switchWriter.setExcludedFromBackup(false) } == true && inBackups(switchStore.directory) && inBackups(switchFile)
    // The other way: built to include, switched off before the first save, so the folder is created out of backups.
    let laterBase = meetingsBase.appendingPathComponent("SwitchLater", isDirectory: true)
    let laterWriter = MeetingCheckpointWriter(store: MeetingStore(meetingsIn: laterBase, excludedFromBackup: false))
    let switchLaterExcluded = finished { await laterWriter.setExcludedFromBackup(true) } == true && !FileManager.default.fileExists(atPath: laterBase.path)
        && finished { await laterWriter.write(switchMeeting, revision: 1) } == MeetingCheckpointWriter.Outcome.saved && leftOutOfBackups(MeetingStore(meetingsIn: laterBase).directory)
    // A live controller passes the choice to its writer; it shows a saved meeting and writes it with Try again, starting nothing.
    let controllerBase = meetingsBase.appendingPathComponent("SwitchController", isDirectory: true)
    let controllerStore = MeetingStore(meetingsIn: controllerBase)
    let switchHost = fixture("ready")
    let switchController = MeetingController(speech: LocalSpeech(), host: switchHost, store: controllerStore, sources: { _ in [] })
    let switchControllerPassed = finished { await switchController.setExcludedFromBackup(false) } == true && !FileManager.default.fileExists(atPath: controllerBase.path)
        && switchController.show(switchMeeting) && finished { await switchController.tryAgain() } == true
        && inBackups(controllerStore.directory) && !switchController.isOpen && switchController.phase == .finished
        && finished { await switchController.setExcludedFromBackup(true) } == true && leftOutOfBackups(controllerStore.directory)
    let meetingBackupsSwitchPassed = backupsOffByDefault && backupsTurnedOn && !backupsShown.meetingBackups && !backupsHidden.meetingBackups
        && switchNoFolder && switchCreatedIncluded && switchExcluded && switchIncludedAgain && switchLaterExcluded && switchControllerPassed
        && !FileManager.default.fileExists(atPath: unusedMeetings.path)
    // At launch the stored choice reaches an existing folder only: none is created; a folder a crash left without its
    // exclusion gets it; including clears it from the folder and its files; hourly pruning leaves the choice alone.
    let launchBase = meetingsBase.appendingPathComponent("Launch", isDirectory: true)
    let launchStore = MeetingStore(meetingsIn: launchBase)
    let launchFile = launchStore.directory.appendingPathComponent(switchFile.lastPathComponent)
    let launchAbsent = MeetingUpkeep.atLaunch(base: launchBase, retention: .untilDeleted, excludedFromBackup: false, now: upkeepNow) == nil
        && MeetingUpkeep.atLaunch(base: launchBase, retention: .untilDeleted, now: upkeepNow) == nil && !FileManager.default.fileExists(atPath: launchBase.path)
    // As after a crash between creating the folder and excluding it.
    try MeetingStore(directory: launchStore.directory, excludedFromBackup: false).save(switchMeeting)
    let launchCrashLeftIncluded = inBackups(launchStore.directory)
    let launchExcluded = MeetingUpkeep.atLaunch(base: launchBase, retention: .untilDeleted, now: upkeepNow) == MeetingUpkeep.Result(saved: 1)
        && leftOutOfBackups(launchStore.directory)
    let launchPruneLeavesChoice = MeetingUpkeep.prune(base: launchBase, retention: .untilDeleted, excludedFromBackup: false, now: upkeepNow, keeping: [])
        == MeetingUpkeep.Result(saved: 1) && leftOutOfBackups(launchStore.directory)
    try markOwn(launchFile)
    let launchIncluded = MeetingUpkeep.atLaunch(base: launchBase, retention: .untilDeleted, excludedFromBackup: false, now: upkeepNow) == MeetingUpkeep.Result(saved: 1)
        && inBackups(launchStore.directory) && inBackups(launchFile)
    // A file that can't be changed (user-immutable here) is reported, and the rest of upkeep still runs.
    try markOwn(launchFile)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: launchFile.path)
    let launchFailure = MeetingUpkeep.atLaunch(base: launchBase, retention: .untilDeleted, excludedFromBackup: false, now: upkeepNow)
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: launchFile.path)
    let launchFailureReported = launchFailure == MeetingUpkeep.Result(saved: 1, backupFailed: true) && inBackups(launchStore.directory)
    let meetingBackupLaunchPassed = launchAbsent && launchCrashLeftIncluded && launchExcluded && launchPruneLeavesChoice && launchIncluded && launchFailureReported
        && MeetingUpkeep.atLaunch(base: launchBase, retention: .untilDeleted, now: upkeepNow) == MeetingUpkeep.Result(saved: 1) && leftOutOfBackups(launchStore.directory)
    // Retention changes only by a choice in Settings → Meetings: never with the space hidden, never by showing the section.
    // Its confirmation counts expired meetings, leaving out the shown one, as pruning does.
    let hiddenRetention = fixture("ready")
    hiddenRetention.chooseMeetingRetention(.days30)
    let retentionModel = fixture("settings-meetings")
    let retentionNavigation = AppNavigation()
    _ = retentionNavigation.navigate(to: .settings, model: retentionModel, blocked: false, confirmPracticeExit: { false })
    retentionModel.settingsSection = "Meetings"
    hostWindow(retentionModel, retentionNavigation)
    let retentionShownUnchanged = retentionModel.meetingRetention == .untilDeleted && !retentionModel.meetingBackups
    let retentionNow = Date(timeIntervalSince1970: 1_800_000_000 + 27 * 86_400)
    let expiringCounts = [DocumentRetention.days30, .days90, .days365, .untilDeleted].map { retention in
        finished { await retentionModel.meetingsExpiring(under: retention, now: retentionNow) }
    }
    let shownKept = fixture("meeting-finished")
    let shownKeptCount = finished { await shownKept.meetingsExpiring(under: .days30, now: retentionNow.addingTimeInterval(30 * 86_400)) }
    retentionModel.chooseMeetingRetention(.days90)
    let meetingRetentionChoicePassed = hiddenRetention.meetingRetention == .untilDeleted && retentionShownUnchanged
        && expiringCounts == [2, 0, 0, 0] && shownKeptCount == 3 && retentionModel.meetingRetention == .days90 && retentionModel.meetingLibrary.count == 4
        && finished { await hiddenRetention.meetingsExpiring(under: .days30, now: retentionNow) } == 0
        && !FileManager.default.fileExists(atPath: unusedMeetings.path)
        && [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts] == meetingStartsBeforeSettings
    // Showing another meeting writes a pending notes edit first. If that write fails, the meeting stays shown as not
    // saved; its Try again clears the refusal, as showing another meeting clears a refused delete's.
    let meetingStartsBeforeSwitch = [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts]
    let pendingStore = MeetingStore(meetingsIn: meetingsBase.appendingPathComponent("Pending", isDirectory: true))
    let pendingController = MeetingController(speech: LocalSpeech(), host: fixture("ready"), store: pendingStore, sources: { _ in [] })
    func pendingMeeting(_ title: String) -> Meeting {
        Meeting(title: title, created: Date(timeIntervalSince1970: 1_800_000_000), appName: Meeting.microphoneOnly,
                segments: [MeetingSegment(source: .you, offset: 1, text: "synthetic pending words")],
                stretches: [MeetingStretch(start: 0, sources: [.you], end: 5, ended: .finished)], state: .finished)
    }
    let pendingA = pendingMeeting("Synthetic A"), pendingB = pendingMeeting("Synthetic B")
    func pendingOnDisk(_ id: UUID) -> Meeting? { pendingStore.loadAll(sweepingStaging: false).documents.first { $0.id == id } }
    func lockPendingFolder(_ locked: Bool) { try? FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: pendingStore.directory.path) }
    defer { lockPendingFolder(false) }
    let pendingSaved = pendingController.show(pendingA) && finished { await pendingController.tryAgain() } == true
    pendingController.setNotes("synthetic notes written before the switch")
    let pendingWritten = pendingController.show(pendingB) && pendingController.meeting?.id == pendingB.id
        && pendingOnDisk(pendingA.id)?.notes == "synthetic notes written before the switch"
    let pendingShownAgain = pendingOnDisk(pendingA.id).map(pendingController.show) == true
    pendingController.setNotes("synthetic notes the folder refuses")
    lockPendingFolder(true)
    let pendingKept = !pendingController.show(pendingB) && pendingController.meeting?.id == pendingA.id && pendingController.notSaved
        && pendingController.refusal == MeetingController.notSavedMessage && pendingController.meeting?.notes == "synthetic notes the folder refuses"
    lockPendingFolder(false)
    let pendingRetried = finished { await pendingController.tryAgain() } == true && !pendingController.notSaved && pendingController.refusal == nil
        && pendingOnDisk(pendingA.id)?.notes == "synthetic notes the folder refuses"
    lockPendingFolder(true)
    let pendingDeleteRefused = finished { await pendingController.delete() } == false && pendingController.refusal == MeetingController.notDeletedMessage
    lockPendingFolder(false)
    let pendingRefusalCleared = pendingController.show(pendingB) && pendingController.refusal == nil && pendingOnDisk(pendingA.id) != nil
    // A lock or user switch with no meeting open starts nothing, yet clears a checked acknowledgment; other reasons don't.
    let epochBefore = pendingController.acknowledgmentEpoch
    pendingController.boundary(.lockOrSleep); pendingController.boundary(.userSwitched); pendingController.boundary(.pauseButton)
    let epochPreview = MeetingController(preview: true)
    epochPreview.boundary(.lockOrSleep); epochPreview.callEnded()
    let meetingAcknowledgmentClearedByBoundaryPassed = pendingController.acknowledgmentEpoch == epochBefore + 2 && pendingController.phase == .finished
        && !pendingController.isOpen && epochPreview.acknowledgmentEpoch == 2 && epochPreview.phase == .idle
        && [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts] == meetingStartsBeforeSwitch
    let meetingSwitchSavesPendingEditFirstPassed = pendingSaved && pendingWritten && pendingShownAgain && pendingKept && pendingRetried
        && pendingDeleteRefused && pendingRefusalCleared && [MeetingSourceAudit.microphoneStarts, MeetingSourceAudit.appAudioStarts] == meetingStartsBeforeSwitch
    // Continue includes Zoom's sound only for a meeting that already did, so a microphone-only meeting's labels stay true.
    let continuing = fixture("meetings-library")
    continuing.includeZoomSound = true
    let continueMicrophoneOnly = continuing.openMeeting(MeetingPreviews.microphoneOnly.id) && continuing.meetingContinueApp == nil
    let continueZoom = continuing.openMeeting(MeetingPreviews.finished.id) && continuing.meetingContinueApp == (continuing.meetingAppSoundSupported ? .zoom : nil)
    continuing.includeZoomSound = false
    let meetingContinueKeepsMicrophoneOnlyPassed = continueMicrophoneOnly && continueZoom && continuing.meetingContinueApp == nil
    // A meeting held in memory only keeps setup's Start and File → New Meeting… unavailable, with its reason.
    let heldModel = fixture("meeting-setup-not-saved")
    let heldNavigation = AppNavigation()
    _ = heldNavigation.navigate(to: .meetings, model: heldModel, blocked: false, confirmPracticeExit: { false })
    hostWindow(heldModel, heldNavigation)
    let meetingHeldMeetingBlocksSetupWithReasonPassed = heldModel.meetingsRoute == .setup && heldModel.meetingHeldMessage == MeetingController.notSavedMessage
        && MeetingAcknowledgment.blocker(acknowledged: true, refusal: heldModel.meetingHeldMessage ?? heldModel.meetingStartBlocker) == MeetingController.notSavedMessage
        && AppDelegate.meetingMenuState(.newMeeting, model: heldModel, page: .meetings) == .init(title: "New Meeting…", enabled: false, reason: MeetingController.notSavedMessage)
        && fixture("meeting-finished").meetingHeldMessage == nil && fixture("meeting-setup").meetingHeldMessage == nil
    // The backup wording follows what is known: never included, included, included before, or the choice not applied.
    let turnedOff = fixture("settings-meetings")
    turnedOff.setMeetingBackups(true); turnedOff.setMeetingBackups(false)
    let meetingBackupWordingFollowsChoicePassed = fixture("settings-meetings").meetingBackupStatus == .excluded
        && fixture("settings-meetings-backups").meetingBackupStatus == .included
        && fixture("settings-meetings-backups-off").meetingBackupStatus == .excludedAfterIncluded
        && fixture("settings-privacy-saved-meetings-backups-off").meetingBackupStatus == .excludedAfterIncluded
        && fixture("settings-privacy-saved-meetings-backup-failed").meetingBackupStatus == .unconfirmed
        && fixture("settings-privacy-saved-meetings").meetingBackupStatus == .excluded && turnedOff.meetingBackupStatus == .excludedAfterIncluded
        && !AppModel.meetingBackupsWereIncluded(nil) && !AppModel.meetingBackupsWereIncluded(true) && AppModel.meetingBackupsWereIncluded(false)
        && MeetingWords.emptyLibrary(.excluded).contains("kept out of Time Machine backups") && MeetingWords.emptyLibrary(.included).contains("its Time Machine backups")
        && !MeetingWords.emptyLibrary(.unconfirmed).contains("backups")
    // What VoiceOver gets from the meeting screen: each turn, live row, chip and Fixed tag is static text whose value
    // carries its words, state or count; the title stays a text field; the Zoom switch has a name. Checked last, as it
    // turns on the accessibility tree for this process.
    let meetingTranscriptExposesWordsToVoiceOverPassed = meetingAccessibilityPassed(fixture)
    let meetingFollowupsPassed = meetingSwitchSavesPendingEditFirstPassed && meetingAcknowledgmentClearedByBoundaryPassed && meetingContinueKeepsMicrophoneOnlyPassed
        && meetingHeldMeetingBlocksSetupWithReasonPassed && meetingBackupWordingFollowsChoicePassed && meetingTranscriptExposesWordsToVoiceOverPassed
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
        "meetingsStoreOwnerOnlyAtomicPassed": meetingsStorePassed,
        "meetingPreviewControllerPassed": meetingPreviewPassed,
        "meetingRefusesCaptureAndKeepsItsSessionPassed": meetingRefusesCapturePassed,
        "meetingDrainingNeverReadsAsListeningPassed": meetingWordsHonest,
        "meetingUnloadWaitsBetweenStretchesPassed": meetingUnloadPassed,
        "meetingStartRefusalNamesBlockerPassed": meetingStartRefusalsPassed,
        "meetingsDefaultOffLeavesStatesUnchangedPassed": meetingsDefaultOffPassed,
        "meetingUpkeepExistingFolderOnlyPassed": meetingUpkeepPassed,
        "meetingsBackupChoicePassed": meetingsBackupChoicePassed,
        "meetingsSpaceHiddenByDefaultPassed": meetingsSpaceHiddenPassed,
        "meetingStartNeedsAcknowledgmentWithReasonPassed": meetingStartNeedsAcknowledgmentPassed,
        "meetingNavigationNeverStartsCapturePassed": navigationNeverCapturesPassed,
        "meetingHomeHasNoStopOrCancelPassed": meetingHomePassed,
        "meetingDictionaryFixesShownWithOriginalOnTogglePassed": meetingDictionaryFixesPassed,
        "meetingSearchFindsEitherSpellingPassed": meetingSearchEitherSpellingPassed && backgroundSearchPassed,
        "meetingCopyNoticeOnlyToItsBoardPassed": meetingCopyNoticePassed,
        "meetingSearchSyntheticTiming": meetingSearchTiming,
        "meetingSettingsAndMenuHiddenByDefaultPassed": meetingSettingsHiddenPassed,
        "meetingMenuItemsFollowRefusalOrderPassed": meetingMenuStatesPassed,
        "meetingBackupsOffByDefaultSwitchReachesLaterFolderPassed": meetingBackupsSwitchPassed,
        "meetingBackupChoiceAppliedAtLaunchOnlyToExistingFolderPassed": meetingBackupLaunchPassed,
        "meetingRetentionWrittenOnlyByChoicePassed": meetingRetentionChoicePassed,
        "meetingSwitchSavesPendingEditFirstPassed": meetingSwitchSavesPendingEditFirstPassed,
        "meetingAcknowledgmentClearedByBoundaryPassed": meetingAcknowledgmentClearedByBoundaryPassed,
        "meetingContinueKeepsMicrophoneOnlyPassed": meetingContinueKeepsMicrophoneOnlyPassed,
        "meetingHeldMeetingBlocksSetupWithReasonPassed": meetingHeldMeetingBlocksSetupWithReasonPassed,
        "meetingBackupWordingFollowsChoicePassed": meetingBackupWordingFollowsChoicePassed,
        "meetingTranscriptExposesWordsToVoiceOverPassed": meetingTranscriptExposesWordsToVoiceOverPassed,
        "dictionaryStoreOwnerOnlyAtomicKeptInBackupsPassed": dictionaryStorePassed,
        "dictionaryProtectedFileIsNeverOverwrittenPassed": dictionaryProtectedPassed,
        "dictionaryPreviewWritesNothingPassed": dictionaryPreviewPassed,
        "dictionaryRecoverySwitchPassed": dictionaryRecoverySwitchPassed,
        "dictionaryCopyOriginalPassed": dictionaryCopyOriginalPassed,
        "dictionaryPracticeRestorePassed": dictionaryPracticeRestorePassed,
        "emptyDictionaryLeavesDictationUnchangedPassed": emptyDictionaryLeavesDictationUnchangedPassed,
        "dictionaryUnreadableLineShownPassed": dictionaryUnreadableLineShownPassed,
        "updatePreviewWithoutNetworkPassed": updatesPassed,
        "allPassed": roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed && historyStorePassed && historyPolicyPassed && notesStorePassed && notesGuardsPassed && meetingsStorePassed && meetingPreviewPassed && meetingRefusesCapturePassed && meetingStartRefusalsPassed && meetingWordsHonest && meetingUnloadPassed && meetingsDefaultOffPassed && meetingUpkeepPassed && meetingsBackupChoicePassed && meetingsSpacePassed && meetingSettingsHiddenPassed && meetingMenuStatesPassed && meetingBackupsSwitchPassed && meetingBackupLaunchPassed && meetingRetentionChoicePassed && meetingFollowupsPassed && dictionaryStorePassed && dictionaryProtectedPassed && dictionaryPreviewPassed && dictionaryRecoverySwitchPassed && dictionaryCopyOriginalPassed && dictionaryPracticeRestorePassed && emptyDictionaryLeavesDictationUnchangedPassed && dictionaryUnreadableLineShownPassed && updatesPassed,
        "notTested": ["live note recording with a microphone", "note lock/sleep pause on a real Mac", "live history recording after real insertion", "physical custom shortcut events", "global paste shortcut", "live app insertion", "clipboard managers", "Universal Clipboard", "VoiceOver", "modal keyboard events", "login launch", "live dictation with dictionary entries in real apps", "dictionary editor, recovery switch, Dictation row, Practice and Notes controls with VoiceOver", "Time Machine inclusion on a real backup", "Spotlight exclusion of the Dictionary.noindex folder", "Time Machine exclusion and Spotlight exclusion of the Meetings.noindex folder", "Open dictionary navigation from the Dictation space in the running app"],
        "meetingsNotTested": ["a meeting started, paused, resumed, finished, continued or discarded from the Meetings space in the running app",
            "keyboard-only and VoiceOver passes over the library, setup and meeting screen, including rotors, Read latest and the Fixed tag's action",
            "whether VoiceOver speaks both the label and the value of the static-text turns, live rows, chips and Fixed tag (the tree is checked, not speech)",
            "the not-hearing and hearing-again announcements on a real call",
            "Export through the save panel", "auto-scroll and Jump to latest while words arrive", "the library read from the real folder",
            "deleting a meeting from the library or its screen in the running app", "the File menu's Meeting items and their shortcuts in the running app",
            "Settings → Meetings in the running app: the retention confirmation and pruning on the real folder, and the backup switch on the real folder",
            "Time Machine honoring the meetings folder's exclusion, or its inclusion after the switch is turned on, in a real backup",
            "Finish and Quit with terminateLater and the 10-second watchdog",
            "the save-failure quit alert", "logout, restart or shutdown during a meeting", "real lock, sleep or user switch during a meeting",
            "the pause announcement after unlock, wake or a user switch", "microphone change routing during a meeting", "the status menu during a meeting",
            "the meeting phase observer, its message reset and the meeting error codes in a running app", "upkeep and hourly pruning on the real folder at launch",
            "Show in Finder and Delete all in the running app", "System Audio Recording prompt and its System Settings pane",
            "Stop and Cancel leaving a live meeting's rings open", "the quit reason of a real logout, restart or shutdown",
            "a logout canceled after Within finished a meeting", "a second quit from the Dock or another app while Finish and Quit saves",
            "the Quit items while Finish and Quit saves", "the unlock announcement after a lock during a rollover"]]
    try writeReport(report, to: output)
    guard roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed && historyStorePassed && historyPolicyPassed && notesStorePassed && notesGuardsPassed && meetingsStorePassed && meetingPreviewPassed && meetingRefusesCapturePassed && meetingStartRefusalsPassed && meetingWordsHonest && meetingUnloadPassed && meetingsDefaultOffPassed && meetingUpkeepPassed && meetingsBackupChoicePassed && meetingsSpacePassed && meetingSettingsHiddenPassed && meetingMenuStatesPassed && meetingBackupsSwitchPassed && meetingBackupLaunchPassed && meetingRetentionChoicePassed && meetingFollowupsPassed && dictionaryStorePassed && dictionaryProtectedPassed && dictionaryPreviewPassed && dictionaryRecoverySwitchPassed && dictionaryCopyOriginalPassed && dictionaryPracticeRestorePassed && emptyDictionaryLeavesDictationUnchangedPassed && dictionaryUnreadableLineShownPassed && updatesPassed else { throw CompatibilityPaste.Failure.writeFailed }
}

/// One element of the accessibility tree as VoiceOver receives it.
private struct AccessibilityNode {
    let role: String, label: String, value: String
    let actions: [String]
}

/// The meeting screen's tree, built the way VoiceOver asks for it: the window is hosted with the accessibility tree
/// turned on for this process, then walked. Synthetic preview meetings only; nothing is spoken, read or written.
@MainActor
private func meetingAccessibilityPassed(_ fixture: (String) -> AppModel) -> Bool {
    // As an assistive app asks for it; the legacy setter is reached by name. Process-local; it prompts for nothing.
    func assistive(_ on: Bool) {
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: on), with: attribute as NSString)
        }
    }
    assistive(true)
    defer { assistive(false) }
    func walk(_ node: Any, _ depth: Int, _ out: inout [AccessibilityNode]) {
        guard depth < 40, let element = node as? NSObject else { return }
        func get(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
        }
        out.append(AccessibilityNode(role: get("accessibilityRole") as? String ?? "", label: get("accessibilityLabel") as? String ?? "",
                                     value: get("accessibilityValue").map { "\($0)" } ?? "",
                                     actions: (get("accessibilityCustomActions") as? [NSAccessibilityCustomAction])?.map(\.name) ?? []))
        for child in get("accessibilityChildren") as? [Any] ?? [] { walk(child, depth + 1, &out) }
    }
    func tree(_ state: String) -> [AccessibilityNode] {
        let model = fixture(state)
        let navigation = AppNavigation()
        _ = navigation.navigate(to: .meetings, model: model, blocked: false, confirmPracticeExit: { false })
        let host = NSHostingView(rootView: AppWindowView(model: model, navigation: navigation, togglePractice: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: state.hasPrefix("meeting-setup") ? 1000 : 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; window.orderOut(nil) }
        var nodes: [AccessibilityNode] = []
        // SwiftUI fills the tree in over a few passes once it is asked for.
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.needsLayout = true; host.layoutSubtreeIfNeeded()
            nodes = []; walk(host, 0, &nodes)
        }
        return nodes
    }
    func node(_ nodes: [AccessibilityNode], _ label: String) -> AccessibilityNode? { nodes.first { $0.label == label } }
    let staticText = NSAccessibility.Role.staticText.rawValue
    let read = "Read original transcription"
    let fixes = tree("meeting-dictionary-fixes")
    let fixedTurn = node(fixes, "Others, 8 seconds"), plainTurn = node(fixes, "Others, 33 seconds"), tag = node(fixes, "Fixed")
    let fixesPassed = fixedTurn?.role == staticText && fixedTurn?.value == "Can you open the Jira board so Siobhan can see the sprint?"
        && fixedTurn?.actions.contains(read) == true
        && plainTurn?.role == staticText && plainTurn?.value == "Thanks. Anything blocking you this week?" && plainTurn?.actions.isEmpty == true
        && tag?.role == staticText && tag?.value == MeetingWords.fixes(2) && tag?.actions.contains(read) == true
        && node(fixes, "Meeting title")?.role == NSAccessibility.Role.textField.rawValue
    let recording = tree("meeting-recording")
    let others = node(recording, "Others, Zoom"), live = node(recording, "Others, still being transcribed")
    let recordingPassed = others?.role == staticText && others?.value == "Live" && live?.role == staticText
        && live?.value == "I think we could move the shortcut choice to the end and"
        && recording.contains { $0.role == staticText && $0.label.hasPrefix("You, ") && $0.value == "Live" }
    let setup = tree("meeting-setup-computer-audio-intro")
    let setupPassed = setup.contains { $0.role == NSAccessibility.Role.checkBox.rawValue && $0.label == "Include Zoom’s sound (the other people)" }
    return fixesPassed && recordingPassed && setupPassed
}
