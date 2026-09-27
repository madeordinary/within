import Foundation

/// A saved voice note: text only. Audio is never stored.
public struct Note: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let created: Date
    public var modified: Date
    public var body: String

    public init(id: UUID = UUID(), title: String = "", created: Date, body: String = "") {
        self.id = id; self.title = title; self.created = created; self.modified = created; self.body = body
    }

    /// Untitled notes are named by their first words, then by their date.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let words = body.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.isEmpty ? "New note" : words
    }
}

public enum NoteText {
    /// Appends a finished stretch of transcript as its own paragraph, never merging into
    /// the user's last typed line.
    public static func appending(_ transcript: String, to body: String) -> String {
        let clean = TranscriptFormatting.clean(transcript)
        guard !clean.isEmpty else { return body }
        let existing = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? clean : body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n\n" + clean
    }

    /// A visible marker where recording paused (lock, sleep, backlog, or the user's Pause).
    public static func gapMarker(reason: String) -> String { "— \(reason) —" }

    public static func newestFirst(_ notes: [Note]) -> [Note] { notes.sorted { $0.modified > $1.modified } }

    public static func matching(_ notes: [Note], query: String) -> [Note] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }
        return notes.filter {
            $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.body.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
