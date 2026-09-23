/// Non-content policy for best-effort pasteboard restoration. A different
/// generation belongs to another writer and must never be overwritten.
public struct ClipboardLease {
    public let ownedChangeCount: Int
    public init(ownedChangeCount: Int) { self.ownedChangeCount = ownedChangeCount }
    public func mayRestore(currentChangeCount: Int) -> Bool { ownedChangeCount == currentChangeCount }
}
