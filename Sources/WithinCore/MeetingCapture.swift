import Foundation

/// A source's state for the meeting screen, the capsule and diagnostics. A closed set.
public enum MeetingSourceState: String, Encodable, Sendable { case off, live, quiet, lost }

/// Meeting-relative time from a monotonic clock that keeps counting through sleep. In one run of the app
/// a later stretch starts at the previous end plus the measured pause; Resume never restarts the clock.
public struct MeetingClock: Sendable {
    private var anchor: (monotonic: TimeInterval, offset: TimeInterval)?

    public init() {}

    /// Where a new stretch of `meeting` starts. A meeting continued after a relaunch has no anchor yet, so it
    /// starts at the wall-clock time since it was created. Either way never before its last end or its last words.
    public mutating func startStretch(of meeting: Meeting, monotonic: TimeInterval, now: Date) -> TimeInterval {
        let floor = max(meeting.stretches.map { $0.end ?? $0.lastCheckpoint }.max() ?? 0, meeting.segments.map(\.offset).max() ?? 0)
        let start = max(offset(at: monotonic) ?? now.timeIntervalSince(meeting.created), floor)
        anchor = (monotonic, start)
        return start
    }

    /// Nil until the first stretch of this run.
    public func offset(at monotonic: TimeInterval) -> TimeInterval? { anchor.map { $0.offset + monotonic - $0.monotonic } }

    /// When text settles: now, but never after the stretch's end while its rings drain, and never before
    /// the last turn, so offsets only increase in transcript order.
    public static func textOffset(_ now: TimeInterval, stretchEnd: TimeInterval?, lastSegment: TimeInterval?) -> TimeInterval {
        max(min(now, stretchEnd ?? now), lastSegment ?? -.infinity)
    }
}

/// Which speech updates of a stretch still apply: only the current stretch's, each source's in the order
/// produced, and nothing after that source's final result.
public struct MeetingUpdateFilter: Sendable {
    private var stretch: Int?
    private var lastSequence: [MeetingSource: Int] = [:]
    private var finished: Set<MeetingSource> = []

    public init() {}

    public mutating func begin(stretch: Int) { self.stretch = stretch; lastSequence = [:]; finished = [] }

    public mutating func admit(stretch: Int, source: MeetingSource, sequence: Int, final: Bool) -> Bool {
        guard stretch == self.stretch, !finished.contains(source), sequence > lastSequence[source, default: Int.min] else { return false }
        lastSequence[source] = sequence
        if final { finished.insert(source) }
        return true
    }
}
