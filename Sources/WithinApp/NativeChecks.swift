import AppKit
import WithinCore

/// Uses a uniquely named, synthetic pasteboard. Never reads the user's clipboard.
@MainActor
func nativeChecks(to output: URL) throws {
    _ = NSApplication.shared
    let manifest = try loadManifest()
    let preferenceKeys = ["soundsEnabled", "compatibilityPaste", "activationMode", "alternateShortcut", "dictationShortcut", "microphoneUID", "setupComplete"]
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
    routing.practiceWindowIsActive = { true }
    let activeWindowRoutesToPractice = routing.startsInPractice
    routing.practiceWindowIsActive = { false }
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

    let recoveryWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    let escapeScopePassed = AppDelegate.canHideRecovery(for: recoveryWindow, recovery: recoveryWindow)
        && !AppDelegate.canHideRecovery(for: otherWindow, recovery: recoveryWindow)
        && !AppDelegate.canHideRecovery(for: nil, recovery: recoveryWindow)
        && !AppDelegate.canHideRecovery(for: otherWindow, recovery: nil)
    let previewPreferencesUnchanged = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) as? NSObject } == preferencesBefore
    let transitionsPassed = invalidationPassed && practiceLifecyclePassed && practiceCloseRecheckPassed && busyFeedbackPassed && busyFeedbackCleared && routingPassed && setupPassed && escapeScopePassed && shortcutEditingPassed && microphoneSelectionPassed && modifierSidePassed && recorderEventsPassed
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
        "allPassed": roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed,
        "notTested": ["physical custom shortcut events", "global paste shortcut", "live app insertion", "clipboard managers", "Universal Clipboard", "VoiceOver", "modal keyboard events", "login launch"]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    guard roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged && transitionsPassed else { throw CompatibilityPaste.Failure.writeFailed }
}
