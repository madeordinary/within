import Foundation

/// The time between two stretches, with the reason the earlier one ended.
public struct MeetingGap: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let reason: MeetingStretchEnd
    public init(start: TimeInterval, end: TimeInterval, reason: MeetingStretchEnd) {
        self.start = start; self.end = end; self.reason = reason
    }

    /// "Paused", or what continued, for the gap marker.
    public var label: String { reason == .durationLimit ? "Continued past three hours (untested length)" : "Paused" }

    /// Why, in words, without the leading label; nil for the Pause button.
    public func detail(appName: String) -> String? {
        switch reason {
        case .pauseButton, .durationLimit: return nil
        case .finished: return "the meeting was finished, then continued"
        case .lockOrSleep: return "the Mac locked or slept"
        case .userSwitched: return "you switched users"
        case .callEnded: return "the call ended"
        case .microphoneLost: return "the microphone was disconnected or changed"
        case .microphoneStalled: return "the microphone stopped sending audio"
        case .microphonePermission: return "microphone access changed"
        case .computerAudioLost: return "\(appName)’s sound or the output device changed"
        case .computerAudioChanged: return "\(appName) started another audio process"
        case .computerAudioStalled: return "\(appName)’s sound stopped arriving"
        case .processingFellBehind: return "speech processing fell behind"
        case .speechError: return "a speech processing error; the last words may be missing"
        case .quit: return "Within quit"
        case .quitBeforeDrain: return "Within quit before the last seconds were transcribed"
        case .unexpectedExit: return "Within closed unexpectedly; the last words may be missing"
        }
    }
}

/// Where a finished meeting's capture stopped with its last words possibly missing and never continued:
/// a quit before the drain finished, a crash, or a speech error.
public struct MeetingStop: Equatable, Sendable {
    public static let reasons: Set<MeetingStretchEnd> = [.quitBeforeDrain, .unexpectedExit, .speechError]
    public let at: TimeInterval
    public let reason: MeetingStretchEnd
    public init(at: TimeInterval, reason: MeetingStretchEnd) { self.at = at; self.reason = reason }

    public func detail(appName: String) -> String? { MeetingGap(start: at, end: at, reason: reason).detail(appName: appName) }
}

/// One line of a meeting as the screen and the export list it.
public enum MeetingTimelineRow: Equatable, Identifiable, Sendable {
    case turn(MeetingSegment)
    /// `index` counts the meeting's gaps, so each keeps its identity as turns are added.
    case gap(MeetingGap, index: Int)
    case stop(MeetingStop)

    public var id: String {
        switch self {
        case .turn(let segment): return segment.id.uuidString
        case .gap(_, let index): return "gap-\(index)"
        case .stop: return "stop"
        }
    }
}

extension Meeting {
    /// Meeting-relative seconds captured: where the last stretch ended, or its last checkpoint while it is open.
    public var length: TimeInterval { stretches.last.map { $0.end ?? $0.lastCheckpoint } ?? 0 }

    /// Whether the meeting app's sound was included, rather than the microphone alone.
    public var includesAppSound: Bool { !appName.isEmpty && appName != Self.microphoneOnly }

    /// Within closed unexpectedly during it, and it hasn't been continued since.
    public var recovered: Bool { stop?.reason == .unexpectedExit }

    /// Turns in order, each gap before the first turn after it began, and where the meeting stopped without its last words.
    public var timeline: [MeetingTimelineRow] {
        var rows: [MeetingTimelineRow] = []
        var gaps = Array(self.gaps.enumerated())[...]
        for segment in segments {
            while let next = gaps.first, segment.offset > next.element.start {
                rows.append(.gap(next.element, index: next.offset)); gaps = gaps.dropFirst()
            }
            rows.append(.turn(segment))
        }
        rows += gaps.map { .gap($0.element, index: $0.offset) }
        if let stop { rows.append(.stop(stop)) }
        return rows
    }

    /// Gap markers: the end of each closed stretch to the start of the next.
    public var gaps: [MeetingGap] {
        zip(stretches, stretches.dropFirst()).compactMap { earlier, later in
            guard let end = earlier.end, let reason = earlier.ended else { return nil }
            return MeetingGap(start: end, end: max(end, later.start), reason: reason)
        }
    }

    /// The marker after the last turn when the meeting ended without its last words.
    public var stop: MeetingStop? {
        guard state == .finished, let last = stretches.last, let end = last.end, let reason = last.ended,
              MeetingStop.reasons.contains(reason) else { return nil }
        return MeetingStop(at: end, reason: reason)
    }
}

/// The personal dictionary in meetings, applied to saved turns whenever a meeting is read: shown, searched or
/// exported. A turn is stored exactly as transcribed, so its `text` is always the original transcription, and editing
/// the dictionary changes how every meeting reads. You and Others alike, one turn at a time: a phrase split across two
/// turns never matches. Provisional text and notes are never changed. Pass the current dictionary each time; nothing
/// is cached.
public enum MeetingSpellings {
    /// One turn in your spellings, and what changed. Linear in the turn's length, so it suits each visible row.
    public static func turn(_ segment: MeetingSegment, dictionary: DictionaryMatcher) -> DictionaryResult {
        dictionary.apply(to: segment.text)
    }

    /// Turns the dictionary changes. Linear in the whole transcript: compute it once per meeting and dictionary.
    public static func fixedTurns(in meeting: Meeting, dictionary: DictionaryMatcher) -> Int {
        dictionary.isEmpty ? 0 : meeting.segments.filter { turn($0, dictionary: dictionary).changed }.count
    }
}

public enum MeetingSearch {
    /// Title, notes, and each turn as transcribed or in your spellings; ignores case and accents.
    public static func matching(_ meetings: [Meeting], query: String, dictionary: DictionaryMatcher) -> [Meeting] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return meetings }
        func found(_ text: String) -> Bool { text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return meetings.filter { meeting in
            found(meeting.title) || found(meeting.notes) || meeting.segments.contains { segment in
                if found(segment.text) { return true }
                let spelled = MeetingSpellings.turn(segment, dictionary: dictionary)
                return spelled.changed && found(spelled.text)
            }
        }
    }
}

/// Markdown for a copy saved outside Within. One version of each turn: your spellings from the current dictionary by
/// default, or the original transcription when asked; never both.
public enum MeetingExport {
    public static func markdown(_ meeting: Meeting, dictionary: DictionaryMatcher, useOriginalTranscription: Bool = false,
                                timeZone: TimeZone = .current) -> String {
        let microphoneOnly = !meeting.includesAppSound
        var header = [
            "# \(meeting.displayTitle)",
            "\(format("yyyy-MM-dd HH:mm", meeting.created, timeZone)) · \(microphoneOnly ? Meeting.microphoneOnly : meeting.appName) · \(duration(meeting.length))",
            microphoneOnly
                ? "Transcribed on this Mac by Within. \"You\" is the microphone. Labels are sources, not people."
                : "Transcribed on this Mac by Within. \"You\" is the microphone; \"Others\" is \(meeting.appName)’s audio. Labels are sources, not people.",
        ]
        let spelled = meeting.segments.map { MeetingSpellings.turn($0, dictionary: dictionary) }
        let fixes = spelled.filter(\.changed).count
        if fixes > 0 {
            header.append(useOriginalTranscription ? "Original transcription, without personal dictionary fixes."
                : "Personal dictionary fixes were applied in \(fixes) \(fixes == 1 ? "turn" : "turns"). The original transcription stays in Within.")
        }
        var turn = 0
        let transcript = meeting.timeline.map { row -> String in
            switch row {
            case .turn(let segment):
                defer { turn += 1 }
                let text = useOriginalTranscription ? segment.text : spelled[turn].text
                return "**[\(clock(segment.offset))] \(segment.source == .you ? "You" : "Others"):** \(text)"
            case .gap(let gap, _):
                return "*— \(gap.label) \(clock(gap.start))–\(clock(gap.end))\(gap.detail(appName: meeting.appName).map { " · " + $0 } ?? "") —*"
            case .stop(let stop):
                return "*— Stopped at \(clock(stop.at))\(stop.detail(appName: meeting.appName).map { " · " + $0 } ?? "") —*"
            }
        }
        // Blank lines keep each line its own paragraph in any Markdown reader.
        var blocks = [header.joined(separator: "\n\n"), "## Transcript", transcript.joined(separator: "\n\n")]
        if !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks += ["## My notes", meeting.notes] }
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    /// "<title> <yyyy-MM-dd>.md", with characters Finder can't use in a name replaced.
    public static func fileName(_ meeting: Meeting, timeZone: TimeZone = .current) -> String {
        let title = meeting.displayTitle.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }
        let name = String(String(title).drop { $0 == "." || $0.isWhitespace })
        return "\(name.isEmpty ? "Meeting" : name) \(format("yyyy-MM-dd", meeting.created, timeZone)).md"
    }

    /// Hours:minutes:seconds, always two-digit hours, for timestamps and gap markers.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// "1:12:04": a meeting's length.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func format(_ pattern: String, _ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Crash recovery at launch. Capture is never restarted; an open meeting would block Dictation, so
/// every recovered meeting is finished, and one that holds nothing is deleted.
public enum MeetingRecovery {
    public struct Result: Equatable, Sendable {
        public var recovered: [Meeting] = []
        public var deleted: [UUID] = []
    }

    public static func recover(_ meetings: [Meeting]) -> Result {
        var result = Result()
        func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for meeting in meetings where meeting.state == .open {
            if meeting.segments.isEmpty && blank(meeting.notes) && blank(meeting.title) { result.deleted.append(meeting.id); continue }
            var recovered = meeting
            for index in recovered.stretches.indices where recovered.stretches[index].end == nil {
                let stretch = recovered.stretches[index]
                let lastWords = recovered.segments.filter { $0.offset >= stretch.start }.map(\.offset).max() ?? stretch.start
                recovered.stretches[index].end = max(stretch.lastCheckpoint, stretch.start, lastWords)
                recovered.stretches[index].ended = .unexpectedExit
            }
            recovered.state = .finished
            result.recovered.append(recovered)
        }
        return result
    }
}
