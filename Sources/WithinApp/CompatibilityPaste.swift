import AppKit
import WithinCore

@MainActor
final class CompatibilityPaste {
    struct SavedItem { let representations: [(NSPasteboard.PasteboardType, Data)] }
    enum Failure: Error { case cannotPreserve, changed, writeFailed }
    struct Snapshot { let items: [SavedItem]; let changeCount: Int }
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func snapshot(_ board: NSPasteboard) throws -> Snapshot {
        let changeCount = board.changeCount
        let original = board.pasteboardItems ?? []
        guard original.count <= 128 else { throw Failure.cannotPreserve }
        var bytes = 0
        var items: [SavedItem] = []
        for item in original {
            guard item.types.count <= 64 else { throw Failure.cannotPreserve }
            var representations: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { throw Failure.cannotPreserve }
                bytes += data.count
                guard bytes <= 8_388_608 else { throw Failure.cannotPreserve }
                representations.append((type, data))
            }
            items.append(.init(representations: representations))
        }
        guard board.changeCount == changeCount else { throw Failure.changed }
        return Snapshot(items: items, changeCount: changeCount)
    }

    static func restore(_ snapshot: Snapshot, to board: NSPasteboard, lease: ClipboardLease) -> Bool {
        guard lease.mayRestore(currentChangeCount: board.changeCount) else { return true } // Respect a newer copy.
        let clearCount = board.clearContents()
        let items = snapshot.items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.representations { item.setData(data, forType: type) }
            return item
        }
        guard board.changeCount == clearCount else { return true }
        return items.isEmpty || board.writeObjects(items)
    }

    /// Returns an explanation for review. Synthetic key posting cannot confirm
    /// insertion, so this operation never claims success or discards the text.
    static func perform(text: String, target: AccessibilityTarget, stillCurrent: () -> Bool) async -> String {
        for _ in 0..<100 {
            guard stillCurrent(), !Task.isCancelled else { return "Canceled before paste." }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        guard flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty else { return "Release the shortcut keys, then copy your words when you’re ready." }
        guard stillCurrent(), !Task.isCancelled, target.evidence(forCompatibilityPaste: true).blockReason == nil else { return "The destination changed before paste. Your words stayed here." }
        let board = NSPasteboard.general
        let saved: Snapshot
        do { saved = try snapshot(board) }
        catch { return "Within couldn’t safely preserve the current clipboard. Your words stayed here for manual Copy." }
        guard stillCurrent(), board.changeCount == saved.changeCount,
              target.evidence(forCompatibilityPaste: true).blockReason == nil else { return "The destination or clipboard changed. Your words stayed here." }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return "The paste action wasn’t available. Copy your words manually." }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string); item.setData(Data(), forType: transient); item.setData(Data(), forType: concealed)
        let clearCount = board.clearContents()
        guard board.changeCount == clearCount else { return "Your clipboard changed before paste. Your words stayed here." }
        guard board.writeObjects([item]) else {
            _ = restore(saved, to: board, lease: .init(ownedChangeCount: clearCount))
            return "Clipboard preparation failed. Check your clipboard before using Copy."
        }
        let lease = ClipboardLease(ownedChangeCount: board.changeCount)
        guard stillCurrent(), !Task.isCancelled, target.evidence(forCompatibilityPaste: true).blockReason == nil else {
            _ = restore(saved, to: board, lease: lease)
            return "The destination changed. Paste was canceled; your words stayed here."
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // A target may read the clipboard asynchronously. This delay is a preview
        // hypothesis to validate in the app matrix, never a success signal.
        try? await Task.sleep(for: .milliseconds(700))
        let restored = restore(saved, to: board, lease: lease)
        return restored
            ? "Paste was attempted. Check the original field before copying to avoid duplicate text. Discard these words if they arrived."
            : "Paste was attempted, but the previous clipboard couldn’t be restored. Check both the original field and clipboard before continuing."
    }
}
