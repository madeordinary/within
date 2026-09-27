import Foundation

public enum MeetingSource: String, Codable, Sendable { case you, others }

/// One stretch of speech from one side of the call. Text only; audio is never stored.
public struct MeetingSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let source: MeetingSource
    /// Seconds after capture started when this stretch was first transcribed.
    public let offset: TimeInterval
    public var text: String
    public init(id: UUID = UUID(), source: MeetingSource, offset: TimeInterval, text: String) {
        self.id = id; self.source = source; self.offset = offset; self.text = text
    }
}

/// A meeting's labelled transcript and the user's own notes, kept separate.
public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let created: Date
    public var modified: Date
    /// Where the other side's audio came from, e.g. "Zoom"; "Microphone only" without app audio.
    public var appName: String
    public var segments: [MeetingSegment]
    public var notes: String

    public init(id: UUID = UUID(), title: String = "", created: Date, appName: String, segments: [MeetingSegment] = [], notes: String = "") {
        self.id = id; self.title = title; self.created = created; self.modified = created
        self.appName = appName; self.segments = segments; self.notes = notes
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(appName) meeting" : trimmed
    }
}

/// Turns each stream's growing transcript into alternating, labelled turns in arrival order.
/// The open turn is always re-derived from its stream's whole text, so updates never split words.
public struct MeetingTranscriptBuilder: Sendable {
    public private(set) var segments: [MeetingSegment]
    private var latest: [MeetingSource: String] = [:]
    private var consumed: [MeetingSource: Int] = [:]
    private var openStart: [MeetingSource: Int] = [:]

    public init(segments: [MeetingSegment] = []) { self.segments = segments }

    /// `transcript` is the stream's whole confirmed (or final) text since its session began.
    public mutating func update(_ source: MeetingSource, transcript: String, at offset: TimeInterval) {
        let current = TranscriptFormatting.clean(transcript)
        latest[source] = current
        if let start = openStart[source], let last = segments.indices.last, segments[last].source == source {
            let text = String(current.dropFirst(start)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { segments[last].text = text }
            return
        }
        let start = consumed[source] ?? 0
        // A new turn never begins with the previous turn's trailing punctuation.
        let text = String(String(current.dropFirst(start)).drop { " .,;:!?".contains($0) })
        guard !text.isEmpty else { return }
        // The other side's open turn is complete once this side speaks.
        for other in openStart.keys where other != source { consumed[other] = latest[other]?.count ?? 0 }
        openStart = [source: start]
        segments.append(MeetingSegment(source: source, offset: offset, text: text))
    }

    /// A pause (lock, sleep, call ended) ends every turn; resumed speech sessions start empty.
    public mutating func markGap() { latest = [:]; consumed = [:]; openStart = [:] }
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

/// An audio client seen by Core Audio: bundle ID and whether it is capturing input.
public struct AudioClientSnapshot: Equatable, Sendable {
    public let bundleID: String
    public let runningInput: Bool
    public init(bundleID: String, runningInput: Bool) { self.bundleID = bundleID; self.runningInput = runningInput }
}

public enum MeetingDetectionEvent: Equatable, Sendable { case offer(MeetingApp), withdraw(MeetingApp) }

/// Opt-in meeting reminders. A call is a meeting app starting microphone input; launching
/// the app alone never counts. Offers once per call; nothing is ever captured by this type.
public struct MeetingDetector: Sendable {
    public var enabled: Bool
    public var apps: [MeetingApp]
    private var inCall: Set<MeetingApp> = []
    private var dismissed: Set<MeetingApp> = []
    private var snoozedUntil: Date?

    public init(enabled: Bool = false, apps: [MeetingApp] = [.zoom, .teams]) { self.enabled = enabled; self.apps = apps }

    public mutating func observe(_ clients: [AudioClientSnapshot], now: Date, captureActive: Bool) -> [MeetingDetectionEvent] {
        guard enabled else { inCall = []; dismissed = []; return [] }
        var events: [MeetingDetectionEvent] = []
        for app in apps {
            let using = clients.contains { $0.runningInput && app.matches($0.bundleID) }
            if using && !inCall.contains(app) {
                inCall.insert(app)
                let snoozed = snoozedUntil.map { now < $0 } ?? false
                if !captureActive && !dismissed.contains(app) && !snoozed { events.append(.offer(app)) }
            } else if !using && inCall.contains(app) {
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
