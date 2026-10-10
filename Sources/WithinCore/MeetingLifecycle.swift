import Foundation

/// One meeting's capture lifecycle as a pure reducer. The controller performs the effects in order and
/// reports each completion with the generation its effect carried; anything tagged with an older
/// generation changes nothing. Leaving capture bumps the generation and stops both sources first.
public struct MeetingLifecycle: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable { case idle, preparing, recording, pausing, paused, finishing, discarding, finished }

    public enum Event: Equatable, Sendable {
        case start(acknowledged: Bool)
        case resume(acknowledged: Bool)
        /// The save a new or continued meeting makes before anything starts succeeded.
        case saved(generation: Int)
        /// That save failed, so the start is refused. Later checkpoint failures don't change the
        /// lifecycle: capture continues and the next save retries.
        case saveFailed(generation: Int)
        case sourcesLive(generation: Int)
        /// From the stretch task after its own cleanup while preparing, or the first-audio rule once live.
        case startFailed(MeetingStretchEnd, generation: Int)
        /// The Pause button, capsule or menu.
        case pause
        /// A health rule or a speech error stopped the stretch. A speech error while draining, tagged with
        /// the drain's generation, means the stretch's last words may be missing.
        case health(MeetingStretchEnd, generation: Int)
        /// `.lockOrSleep` or `.userSwitched`.
        case boundary(MeetingStretchEnd)
        case callEnded
        /// `.microphoneLost`, `.computerAudioLost` or `.computerAudioChanged`.
        case sourceLost(MeetingStretchEnd, generation: Int)
        case rollover(generation: Int)
        case finish, quit, discard
        case drained(generation: Int)
        /// The quit watchdog of the drain with this generation fired before it finished.
        case drainTimedOut(generation: Int)

        var generation: Int? {
            switch self {
            case .saved(let generation), .saveFailed(let generation), .sourcesLive(let generation), .startFailed(_, let generation),
                 .health(_, let generation), .sourceLost(_, let generation), .rollover(let generation), .drained(let generation),
                 .drainTimedOut(let generation): return generation
            default: return nil
            }
        }

        /// Why a stretch this event stops ends.
        var reason: MeetingStretchEnd? {
            switch self {
            case .pause: return .pauseButton
            case .callEnded: return .callEnded
            case .finish: return .finished
            case .quit: return .quit
            case .startFailed(let reason, _), .health(let reason, _), .boundary(let reason), .sourceLost(let reason, _): return reason
            default: return nil
            }
        }
    }

    public enum Refusal: Equatable, Sendable { case acknowledgmentNeeded, saveFailed }

    public enum Effect: Equatable, Sendable {
        /// Stop both sources and close their rings now, and keep the stretch's end time.
        case stopSources
        /// Save the record as it is, then report `.saved` or `.saveFailed` with this generation. Nothing starts before `.saved`.
        case saveBeforeStart(generation: Int)
        /// Append an open stretch (the record is open again), claim the session and run the stretch task.
        case beginStretch(generation: Int)
        /// Let the stretch task drain both rings, then report `.drained` with this generation.
        case drain(generation: Int)
        /// Cancel the stretch task; once it has cleaned up and released the session, report `.drained` with
        /// this generation. A stretch that never began reports it at once.
        case cancelStretch(generation: Int)
        /// Give the open stretch its end time and its one reason.
        case closeStretch(MeetingStretchEnd)
        /// Remove the open stretch of a start that never delivered audio.
        case removeStretch
        /// Replace the last closed stretch's reason, keeping its end: a rollover whose restart never delivered
        /// audio did not continue.
        case amendLastStretch(MeetingStretchEnd)
        case markFinished
        case saveRecord
        /// Delete the file and any pending write; nothing may resurrect it.
        case deleteRecord
        case requestUnload
        case refused(Refusal)

        /// Effects that suspend the controller. Nothing that awaits runs before `.stopSources`.
        public var awaits: Bool {
            switch self {
            case .saveBeforeStart, .beginStretch, .drain, .cancelStretch, .saveRecord, .deleteRecord, .requestUnload: return true
            case .stopSources, .closeStretch, .removeStretch, .amendLastStretch, .markFinished, .refused: return false
            }
        }
    }

    /// A pause longer than this needs a new acknowledgment: the call it was given for may be over.
    public static let acknowledgmentAfterPause: TimeInterval = 15 * 60
    /// Stretch ends after which the call may have changed.
    public static let acknowledgedEnds: Set<MeetingStretchEnd> = [.callEnded, .lockOrSleep, .userSwitched, .computerAudioLost]

    public private(set) var phase: Phase
    public private(set) var generation = 0
    /// Why the last closed stretch ended.
    public private(set) var lastEnd: MeetingStretchEnd?
    /// Why the last start failed, until the next start.
    public private(set) var startFailure: MeetingStretchEnd?
    /// Whether the record holds a title, notes or words; the controller keeps it current. A new meeting
    /// whose start never delivered audio is deleted only when it holds nothing.
    public var holdsContent = false
    private var origin: Phase = .idle
    /// The start's stretch began: its save succeeded, or it resumed a saved meeting.
    private var stretchBegun = false
    /// The start continues a rollover, so if it never delivers audio the previous stretch did not continue.
    private var rolloverRestart = false
    /// Where an unacknowledged resume that fails leaves the pause clock, so retrying never restarts it.
    private var pauseBeforeStart: Date?
    private var ending: MeetingStretchEnd?
    /// Why a start that never delivered audio stopped; its stretch is removed once the task has ended.
    private var cancelling: MeetingStretchEnd?
    private var pendingFinish = false, continueAfterDrain = false, unloadAfterDrain = false
    private var callMayHaveChanged = false
    private var pausedSince: Date?

    /// A saved meeting starts finished; "Continue this meeting" is a new start on it.
    public init(finished: Bool = false) { phase = finished ? .finished : .idle }

    /// Open meetings block Dictation and Notes, paused ones included.
    public var isOpen: Bool { phase != .idle && phase != .finished }
    public var sourcesOn: Bool { phase == .recording || (phase == .preparing && stretchBegun) }

    public func needsAcknowledgment(at now: Date) -> Bool {
        callMayHaveChanged || pausedSince.map { now.timeIntervalSince($0) > Self.acknowledgmentAfterPause } ?? false
    }

    public mutating func handle(_ event: Event, at now: Date) -> [Effect] {
        if let tagged = event.generation, tagged != generation { return [] }
        switch (phase, event) {
        case (.idle, .start(let acknowledged)), (.finished, .start(let acknowledged)):
            guard acknowledged else { return [.refused(.acknowledgmentNeeded)] }
            return begin(from: phase)
        case (.paused, .resume(let acknowledged)):
            guard acknowledged || !needsAcknowledgment(at: now) else { return [.refused(.acknowledgmentNeeded)] }
            return begin(from: .paused, keepingPauseClock: !acknowledged)

        case (.preparing, .saved) where !stretchBegun:
            stretchBegun = true
            return [.beginStretch(generation: generation)]
        case (.preparing, .saveFailed) where !stretchBegun:
            // Nothing began: a new record was never written, and a continued one is still as saved.
            generation += 1; resetDrain()
            phase = origin == .idle ? .idle : .finished
            return [.stopSources] + (phase == .idle ? [.deleteRecord] : []) + [.refused(.saveFailed)]
        case (.preparing, .sourcesLive) where stretchBegun:
            phase = .recording
            return []
        case (.preparing, .startFailed(let reason, _)) where stretchBegun:
            generation += 1; startFailure = reason
            return [.stopSources] + returnToOrigin(reason, now)
        case (.preparing, .boundary), (.preparing, .callEnded), (.preparing, .pause), (.preparing, .health), (.preparing, .sourceLost):
            noteInterruption(event)
            cancelling = event.reason
            return leaveCapture(to: .pausing, cancel: true)
        case (.preparing, .finish), (.preparing, .quit):
            cancelling = event.reason; pendingFinish = true
            return leaveCapture(to: .finishing, cancel: true)

        case (.recording, .pause): return stop(.pauseButton, now)
        case (.recording, .health(let reason, _)), (.recording, .sourceLost(let reason, _)): return stop(reason, now)
        case (.recording, .callEnded): return stop(.callEnded, now)
        case (.recording, .boundary(let reason)):
            unloadAfterDrain = true
            return stop(reason, now)
        case (.recording, .startFailed(let reason, _)):
            startFailure = reason; cancelling = reason
            return leaveCapture(to: .pausing, cancel: true)
        case (.recording, .rollover):
            continueAfterDrain = true
            return stop(.durationLimit, now)
        case (.recording, .finish), (.recording, .quit):
            ending = event.reason; pendingFinish = true
            return leaveCapture(to: .finishing, cancel: false)

        case (.preparing, .discard), (.recording, .discard):
            return leaveCapture(to: .discarding, cancel: true)
        case (.pausing, .discard), (.finishing, .discard), (.paused, .discard):
            generation += 1; phase = .discarding
            return [.stopSources, .cancelStretch(generation: generation)]

        case (.pausing, .drained), (.finishing, .drained): return completeDrain(now)
        case (.pausing, .finish), (.pausing, .quit):
            if continueAfterDrain { ending = event.reason }
            pendingFinish = true; continueAfterDrain = false
            return []
        case (.pausing, .boundary), (.pausing, .callEnded), (.pausing, .pause):
            noteInterruption(event)
            // A rollover that no longer continues ends for this reason, not at the duration limit.
            if continueAfterDrain { ending = event.reason; continueAfterDrain = false }
            return []
        case (.pausing, .health(.speechError, _)) where cancelling == nil, (.finishing, .health(.speechError, _)) where cancelling == nil:
            // The flush failed, so the last words may be missing; a rollover pauses instead of continuing.
            ending = .speechError; continueAfterDrain = false
            return []
        case (.finishing, .boundary):
            unloadAfterDrain = true
            return []
        case (.pausing, .drainTimedOut) where pendingFinish, (.finishing, .drainTimedOut):
            generation += 1
            if let reason = cancelling { return returnToOrigin(reason, now) }
            lastEnd = .quitBeforeDrain; becomeFinished()
            return [.closeStretch(.quitBeforeDrain), .markFinished, .saveRecord]

        case (.paused, .finish), (.paused, .quit):
            becomeFinished()
            return [.markFinished, .saveRecord]
        case (.paused, .boundary):
            callMayHaveChanged = true
            return [.requestUnload]
        case (.paused, .callEnded):
            callMayHaveChanged = true
            return []

        case (.discarding, .drained):
            phase = .idle; resetDrain(); pausedSince = nil; callMayHaveChanged = false
            return [.deleteRecord]
        default:
            return []
        }
    }

    /// A resumed meeting is already saved; a new or continued one saves before anything starts.
    private mutating func begin(from start: Phase, keepingPauseClock: Bool = false, rollover: Bool = false) -> [Effect] {
        pauseBeforeStart = keepingPauseClock ? pausedSince : nil
        origin = start; phase = .preparing; generation += 1; rolloverRestart = rollover
        resetDrain(); callMayHaveChanged = false; pausedSince = nil; startFailure = nil
        stretchBegun = start == .paused
        return stretchBegun ? [.beginStretch(generation: generation)] : [.saveBeforeStart(generation: generation)]
    }

    /// Bumps the generation before anything awaits, so every callback of the stretch that is ending goes stale.
    private mutating func leaveCapture(to next: Phase, cancel: Bool) -> [Effect] {
        generation += 1; phase = next
        return [.stopSources, cancel ? .cancelStretch(generation: generation) : .drain(generation: generation)]
    }

    private mutating func stop(_ reason: MeetingStretchEnd, _ now: Date) -> [Effect] {
        ending = reason; pausedSince = now
        if Self.acknowledgedEnds.contains(reason) { callMayHaveChanged = true }
        return leaveCapture(to: .pausing, cancel: false)
    }

    /// A boundary or call end while starting or draining: the call may have changed, and a boundary unloads.
    private mutating func noteInterruption(_ event: Event) {
        switch event {
        case .boundary: unloadAfterDrain = true; callMayHaveChanged = true
        case .callEnded: callMayHaveChanged = true
        case .sourceLost(let reason, _) where Self.acknowledgedEnds.contains(reason): callMayHaveChanged = true
        default: break
        }
    }

    private mutating func completeDrain(_ now: Date) -> [Effect] {
        let unload: [Effect] = unloadAfterDrain ? [.requestUnload] : []
        if let reason = cancelling { return returnToOrigin(reason, now) + unload }
        let reason = ending ?? .finished
        lastEnd = reason
        if pendingFinish {
            becomeFinished()
            return [.closeStretch(reason), .markFinished, .saveRecord] + unload
        }
        if continueAfterDrain {
            // The rollover continues the capture the user started: no new acknowledgment.
            return [.closeStretch(reason), .saveRecord] + begin(from: .paused, rollover: true)
        }
        phase = .paused; resetDrain()
        return [.closeStretch(reason), .saveRecord] + unload
    }

    /// A start that never delivered audio leaves no stretch. A new meeting that holds nothing is deleted;
    /// one with a title or notes is kept, finished; a resumed one stays paused.
    private mutating func returnToOrigin(_ reason: MeetingStretchEnd, _ now: Date) -> [Effect] {
        let finish = pendingFinish
        resetDrain()
        if origin == .idle, !holdsContent { phase = .idle; return [.deleteRecord] }
        var effects: [Effect] = stretchBegun ? [.removeStretch] : []
        if rolloverRestart { effects.append(.amendLastStretch(reason)); lastEnd = reason }
        if origin == .paused, !finish {
            phase = .paused; pausedSince = pauseBeforeStart ?? now
            return effects + [.saveRecord]
        }
        becomeFinished()
        return effects + [.markFinished, .saveRecord]
    }

    private mutating func becomeFinished() {
        phase = .finished; resetDrain(); pausedSince = nil; callMayHaveChanged = false
    }

    private mutating func resetDrain() {
        ending = nil; cancelling = nil; pendingFinish = false; continueAfterDrain = false; unloadAfterDrain = false
    }
}

/// Which meeting snapshots may still be written: only a newer revision than the last admitted, and never
/// one for a meeting that was deleted or discarded, so a late checkpoint cannot bring it back.
public struct MeetingCheckpointGate: Sendable {
    private var admitted: [UUID: Int] = [:]
    private var deleted: Set<UUID> = []

    public init() {}

    public mutating func admit(_ id: UUID, revision: Int) -> Bool {
        guard !deleted.contains(id), revision > admitted[id, default: Int.min] else { return false }
        admitted[id] = revision
        return true
    }

    public mutating func delete(_ id: UUID) { deleted.insert(id); admitted[id] = nil }
}
