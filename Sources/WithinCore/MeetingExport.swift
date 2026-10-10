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

extension Meeting {
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

    /// Turns that personal dictionary fixes changed.
    public var fixedTurns: Int { segments.filter { $0.original != nil }.count }
}

public enum MeetingSearch {
    /// Title, notes, each turn's text and its original transcription; ignores case and accents.
    public static func matching(_ meetings: [Meeting], query: String) -> [Meeting] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return meetings }
        func found(_ text: String?) -> Bool { text?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return meetings.filter { meeting in
            found(meeting.title) || found(meeting.notes) || meeting.segments.contains { found($0.text) || found($0.original) }
        }
    }
}

/// Markdown for a copy saved outside Within. One version of each turn: the fixed text by default,
/// or the original transcription when asked; never both.
public enum MeetingExport {
    public static func markdown(_ meeting: Meeting, useOriginalTranscription: Bool = false, timeZone: TimeZone = .current) -> String {
        let microphoneOnly = meeting.appName == Meeting.microphoneOnly || meeting.appName.isEmpty
        let length = meeting.stretches.last.map { $0.end ?? $0.lastCheckpoint } ?? 0
        var header = [
            "# \(meeting.displayTitle)",
            "\(format("yyyy-MM-dd HH:mm", meeting.created, timeZone)) · \(microphoneOnly ? Meeting.microphoneOnly : meeting.appName) · \(duration(length))",
            microphoneOnly
                ? "Transcribed on this Mac by Within. \"You\" is the microphone. Labels are sources, not people."
                : "Transcribed on this Mac by Within. \"You\" is the microphone; \"Others\" is \(meeting.appName)’s audio. Labels are sources, not people.",
        ]
        let fixes = meeting.fixedTurns
        if fixes > 0 {
            header.append(useOriginalTranscription ? "Original transcription, without personal dictionary fixes."
                : "Personal dictionary fixes were applied in \(fixes) \(fixes == 1 ? "turn" : "turns"). The original transcription stays in Within.")
        }
        var transcript: [String] = []
        var gaps = meeting.gaps[...]
        func gapLine(_ gap: MeetingGap) -> String {
            "*— \(gap.label) \(clock(gap.start))–\(clock(gap.end))\(gap.detail(appName: meeting.appName).map { " · " + $0 } ?? "") —*"
        }
        for segment in meeting.segments {
            while let gap = gaps.first, segment.offset > gap.start { transcript.append(gapLine(gap)); gaps = gaps.dropFirst() }
            let text = useOriginalTranscription ? segment.original ?? segment.text : segment.text
            transcript.append("**[\(clock(segment.offset))] \(segment.source == .you ? "You" : "Others"):** \(text)")
        }
        transcript += gaps.map(gapLine)
        if let stop = meeting.stop {
            transcript.append("*— Stopped at \(clock(stop.at))\(stop.detail(appName: meeting.appName).map { " · " + $0 } ?? "") —*")
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
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
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
