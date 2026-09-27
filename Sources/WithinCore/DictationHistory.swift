import Foundation

/// How long optional local dictation history is kept. An unset preference means the user
/// has not chosen yet, which behaves exactly like `off`: nothing is saved.
public enum HistoryRetention: String, CaseIterable, Codable, Sendable {
    case off, day, week, month, forever
    public var interval: TimeInterval? {
        switch self {
        case .off: return 0
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .forever: return nil
        }
    }
    public var keepsHistory: Bool { self != .off }
    public var title: String {
        switch self {
        case .off: return "Off"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        case .forever: return "Until I delete"
        }
    }
    public static func restored(from value: String?) -> HistoryRetention? { value.flatMap(Self.init(rawValue:)) }
}

/// Only final dictated text and its time: no audio, destination, window title, or field content.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
    public init(id: UUID = UUID(), date: Date, text: String) {
        self.id = id; self.date = date; self.text = text
    }
}

public enum HistoryPolicy {
    /// Newest first, limited to the chosen retention window.
    public static func prune(_ entries: [HistoryEntry], now: Date, retention: HistoryRetention) -> [HistoryEntry] {
        let sorted = entries.sorted { $0.date > $1.date }
        guard let interval = retention.interval else { return sorted }
        guard interval > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-interval)
        return sorted.filter { $0.date > cutoff }
    }

    public static func adding(_ text: String, at date: Date, to entries: [HistoryEntry], retention: HistoryRetention) -> [HistoryEntry] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard retention.keepsHistory, !clean.isEmpty else { return prune(entries, now: date, retention: retention) }
        return prune(entries + [HistoryEntry(date: date, text: clean)], now: date, retention: retention)
    }

    public static func matching(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
