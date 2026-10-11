import Foundation

public enum MeetingSource: String, Codable, Sendable { case you, others }

/// One stretch of speech from one side of the call. Text only; audio is never stored.
public struct MeetingSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let source: MeetingSource
    /// Meeting-relative seconds when this turn's text first settled: its stretch's start plus the
    /// time since, counted through sleep. Resume never restarts the clock.
    public let offset: TimeInterval
    /// The original transcription: the speech model's hypothesis, not a record of what was said. The personal
    /// dictionary is applied only when the meeting is read (`MeetingSpellings`), never stored.
    public var text: String
    public init(id: UUID = UUID(), source: MeetingSource, offset: TimeInterval, text: String) {
        self.id = id; self.source = source; self.offset = offset; self.text = text
    }

    private enum EarlierKeys: String, CodingKey { case original }

    /// A file from when fixes were stored may also hold `original`, the transcription before them. That is the
    /// text kept, so the current dictionary applies to it like any other turn.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(MeetingSource.self, forKey: .source)
        offset = try values.decode(TimeInterval.self, forKey: .offset)
        let stored = try values.decode(String.self, forKey: .text)
        text = try decoder.container(keyedBy: EarlierKeys.self).decodeIfPresent(String.self, forKey: .original) ?? stored
    }
}

/// Why a stretch of capture ended. A closed set: stored in meetings and safe for diagnostics.
public enum MeetingStretchEnd: String, Codable, CaseIterable, Sendable {
    case finished, pauseButton = "pause_button", lockOrSleep = "lock_or_sleep", userSwitched = "user_switched"
    case callEnded = "call_ended", microphoneLost = "microphone_lost", microphoneStalled = "microphone_stalled"
    case microphonePermission = "microphone_permission", computerAudioLost = "computer_audio_lost"
    case computerAudioChanged = "computer_audio_changed", computerAudioStalled = "computer_audio_stalled"
    case processingFellBehind = "processing_fell_behind", durationLimit = "duration_limit", speechError = "speech_error"
    case quit, quitBeforeDrain = "quit_before_drain", unexpectedExit = "unexpected_exit"
}

/// One continuous capture period with its own sources. Gaps are the time between stretches.
public struct MeetingStretch: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Meeting-relative seconds.
    public let start: TimeInterval
    /// Nil only while capturing.
    public var end: TimeInterval?
    /// Meeting-relative offset of this stretch's last checkpoint, where crash recovery closes it.
    public var lastCheckpoint: TimeInterval
    public let sources: [MeetingSource]
    public var ended: MeetingStretchEnd?
    public init(id: UUID = UUID(), start: TimeInterval, sources: [MeetingSource], end: TimeInterval? = nil, ended: MeetingStretchEnd? = nil) {
        self.id = id; self.start = start; self.sources = sources; self.end = end; self.ended = ended
        lastCheckpoint = end ?? start
    }
}

/// Open while preparing, recording or paused. A crashed open meeting is recovered as finished.
public enum MeetingRecordState: String, Codable, Sendable { case open, finished }

/// A meeting's labelled transcript and the user's own notes, kept separate.
public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    /// `appName` for a meeting without another app's sound.
    public static let microphoneOnly = "Microphone only"
    public let id: UUID
    public var title: String
    public let created: Date
    public var modified: Date
    /// Where the other side's audio came from, e.g. "Zoom"; "Microphone only" without app audio.
    public var appName: String
    /// Settled words only; the still-changing tail is never saved.
    public var segments: [MeetingSegment]
    /// The user's own text; never transformed.
    public var notes: String
    public var stretches: [MeetingStretch]
    public var state: MeetingRecordState

    public init(id: UUID = UUID(), title: String = "", created: Date, appName: String, segments: [MeetingSegment] = [], notes: String = "",
                stretches: [MeetingStretch] = [], state: MeetingRecordState = .open) {
        self.id = id; self.title = title; self.created = created; self.modified = created
        self.appName = appName; self.segments = segments; self.notes = notes; self.stretches = stretches; self.state = state
    }

    /// Untitled meetings are named by their app; a microphone-only one is just "Meeting".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return appName.isEmpty || appName == Self.microphoneOnly ? "Meeting" : "\(appName) meeting"
    }

    /// When words were last captured; retention counts from here, so continuing a meeting restarts its clock.
    public var lastCapture: Date { created.addingTimeInterval(stretches.last.map { $0.end ?? $0.lastCheckpoint } ?? 0) }
}

/// Turns each stream's growing transcript into alternating, labelled turns in arrival order, exactly as
/// transcribed. The open turn is always re-derived from its stream's whole text, so updates never split words,
/// and every turn starts at a word, so the dictionary applied when a meeting is read matches each turn alone.
public struct MeetingTranscriptBuilder: Sendable {
    public private(set) var segments: [MeetingSegment]
    /// Counts gaps. An update tagged with an earlier stretch changes nothing.
    public private(set) var stretch = 0
    private var latest: [MeetingSource: String] = [:]
    /// Each stream's text already in closed turns. Kept as text, not a count, so a stream that
    /// shrinks or is re-spaced re-anchors instead of being sliced mid-word.
    private var consumed: [MeetingSource: String] = [:]
    private var open: MeetingSource?

    public init(segments: [MeetingSegment] = []) { self.segments = segments }

    /// `transcript` is the stream's whole settled (or final) text since its session began.
    public mutating func update(_ source: MeetingSource, transcript: String, at offset: TimeInterval, stretch: Int? = nil) {
        if let stretch, stretch != self.stretch { return }
        let current = TranscriptFormatting.clean(transcript)
        latest[source] = current
        let text = Self.turnText(current, after: consumed[source] ?? "")
        if open == source, let last = segments.indices.last {
            // A turn whose only words were withdrawn is removed rather than left showing them.
            guard !text.isEmpty else { segments.removeLast(); open = nil; return }
            segments[last].text = text
            return
        }
        guard !text.isEmpty else { return }
        // The other side's open turn is complete once this side speaks.
        if let other = open { consumed[other] = latest[other] ?? "" }
        open = source
        segments.append(MeetingSegment(source: source, offset: offset, text: text))
    }

    /// A pause (lock, sleep, call ended) ends every turn; resumed speech sessions start empty.
    public mutating func markGap() { latest = [:]; consumed = [:]; open = nil; stretch += 1 }

    /// The text after `anchor`, without the previous turn's trailing punctuation.
    static func turnText(_ current: String, after anchor: String) -> String {
        let start = anchorEnd(current, anchor)
        return String(current[start...].drop(while: trimsTurnStart)).trimmingCharacters(in: .whitespaces)
    }

    /// Where `current` continues past `anchor`. Runs of spaces compare as one, and a space next to punctuation
    /// may be missing on either side ("today ." vs "today."). Where the texts part inside a word of either one,
    /// the turn starts at that word in `current`, so it never starts mid-word or loses its first characters; a
    /// word the earlier turn already shows may repeat instead.
    static func anchorEnd(_ current: String, _ anchor: String) -> String.Index {
        var i = anchor.startIndex, j = current.startIndex
        while i < anchor.endIndex, j < current.endIndex {
            let a = anchor[i], c = current[j]
            if a.isWhitespace, c.isWhitespace {
                while i < anchor.endIndex, anchor[i].isWhitespace { i = anchor.index(after: i) }
                while j < current.endIndex, current[j].isWhitespace { j = current.index(after: j) }
            } else if a == c { i = anchor.index(after: i); j = current.index(after: j) }
            else if a.isWhitespace, !isWord(c) { i = anchor.index(after: i) }
            else if c.isWhitespace, !isWord(a) { j = current.index(after: j) }
            else { break }
        }
        if insideWord(current, at: j) || (i < anchor.endIndex && insideWord(anchor, at: i)) {
            while j > current.startIndex, !current[current.index(before: j)].isWhitespace { j = current.index(before: j) }
        }
        return j
    }

    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.first.map(DictionaryTokenizer.isWordScalar) ?? false
    }

    /// Whether `index` falls inside one word by the dictionary's rules, so "10:42", "1,000", "U.S." and
    /// "don't" stay whole.
    static func insideWord(_ text: String, at index: String.Index) -> Bool {
        typealias Words = DictionaryTokenizer
        let scalars = text.unicodeScalars
        guard index > scalars.startIndex, index < scalars.endIndex else { return false }
        let before = scalars.index(before: index), after = scalars.index(after: index)
        let previous = scalars[before], next = scalars[index]
        let earlier = before > scalars.startIndex ? scalars[scalars.index(before: before)] : nil
        let later = after < scalars.endIndex ? scalars[after] : nil
        // A joiner just before the index already sits between two word characters.
        if let earlier, Words.isJoiner(previous), Words.isWordScalar(earlier), Words.isWordScalar(next) { return true }
        if let earlier, Words.isDigitJoiner(previous), Words.isDigit(earlier), Words.isDigit(next) { return true }
        guard Words.isWordScalar(previous) else { return false }
        if Words.isWordScalar(next) { return true }
        guard let later else { return false }
        return (Words.isJoiner(next) && Words.isWordScalar(later)) || (Words.isDigitJoiner(next) && Words.isDigit(previous) && Words.isDigit(later))
    }

    /// Whitespace and closing punctuation in any script; opening marks such as "¿" or "(" begin the next turn.
    private static func trimsTurnStart(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            guard CharacterSet.punctuationCharacters.contains(scalar), scalar != "¿", scalar != "¡" else { return false }
            return ![.openPunctuation, .initialPunctuation].contains(scalar.properties.generalCategory)
        }
    }
}

/// When a source's still-changing tail counts as settled, so a speaker who goes quiet keeps their
/// last sentence in place and on disk. The text fed to the builder never gets shorter than the last
/// settled text. Make a new one for each stretch: a resumed stream starts empty.
public struct MeetingSettle: Sendable {
    /// One full window of further audio (11 s chunk + 2 s right context) with the tail unchanged.
    /// UNVERIFIED against real turn-taking.
    public static let audioSeconds: TimeInterval = 13
    /// Or this long with no new audio and no change, since the tap may deliver nothing in silence.
    /// UNVERIFIED against real turn-taking.
    public static let wallSeconds: TimeInterval = 15

    private var confirmed = "", volatile = ""
    private var audioSinceChange: TimeInterval = 0
    private var quietSince: TimeInterval?
    private var snapshot = ""

    public init() {}

    public static func isSettled(audioSinceChange: TimeInterval, quietSeconds: TimeInterval) -> Bool {
        audioSinceChange >= audioSeconds || quietSeconds >= wallSeconds
    }

    /// One report from the stream: its confirmed and volatile text together, and how much audio was appended since the last.
    public mutating func observe(confirmed: String, volatile: String, appendedSeconds: TimeInterval, at now: TimeInterval) {
        self.confirmed = confirmed
        if volatile != self.volatile { self.volatile = volatile; audioSinceChange = 0; quietSince = now }
        else { audioSinceChange += appendedSeconds }
        if appendedSeconds > 0 { quietSince = now }
    }

    /// Also checked on a timer, so it does not depend on new samples arriving.
    public func isSettled(at now: TimeInterval) -> Bool {
        !volatile.isEmpty && Self.isSettled(audioSinceChange: audioSinceChange, quietSeconds: now - (quietSince ?? now))
    }

    /// The text to feed the builder now, from the last report's pair, so confirmed and volatile never come from different reports.
    public mutating func feed(at now: TimeInterval) -> String {
        let fed: String
        if isSettled(at: now) { fed = confirmed.isEmpty ? volatile : confirmed + " " + volatile }
        else { fed = confirmed.count >= snapshot.count ? confirmed : snapshot }
        snapshot = fed
        return fed
    }
}

public struct MeetingApp: Equatable, Hashable, Sendable {
    public let name: String
    public let bundlePrefixes: [String]
    public init(name: String, bundlePrefixes: [String]) { self.name = name; self.bundlePrefixes = bundlePrefixes }
    public static let zoom = MeetingApp(name: "Zoom", bundlePrefixes: ["us.zoom."])
    /// Matches both new Teams (`com.microsoft.teams2`) and classic Teams (`com.microsoft.teams`).
    public static let teams = MeetingApp(name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"])
    public func matches(_ bundleID: String) -> Bool { bundlePrefixes.contains { bundleID.hasPrefix($0) } }
}

/// An audio client seen by Core Audio: bundle ID and whether it is capturing input or playing output.
public struct AudioClientSnapshot: Equatable, Sendable {
    public let bundleID: String
    public let runningInput: Bool
    public let runningOutput: Bool
    public init(bundleID: String, runningInput: Bool, runningOutput: Bool = false) {
        self.bundleID = bundleID; self.runningInput = runningInput; self.runningOutput = runningOutput
    }
}

public enum MeetingDetectionEvent: Equatable, Sendable { case offer(MeetingApp), withdraw(MeetingApp) }

/// Opt-in meeting reminders. A call is a meeting app starting microphone input; launching
/// the app alone never counts. Offers once per call; nothing is ever captured by this type.
public struct MeetingDetector: Sendable {
    public var enabled: Bool
    public var apps: [MeetingApp]
    /// Consecutive readings before a call counts as started, and as ended. The watcher uses 2 and 3,
    /// so a brief blip neither offers nor withdraws.
    public let confirmations: Int
    public let withdrawConfirmations: Int
    private var inCall: Set<MeetingApp> = []
    private var dismissed: Set<MeetingApp> = []
    private var snoozedUntil: Date?
    private var streak: [MeetingApp: Int] = [:]

    public init(enabled: Bool = false, apps: [MeetingApp] = [.zoom, .teams], confirmations: Int = 1, withdrawConfirmations: Int = 1) {
        self.enabled = enabled; self.apps = apps
        self.confirmations = confirmations; self.withdrawConfirmations = withdrawConfirmations
    }

    public mutating func observe(_ clients: [AudioClientSnapshot], now: Date, captureActive: Bool) -> [MeetingDetectionEvent] {
        // Off only stops offering: a call dismissed before reminders were turned off and on stays dismissed.
        guard enabled else { return [] }
        var events: [MeetingDetectionEvent] = []
        for app in apps {
            let using = clients.contains { $0.runningInput && app.matches($0.bundleID) }
            guard using != inCall.contains(app) else { streak[app] = 0; continue }
            let count = (streak[app] ?? 0) + 1
            guard count >= (using ? confirmations : withdrawConfirmations) else { streak[app] = count; continue }
            streak[app] = 0
            if using {
                inCall.insert(app)
                let snoozed = snoozedUntil.map { now < $0 } ?? false
                if !captureActive && !dismissed.contains(app) && !snoozed { events.append(.offer(app)) }
            } else {
                inCall.remove(app); dismissed.remove(app)
                events.append(.withdraw(app))
            }
        }
        return events
    }

    /// Dismiss holds until that call ends.
    public mutating func dismiss(_ app: MeetingApp) { dismissed.insert(app) }
    /// Snooze suppresses offers for calls that start before it expires; no offer is backfilled.
    public mutating func snooze(until date: Date) { snoozedUntil = date }
}

/// The reminder panel: shown for one call at a time, hidden by any action, the call ending, lock or
/// sleep, any capture starting, or reminders being turned off. The effects go to the detector or the meeting.
public struct MeetingReminderState: Equatable, Sendable {
    public struct Reminder: Equatable, Sendable {
        public let app: MeetingApp
        /// An earlier meeting is paused; Start notes finishes it before starting this one.
        public let pausedMeeting: Bool
    }
    public enum Event: Equatable, Sendable {
        case offer(MeetingApp, pausedMeeting: Bool), withdraw(MeetingApp)
        case startNotes, dismiss, snooze, lockOrSleep, captureStarted, remindersOff
    }
    public enum Effect: Equatable, Sendable {
        /// `MeetingDetector.dismiss`: this call is never offered again.
        case dismissCall(MeetingApp)
        case snooze(until: Date)
        case finishPausedMeeting
        /// The click is the acknowledgment.
        case startMeeting(MeetingApp)
    }
    public static let snoozeSeconds: TimeInterval = 3600
    public private(set) var shown: Reminder?

    public init() {}

    public mutating func handle(_ event: Event, now: Date) -> [Effect] {
        if case .offer(let app, let paused) = event { shown = Reminder(app: app, pausedMeeting: paused); return [] }
        guard let reminder = shown else { return [] }
        switch event {
        case .offer: return []
        case .withdraw(let app):
            if app == reminder.app { shown = nil }
            return []
        case .startNotes:
            shown = nil
            return (reminder.pausedMeeting ? [.finishPausedMeeting] : []) + [.startMeeting(reminder.app)]
        case .dismiss, .lockOrSleep, .captureStarted:
            shown = nil
            return [.dismissCall(reminder.app)]
        case .snooze:
            shown = nil
            return [.snooze(until: now.addingTimeInterval(Self.snoozeSeconds)), .dismissCall(reminder.app)]
        case .remindersOff:
            shown = nil
            return []
        }
    }
}
