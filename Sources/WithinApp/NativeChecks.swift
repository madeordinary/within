import AppKit
import WithinCore

/// Uses a uniquely named, synthetic pasteboard. Never reads the user's clipboard.
@MainActor
func nativeChecks(to output: URL) throws {
    let manifest = try loadManifest()
    let preferenceKeys = ["soundsEnabled", "compatibilityPaste", "activationMode", "alternateShortcut", "microphoneUID"]
    let preferencesBefore = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
    var readinessPassed = true
    for (state, expected) in [("ready", true), ("setup", false), ("model-error", false), ("missing-input", false), ("permission", true), ("recovery", false), ("recording", false)] {
        let model = AppModel(manifest: manifest, base: output.deletingLastPathComponent().appendingPathComponent("unused"), preview: true)
        model.configurePreview(state)
        readinessPassed = readinessPassed && model.canStart == expected
    }
    let previewPreferencesUnchanged = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) as? NSObject } == preferencesBefore
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
        "allPassed": roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged,
        "notTested": ["global paste shortcut", "live app insertion", "clipboard managers", "Universal Clipboard", "VoiceOver"]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    guard roundtrip && userCopyPreserved && oversizeRefused && readinessPassed && previewPreferencesUnchanged else { throw CompatibilityPaste.Failure.writeFailed }
}
