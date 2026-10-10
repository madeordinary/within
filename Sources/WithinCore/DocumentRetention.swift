import Foundation

/// How long saved documents are kept before they are deleted automatically. An unset preference
/// means keep until deleted. Deleting is not a secure erase, and existing backups may keep copies.
public enum DocumentRetention: String, CaseIterable, Codable, Sendable {
    case untilDeleted, days30, days90, days365

    public var interval: TimeInterval? {
        switch self {
        case .untilDeleted: return nil
        case .days30: return 30 * 86_400
        case .days90: return 90 * 86_400
        case .days365: return 365 * 86_400
        }
    }

    public var title: String {
        switch self {
        case .untilDeleted: return "Until I delete"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .days365: return "365 days"
        }
    }

    public static func restored(from value: String?) -> DocumentRetention { value.flatMap(Self.init(rawValue:)) ?? .untilDeleted }

    /// Items whose last activity is at least the retention interval before `now`.
    public func expired(_ items: [(id: UUID, lastActivity: Date)], now: Date) -> [UUID] {
        guard let interval else { return [] }
        let cutoff = now.addingTimeInterval(-interval)
        return items.filter { $0.lastActivity <= cutoff }.map(\.id)
    }

    /// Age counts from each meeting's most recent capture, and an open meeting is never deleted.
    public func expired(_ meetings: [Meeting], now: Date) -> [UUID] {
        expired(meetings.filter { $0.state == .finished }.map { ($0.id, $0.lastCapture) }, now: now)
    }
}
