import Foundation

/// One poll of a source's capture ring.
public struct MeetingRingReading: Equatable, Sendable {
    public var samplesCaptured: UInt64
    /// `AudioRing.status`: 0 running, 1 closed, 2 overflowed because processing fell behind, 3 at its sample limit.
    public var status: Int
    /// RMS of the last block pushed.
    public var level: Float
    public init(samplesCaptured: UInt64, status: Int = 0, level: Float = 0) {
        self.samplesCaptured = samplesCaptured; self.status = status; self.level = level
    }
}

public enum MeetingHealthVerdict: Equatable, Sendable {
    /// No first audio: the start failed.
    case startFailed(MeetingStretchEnd)
    /// Stop the stretch; both sources stop, never one.
    case pause(MeetingStretchEnd)
    /// The stretch reached its bound: drain, then continue in a new stretch.
    case rollover
    /// Advisory only, never a stop.
    case quiet(MeetingSource), heard(MeetingSource)
}

/// Pure rules over one stretch's 100 ms pulse. Only stalls, permission and ring status stop a stretch;
/// a quiet call is normal, so energy never does.
public struct MeetingHealthMonitor: Sendable {
    public static let firstAudioSeconds: TimeInterval = 5
    public static let stallSeconds: TimeInterval = 5
    public static let quietSeconds: TimeInterval = 30
    /// RMS below which the other side counts as quiet, near the probes' silent mean energy (2e-7). UNVERIFIED on real calls.
    public static let quietLevel: Float = 0.0005
    /// Whether the tap delivers frames while the app is silent (UNVERIFIED until the live probe). Until it
    /// does, the Others first-audio and stall rules stay off and only the tap's listeners report a loss.
    public let othersDeliversSilence: Bool
    private var lastCount: [MeetingSource: UInt64] = [:]
    private var lastProgress: [MeetingSource: TimeInterval] = [:]
    private var quietSince: TimeInterval?
    private var othersQuiet = false

    public init(othersDeliversSilence: Bool = false) { self.othersDeliversSilence = othersDeliversSilence }

    /// `elapsed` counts from the stretch's start; `others` is nil without the app's sound.
    public mutating func poll(elapsed: TimeInterval, you: MeetingRingReading, others: MeetingRingReading?, microphoneAuthorized: Bool) -> [MeetingHealthVerdict] {
        let othersAdvanced = others.map { $0.samplesCaptured != lastCount[.others] } ?? false
        track(.you, you, elapsed)
        if let others { track(.others, others, elapsed) }
        guard microphoneAuthorized else { return [.pause(.microphonePermission)] }
        let rings = [you] + (others.map { [$0] } ?? [])
        if rings.contains(where: { $0.status == 2 }) { return [.pause(.processingFellBehind)] }
        if rings.contains(where: { $0.status == 3 }) { return [.rollover] }
        if let verdict = audioVerdict(.you, you, elapsed, first: .microphoneStalled, stalled: .microphoneStalled) { return [verdict] }
        if let others, othersDeliversSilence,
           let verdict = audioVerdict(.others, others, elapsed, first: .computerAudioStalled, stalled: .computerAudioStalled) { return [verdict] }
        guard let others else { return [] }
        // A tap that delivers nothing during silence keeps its last level, so no new audio also counts as quiet.
        if others.level < Self.quietLevel || !othersAdvanced {
            let since = quietSince ?? elapsed
            quietSince = since
            guard !othersQuiet, elapsed - since >= Self.quietSeconds else { return [] }
            othersQuiet = true
            return [.quiet(.others)]
        }
        quietSince = nil
        guard othersQuiet else { return [] }
        othersQuiet = false
        return [.heard(.others)]
    }

    private mutating func track(_ source: MeetingSource, _ reading: MeetingRingReading, _ elapsed: TimeInterval) {
        guard reading.samplesCaptured != lastCount[source] else { return }
        lastCount[source] = reading.samplesCaptured; lastProgress[source] = elapsed
    }

    private func audioVerdict(_ source: MeetingSource, _ reading: MeetingRingReading, _ elapsed: TimeInterval,
                              first: MeetingStretchEnd, stalled: MeetingStretchEnd) -> MeetingHealthVerdict? {
        if reading.samplesCaptured == 0 { return elapsed >= Self.firstAudioSeconds ? .startFailed(first) : nil }
        return elapsed - (lastProgress[source] ?? elapsed) >= Self.stallSeconds ? .pause(stalled) : nil
    }
}

/// Whether the meeting app's call is still on, used only for the call-end pause. It reads the app's own
/// microphone-use flag (from the tapped processes, or the reminder watcher in a microphone-only meeting)
/// and holds no reminder state, so offers, dismissals and turning reminders off never affect it.
public struct MeetingCallMonitor: Sendable {
    /// Consecutive "off" readings before the call counts as ended (about 6 s at a 2 s poll).
    public static let endConfirmations = 3
    public let app: MeetingApp
    private var active = false
    private var offReadings = 0

    public init(app: MeetingApp) { self.app = app }

    /// True exactly once when a call that was seen active has been off for `endConfirmations` readings.
    public mutating func observe(usingMicrophone: Bool) -> Bool {
        if usingMicrophone { active = true; offReadings = 0; return false }
        guard active else { return false }
        offReadings += 1
        guard offReadings >= Self.endConfirmations else { return false }
        active = false; offReadings = 0
        return true
    }

    public mutating func observe(_ clients: [AudioClientSnapshot]) -> Bool {
        observe(usingMicrophone: clients.contains { $0.runningInput && app.matches($0.bundleID) })
    }
}
