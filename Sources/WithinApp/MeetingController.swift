import Foundation
import WithinCore

/// What a meeting needs from the app. AppModel adopts it; the developer fixture has its own. Every system
/// read the controller makes goes through here or through its sources.
@MainActor protocol MeetingHost: AnyObject {
    var microphoneUID: String { get }
    /// Read without prompting.
    var microphoneAuthorized: Bool { get }
    /// The current dictionary, applied to saved turns, You and Others alike, whenever a meeting is shown, searched or
    /// exported. Turns are stored exactly as transcribed, and provisional text is always shown raw.
    var dictionaryMatcher: DictionaryMatcher { get }
    var modelManifest: ModelManifest { get }
    func modelDirectory() async -> URL
    /// Nil when a meeting may start; otherwise a sentence naming what holds capture.
    func meetingStartRefusal() -> String?
    func claimCapture() -> UUID?
    func captureRecording(_ id: UUID) -> Bool
    func captureDraining(_ id: UUID)
    func releaseCapture(_ id: UUID) async
    /// Drops the speech models now when idle, or after the session in progress.
    func requestUnload()
    func announce(_ text: String)
    func playCue(start: Bool)
}

/// A meeting's sources: You always, Others when an app's sound is included.
typealias MeetingSourceFactory = @MainActor (_ app: MeetingApp?) -> [MeetingAudioSource]

/// Writes meeting snapshots off the main actor, one at a time and only newer revisions. A deleted meeting's
/// snapshots are dropped, and its file is removed only after every earlier write has landed.
final class MeetingCheckpointWriter: @unchecked Sendable {
    enum Outcome: Equatable { case saved, superseded, failed }
    private let store: MeetingStore
    private let queue = DispatchQueue(label: "com.madeordinary.Within.meeting-checkpoints", qos: .utility)
    /// Touched on `queue` only, so a delete and a late snapshot are decided in the order they were sent.
    private var gate = MeetingCheckpointGate()

    init(store: MeetingStore) { self.store = store }

    func write(_ meeting: Meeting, revision: Int) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.save(meeting, revision)) }
        }
    }

    /// Blocks until written; only for a quit with no time left to drain.
    func writeNow(_ meeting: Meeting, revision: Int) -> Outcome { queue.sync { save(meeting, revision) } }

    /// Whether the file is gone. A removal that fails leaves the meeting writable, as it still exists.
    func delete(_ id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.remove(id)) }
        }
    }

    /// Blocking forms, only for a quit with no time left: a delete, and waiting for everything already sent.
    func deleteNow(_ id: UUID) -> Bool { queue.sync { remove(id) } }
    func flush() { queue.sync {} }

    private func remove(_ id: UUID) -> Bool {
        // Every earlier snapshot has landed and every later one runs after this, so marking after the removal loses nothing.
        guard (try? store.delete(id)) != nil else { return false }
        gate.delete(id)
        return true
    }

    private func save(_ meeting: Meeting, _ revision: Int) -> Outcome {
        guard gate.admit(meeting.id, revision: revision) else { return .superseded }
        do { try store.save(meeting); return .saved } catch { return .failed }
    }
}

/// One meeting's capture, on the main actor. It drives `MeetingLifecycle` and performs its effects in order;
/// effects before the first one that suspends run at once, so the sources always stop before any await. Each
/// stretch runs in one task that prepares, begins both speech sessions, starts the sources, consumes and
/// drains, and releases the session only after its sessions are gone. The in-memory `meeting` is the only
/// truth: the transcript, the stretches and the user's notes are all written from it.
@MainActor final class MeetingController: ObservableObject {
    @Published private(set) var meeting: Meeting?
    @Published private(set) var phase = MeetingLifecycle.Phase.idle
    /// Each source's still-changing tail. Shown after the transcript; never saved.
    @Published private(set) var provisional: [MeetingSource: String] = [:]
    @Published private(set) var sourceStates: [MeetingSource: MeetingSourceState] = [:]
    @Published private(set) var levels: [MeetingSource: Float] = [:]
    /// Meeting-relative seconds: now while capturing, else where the last stretch ended.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Why the last start, resume or capture request was refused; cleared by the next one accepted.
    @Published private(set) var refusal: String?
    /// The last save failed: the meeting is in memory only until Try again or the next checkpoint succeeds.
    @Published private(set) var notSaved = false
    /// A non-blocking notice, such as the rollover past three hours. Kept until the next pause, resume, finish,
    /// discard or start, or `dismissNotice()`.
    @Published private(set) var notice: String?
    /// A discard, or a new meeting that never held anything, couldn't remove its file. The record stays in memory
    /// with the phase idle until Try again removes it, and no other meeting is started or shown meanwhile.
    @Published private(set) var deletionPending = false

    static let notSavedMessage = "Meeting notes couldn't be saved on this Mac. Check free space, then choose Try again."
    static let notDeletedMessage = "This meeting couldn't be deleted from this Mac."
    static let acknowledgmentMessage = "Confirm that everyone in this meeting knows it's being transcribed."
    static let rolloverNotice = "Past three hours, the longest tested length. Notes continue; a few seconds around the change may be missing."
    /// A dirty record is written no later than this, even if nothing else changes.
    static let checkpointDeadline: Duration = .seconds(5)
    static let editDebounce: Duration = .seconds(1)
    static let quitWatchdog: Duration = .seconds(10)

    let preview: Bool
    private(set) var checkpointsWritten = 0
    private(set) var checkpointFailures = 0
    /// Whether the latest stretch's health monitor runs the Others first-audio and stall rules.
    private(set) var othersLivenessRules = false
    private var lifecycle = MeetingLifecycle()
    private let speech: LocalSpeech?
    private weak var host: MeetingHost?
    private let writer: MeetingCheckpointWriter?
    private let makeSources: MeetingSourceFactory
    private var sources: [MeetingAudioSource] = []
    /// The app whose sound the current sources include; it decides the Others liveness rules.
    private var app: MeetingApp?
    private var builder = MeetingTranscriptBuilder()
    private var clock = MeetingClock()
    private let origin = ContinuousClock.now
    private var run: StretchRun?
    private var stretchSerial = 0
    /// Where the open stretch ended, taken when its sources stopped; drained text is clamped to it.
    private var stretchEnd: TimeInterval?
    private var pending: [MeetingLifecycle.Effect] = []
    private var performing = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var revision = 0
    private var dirty = false
    /// Checkpoints written but not yet answered.
    private var saving = 0
    private var deadline: Task<Void, Never>?
    private var editSave: Task<Void, Never>?
    private var previewNeedsAcknowledgment = false
    /// The meeting whose file a delete or discard is removing right now.
    private var deleting: UUID?

    init(speech: LocalSpeech, host: MeetingHost, store: MeetingStore, sources: @escaping MeetingSourceFactory) {
        preview = false
        self.speech = speech; self.host = host; makeSources = sources
        writer = MeetingCheckpointWriter(store: store)
    }

    /// Renders and native checks: no store, no speech, no sources and no system reads. Shows only what
    /// `configurePreview` gives it.
    init(preview: Bool) {
        precondition(preview)
        self.preview = true
        speech = nil; host = nil; writer = nil; makeSources = { _ in [] }
    }

    /// From `phase`, which always mirrors the lifecycle's, so a preview reports what `configurePreview` set.
    var isOpen: Bool { phase != .idle && phase != .finished }
    /// Preparing, capturing or draining; a paused meeting is open but not capturing.
    var isCapturing: Bool { [.preparing, .recording, .pausing, .finishing, .discarding].contains(phase) }
    var needsAcknowledgment: Bool { preview ? previewNeedsAcknowledgment : lifecycle.needsAcknowledgment(at: Date()) }
    var lastEnd: MeetingStretchEnd? { lifecycle.lastEnd }
    var startFailure: MeetingStretchEnd? { lifecycle.startFailure }
    /// What a quit must still write or delete, even with the meeting finished: an edit, a save under way or
    /// failed, a deletion, or an effect not yet performed.
    var hasUnsavedWork: Bool { dirty || saving > 0 || notSaved || deletionPending || performing || !pending.isEmpty }

    // MARK: Requests

    /// A new meeting, saved before anything starts. The acknowledgment is asked for every meeting.
    @discardableResult func start(title: String = "", app: MeetingApp?, acknowledged: Bool) -> Bool {
        guard !preview, let host, !lifecycle.isOpen, quiescent, mayReplaceShown() else { return false }
        if let reason = host.meetingStartRefusal() { refuse(reason); return false }
        guard acknowledged else { refuse(Self.acknowledgmentMessage); return false }
        adopt(Meeting(title: title, created: Date(), appName: app?.name ?? Meeting.microphoneOnly), app: app, finished: false)
        refusal = nil
        return send(.start(acknowledged: true))
    }

    /// A saved meeting, read-only for capture until "Continue this meeting". Never starts anything. The meeting
    /// already shown is kept in memory instead of an older copy of it.
    @discardableResult func show(_ meeting: Meeting) -> Bool {
        guard !lifecycle.isOpen, quiescent else { return false }
        if meeting.id == self.meeting?.id { return true }
        guard mayReplaceShown() else { return false }
        adopt(meeting, app: nil, finished: true)
        return true
    }

    /// "Continue this meeting": a new start on the shown record, with its own acknowledgment.
    @discardableResult func continueMeeting(app: MeetingApp?, acknowledged: Bool) -> Bool {
        guard !preview, let host, lifecycle.phase == .finished, meeting != nil, quiescent else { return false }
        if let reason = host.meetingStartRefusal() { refuse(reason); return false }
        guard acknowledged else { refuse(Self.acknowledgmentMessage); return false }
        self.app = app
        replaceSources(makeSources(app))
        refusal = nil; notice = nil
        return send(.start(acknowledged: true))
    }

    func pause() {
        notice = nil
        send(.pause)
    }

    /// After a call end, lock, sleep, user switch, lost app process or a long pause, this needs a new
    /// acknowledgment. `microphoneOnly` drops the app's sound from this and later stretches.
    @discardableResult func resume(acknowledged: Bool, microphoneOnly: Bool = false) -> Bool {
        guard !preview, let host, lifecycle.phase == .paused else { return false }
        if let reason = host.meetingStartRefusal() { refuse(reason); return false }
        // Refused before anything changes, so a refused microphone-only resume keeps the app's sound.
        guard acknowledged || !lifecycle.needsAcknowledgment(at: Date()) else { refuse(Self.acknowledgmentMessage); return false }
        if microphoneOnly { app = nil; replaceSources(sources.filter { $0.source == .you }) }
        refusal = nil; notice = nil
        return send(.resume(acknowledged: acknowledged))
    }

    func dismissNotice() { notice = nil }

    /// Stops capture, drains and saves. True only once the finished record is on disk (or nothing was kept).
    func finish() async -> Bool { await end(.finish) }

    /// A quit's first step, before anything awaits: both sources stop now. `quit()` then drains and saves.
    func stopForQuit() {
        guard lifecycle.isOpen else { return }
        notice = nil
        send(.quit)
    }

    /// Like Finish, but a drain that stalls is cut off by the watchdog, keeping the text already settled.
    func quit() async -> Bool {
        guard lifecycle.isOpen else {
            // A finish's save, or a deletion, already under way lands first.
            await settled()
            if deletionPending { return await deleteRecord() }
            // A finished meeting can still hold a notes edit inside its debounce, or one still being written.
            return dirty || saving > 0 ? await checkpoint() : !notSaved
        }
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.quitWatchdog)
            guard let self, !Task.isCancelled, let run = self.run, let generation = run.drainGeneration else { return }
            // The quit no longer waits for this stretch: it saves what is already in memory, and nothing later.
            run.abandoned = true; run.dropsWords = true
            self.send(.drainTimedOut(generation: generation))
            run.task?.cancel()
        }
        defer { watchdog.cancel() }
        return await end(.quit)
    }

    /// Stops capture and deletes the meeting and anything still being written. False when the file couldn't be
    /// removed; the meeting then stays in memory with `deletionPending` until Try again.
    @discardableResult func discard() async -> Bool {
        guard lifecycle.isOpen else { return false }
        notice = nil
        send(.discard)
        await settled()
        guard meeting == nil else { return false }
        host?.announce("Meeting discarded. Microphone off.")
        return true
    }

    /// Deletes the shown finished meeting. Refused while it is open.
    func delete() async -> Bool {
        guard !preview, !lifecycle.isOpen, let writer, let id = meeting?.id else { return false }
        let unsaved = dirty
        cancelSaves()
        deleting = id
        let deleted = await writer.delete(id)
        if deleting == id { deleting = nil }
        guard deleted else {
            guard meeting?.id == id else { return false }
            // Still on disk and shown, so a pending edit is still saved.
            if unsaved { markDirty() }
            refuse(Self.notDeletedMessage)
            return false
        }
        if meeting?.id == id { adopt(nil) }
        host?.announce("Meeting deleted")
        return true
    }

    /// Lock, sleep or a user switch.
    func boundary(_ reason: MeetingStretchEnd) {
        guard reason == .lockOrSleep || reason == .userSwitched else { return }
        send(.boundary(reason))
    }

    func callEnded() { send(.callEnded) }

    /// The capture engine's input changed while You was live. No automatic device switch.
    func microphoneChanged() {
        guard let run, run.live, !run.stopped, sources.contains(where: { $0.source == .you }) else { return }
        sourceStates[.you] = .lost
        send(.sourceLost(.microphoneLost, generation: run.beginGeneration))
    }

    func setTitle(_ title: String) {
        guard meeting != nil, meeting?.title != title else { return }
        meeting?.title = title
        edited()
    }

    func setNotes(_ notes: String) {
        guard meeting != nil, meeting?.notes != notes else { return }
        meeting?.notes = notes
        edited()
    }

    /// "Try again" after a failed save, or after a discard that couldn't remove its file.
    @discardableResult func tryAgain() async -> Bool {
        guard deletionPending else { return await checkpoint() }
        guard await deleteRecord() else { return false }
        host?.announce("Meeting deleted")
        return true
    }

    /// The shutdown fallback when there is no time to drain: sources off now, the open stretch closed with the
    /// text already in memory, and a blocking save. What a discard or a failed start would delete is deleted
    /// instead, and a stretch that never delivered audio is removed. Returns once every write has landed.
    @discardableResult func emergencyStop() -> Bool {
        guard let writer else { return !notSaved }
        let open = lifecycle.isOpen
        // Also a delete under way, which may not have reached the writer yet.
        let discarded = deletionPending || (deleting != nil && deleting == meeting?.id) || phase == .discarding || pending.contains(.deleteRecord)
        if open {
            let kept = run.map { $0.live && !$0.dropsWords } ?? false
            stopSources()
            run?.abandoned = true; run?.dropsWords = true
            run?.task?.cancel()
            if !discarded, let index = meeting?.stretches.indices.last, meeting?.stretches[index].end == nil {
                if kept { closeStretch(.quitBeforeDrain) } else { meeting?.stretches.removeLast() }
            }
            meeting?.state = .finished
        }
        guard let snapshot = meeting else { writer.flush(); return true }
        if discarded || (open && !holdsContent && snapshot.stretches.isEmpty) { return writer.deleteNow(snapshot.id) }
        guard open || dirty || notSaved else { writer.flush(); return true }
        revision += 1
        return writer.writeNow(snapshot, revision: revision) == .saved
    }

    /// Previews only: a synthetic meeting shown in a phase. Nothing is written or started.
    func configurePreview(_ meeting: Meeting?, phase: MeetingLifecycle.Phase, provisional: [MeetingSource: String] = [:],
                          sourceStates: [MeetingSource: MeetingSourceState] = [:], elapsed: TimeInterval = 0, needsAcknowledgment: Bool = false) {
        guard preview else { return }
        self.meeting = meeting; self.phase = phase; self.provisional = provisional
        self.sourceStates = sourceStates; self.elapsed = elapsed; previewNeedsAcknowledgment = needsAcknowledgment
    }

    // MARK: Lifecycle

    /// Nothing pending, no effect running and no stretch task, so every effect has acted on the meeting that
    /// produced it and no late event can reach a fresh lifecycle.
    private var quiescent: Bool { !performing && pending.isEmpty && run == nil }

    /// The shown record is replaced only when it isn't held in memory alone: a failed save or a failed
    /// deletion keeps it until Try again.
    private func mayReplaceShown() -> Bool {
        if deletionPending { refuse(Self.notDeletedMessage); return false }
        if notSaved { refuse(Self.notSavedMessage); return false }
        return true
    }

    /// Shows `meeting` with a fresh lifecycle. An unsaved edit of the meeting shown before is written first.
    private func adopt(_ meeting: Meeting?, app: MeetingApp? = nil, finished: Bool = true) {
        if dirty, let writer, let previous = self.meeting {
            revision += 1
            let revision = revision
            Task { _ = await writer.write(previous, revision: revision) }
        }
        cancelSaves()
        self.meeting = meeting
        lifecycle = MeetingLifecycle(finished: finished && meeting != nil)
        lifecycle.holdsContent = holdsContent
        phase = lifecycle.phase
        builder = MeetingTranscriptBuilder(segments: meeting?.segments ?? [])
        clock = MeetingClock()
        notSaved = false; deletionPending = false; notice = nil; provisional = [:]; levels = [:]
        elapsed = meeting?.stretches.last.map { $0.end ?? $0.lastCheckpoint } ?? 0
        self.app = finished ? nil : app
        replaceSources(finished ? [] : makeSources(app))
    }

    private func replaceSources(_ next: [MeetingAudioSource]) {
        for source in sources where !next.contains(where: { $0 === source }) { source.stop() }
        sources = next
        for source in sources {
            let kind = source.source
            source.onLost = { [weak self] reason, generation in
                guard let self, self.run?.beginGeneration == generation else { return }
                self.sourceStates[kind] = .lost
                self.send(.sourceLost(reason, generation: generation))
            }
        }
        sourceStates = Dictionary(uniqueKeysWithValues: sources.map { ($0.source, .off) })
    }

    /// Reduces the event and performs its effects. Returns false when it was refused. A preview keeps the phase
    /// `configurePreview` gave it.
    @discardableResult private func send(_ event: MeetingLifecycle.Event) -> Bool {
        guard !preview else { return false }
        let effects = lifecycle.handle(event, at: Date())
        phase = lifecycle.phase
        let refused = effects.contains { if case .refused = $0 { return true }; return false }
        // Effects before the first that suspends run now, so stopping the sources never waits behind a save.
        let leading = effects.prefix { !$0.awaits }
        leading.forEach(perform)
        // The stretch learns its drain's generation now, so a speech error it reports before the drain is performed isn't stale.
        for effect in effects {
            switch effect {
            case .drain(let generation), .cancelStretch(let generation): run?.requestDrain(generation)
            default: break
            }
        }
        pending += effects.dropFirst(leading.count)
        pump()
        return !refused
    }

    private func pump() {
        guard !performing, !pending.isEmpty else { wakeIfSettled(); return }
        performing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                let effect = self.pending.removeFirst()
                if effect.awaits { await self.performAwaiting(effect) } else { self.perform(effect) }
            }
            self.performing = false
            self.wakeIfSettled()
        }
    }

    private func perform(_ effect: MeetingLifecycle.Effect) {
        switch effect {
        case .stopSources: stopSources()
        case .closeStretch(let reason): closeStretch(reason)
        case .removeStretch:
            guard meeting?.stretches.last.map({ $0.end == nil }) == true else { return }
            meeting?.stretches.removeLast(); stretchEnd = nil
            changed()
        case .amendLastStretch(let reason):
            guard let index = meeting?.stretches.indices.last, meeting?.stretches[index].end != nil else { return }
            meeting?.stretches[index].ended = reason
            changed()
        case .markFinished:
            meeting?.state = .finished
            provisional = [:]
            changed()
            if let speech { Task { await speech.releaseDedicatedModels() } }
        case .refused(.acknowledgmentNeeded): refuse(Self.acknowledgmentMessage)
        case .refused(.saveFailed): refusal = Self.notSavedMessage  // Already announced by the failed save.
        default: break
        }
    }

    private func performAwaiting(_ effect: MeetingLifecycle.Effect) async {
        switch effect {
        case .saveBeforeStart(let generation):
            guard generation == lifecycle.generation else { return }
            let saved = await checkpoint()
            send(saved ? .saved(generation: generation) : .saveFailed(generation: generation))
        case .beginStretch(let generation):
            guard generation == lifecycle.generation else { return }
            beginStretch(generation)
        case .drain(let generation), .cancelStretch(let generation):
            guard generation == lifecycle.generation else { return }
            // A stretch that never began, or already ended, has nothing to drain.
            guard let run else { send(.drained(generation: generation)); return }
            run.requestDrain(generation)
            // A cancelled stretch never gains another turn.
            if case .cancelStretch = effect { run.dropsWords = true; run.task?.cancel() }
        case .saveRecord: await checkpoint()
        case .deleteRecord: await deleteRecord()
        case .requestUnload: host?.requestUnload()
        default: perform(effect)
        }
    }

    private func end(_ event: MeetingLifecycle.Event) async -> Bool {
        notice = nil
        send(event)
        await settled()
        return !notSaved && (lifecycle.phase == .finished || (lifecycle.phase == .idle && meeting == nil))
    }

    /// Until no effect is pending, no stretch task runs, and the meeting rests in a phase.
    private func settled() async {
        while !isSettled { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    private var isSettled: Bool {
        !performing && pending.isEmpty && (run?.abandoned ?? true) && [.idle, .recording, .paused, .finished].contains(lifecycle.phase)
    }

    private func wakeIfSettled() {
        guard isSettled, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func refuse(_ reason: String) {
        refusal = reason
        host?.announce(reason)
    }

    // MARK: Stretches

    private func beginStretch(_ generation: Int) {
        guard let host, var meeting else { send(.startFailed(.speechError, generation: generation)); return }
        let start = clock.startStretch(of: meeting, monotonic: monotonic(), now: Date())
        meeting.stretches.append(MeetingStretch(start: start, sources: sources.map(\.source)))
        meeting.state = .open
        self.meeting = meeting
        builder.markGap()
        // A rollover's notice stays up through its restart.
        stretchEnd = nil
        changed()
        guard let session = host.claimCapture() else { send(.startFailed(.speechError, generation: generation)); return }
        stretchSerial += 1
        let run = StretchRun(serial: stretchSerial, generation: generation, session: session, segmentsAtStart: builder.segments.count)
        self.run = run
        run.task = Task { @MainActor [weak self] in await self?.runStretch(run) }
    }

    private func runStretch(_ run: StretchRun) async {
        guard let speech, let host else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Meeting notes are on")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var failure: MeetingStretchEnd? = .speechError
        do {
            try await speech.prepare(directory: await host.modelDirectory(), manifest: host.modelManifest)
            try current(run)
            try await speech.beginStream(MeetingSource.you.rawValue)
            try current(run)
            if sources.contains(where: { $0.source == .others }) {
                try await speech.beginStream(MeetingSource.others.rawValue, dedicatedModels: true)
                try current(run)
            }
            for source in sources {
                failure = source.source == .you ? .microphoneLost : .computerAudioLost
                run.rings[source.source] = (try source.start(limits: .meeting, generation: run.beginGeneration), source.sampleRate)
            }
            failure = .speechError
            // Only something outside the meeting ends its session here, so this start fails rather than waiting.
            guard host.captureRecording(run.session) else { throw StretchFailure.sessionLost }
            failure = nil
            run.live = true; run.liveAt = monotonic()
            // The stretch starts when audio does, so a gap marker includes the time speech took to get ready.
            if let index = meeting?.stretches.indices.last, let stretch = meeting?.stretches[index], stretch.end == nil,
               let live = clock.offset(at: run.liveAt) {
                meeting?.stretches[index] = MeetingStretch(id: stretch.id, start: max(stretch.start, live), sources: stretch.sources)
            }
            for source in sources { sourceStates[source.source] = .live }
            send(.sourcesLive(generation: run.beginGeneration))
            host.playCue(start: true)
            host.announce(sources.count > 1 ? "Meeting notes are on. Transcribing your microphone and the meeting app" : "Meeting notes are on. Transcribing your microphone")
            startPulse(run)
            await consume(run)
        } catch {
            stopSources()
            if case CaptureFailure.permission? = error as? CaptureFailure { failure = .microphonePermission }
            if error is CancellationError { failure = nil }
        }
        run.pulse?.cancel()
        // Every named session is gone before the session is released, so the next prepare never finds one live.
        await speech.cancelStreams()
        await host.releaseCapture(run.session)
        if run.drainGeneration == nil, let failure, lifecycle.generation == run.beginGeneration {
            if self.run === run { self.run = nil }
            send(.startFailed(failure, generation: run.beginGeneration))
        } else {
            // A drain or cancel was asked for, or is on its way from an event already reduced. A later one may have
            // come in before this task resumed, so the newest is reported, never one already stale.
            let requested = await run.drainRequested()
            let generation = run.drainGeneration ?? requested
            if self.run === run { self.run = nil }
            send(.drained(generation: generation))
        }
        wakeIfSettled()
    }

    /// Throws when the stretch was cancelled or superseded while it was starting.
    private func current(_ run: StretchRun) throws {
        try Task.checkCancellation()
        guard self.run === run, lifecycle.generation == run.beginGeneration else { throw CancellationError() }
    }

    /// Both sources' updates and final results arrive through one stream, applied here in the order produced.
    private func consume(_ run: StretchRun) async {
        guard let speech else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: StretchUpdate.self)
        let serial = run.serial
        let sequence = SequenceCounter()
        let inputs = run.rings.map { (source: $0.key, ring: $0.value.ring, rate: $0.value.rate) }
        run.filter.begin(stretch: serial)
        async let consumed: Void = withTaskGroup(of: Void.self) { group in
            for input in inputs {
                group.addTask {
                    let result = await speech.consumeStream(input.source.rawValue, ring: input.ring, sampleRate: input.rate) { update in
                        continuation.yield(StretchUpdate(serial: serial, source: input.source, sequence: sequence.next(), kind: .update(update)))
                    }
                    continuation.yield(StretchUpdate(serial: serial, source: input.source, sequence: sequence.next(), kind: .final(result)))
                }
            }
            await group.waitForAll()
            continuation.finish()
        }
        for await update in stream { apply(update, run) }
        await consumed
        // The rings closed by themselves (overflow, the sample limit, or a speech error): wait for the pause they cause.
        _ = await run.drainRequested()
    }

    private func apply(_ update: StretchUpdate, _ run: StretchRun) {
        guard self.run === run, !run.dropsWords, run.filter.admit(stretch: update.serial, source: update.source, sequence: update.sequence, final: update.isFinal) else { return }
        let source = update.source
        let now = monotonic() - run.liveAt
        switch update.kind {
        case .update(let words):
            run.settles[source, default: MeetingSettle()].observe(confirmed: words.confirmed, volatile: words.volatile,
                                                                 appendedSeconds: words.appendedSeconds, at: now)
            run.volatile[source] = words.volatile
            feedSettled(source, run, now: now)
        case .final(let result) where result.flushed:
            // After the flush everything is final, but an empty flush never withdraws words already shown.
            if !result.text.isEmpty { feed(source, result.text, run) }
            // The pulse never feeds this source's older settled text after its final.
            run.settles[source] = nil
            provisional[source] = nil
        case .final(let result):
            // Without a flush, only confirmed and already-settled words are kept; the unsettled tail is dropped.
            run.settles[source, default: MeetingSettle()].observe(confirmed: result.confirmed, volatile: result.volatile, appendedSeconds: 0, at: now)
            feed(source, run.settles[source, default: MeetingSettle()].feed(at: now), run)
            run.settles[source] = nil
            provisional[source] = nil
            if let failure = result.failure, !(failure is CancellationError) {
                // Both rings close and the sibling drains normally; its session is never cancelled.
                send(.health(.speechError, generation: run.drainGeneration ?? run.beginGeneration))
            }
        }
    }

    private func feedSettled(_ source: MeetingSource, _ run: StretchRun, now: TimeInterval) {
        guard run.settles[source] != nil else { return }
        let text = run.settles[source, default: MeetingSettle()].feed(at: now)
        feed(source, text, run)
        let settled = run.settles[source]?.isSettled(at: now) ?? false
        provisional[source] = settled ? nil : run.volatile[source].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func feed(_ source: MeetingSource, _ text: String, _ run: StretchRun) {
        guard text != run.fed[source, default: ""] else { return }
        run.fed[source] = text
        let offset = MeetingClock.textOffset(clock.offset(at: monotonic()) ?? 0, stretchEnd: stretchEnd, lastSegment: builder.segments.last?.offset)
        builder.update(source, transcript: text, at: offset)
        guard meeting?.segments != builder.segments else { return }
        meeting?.segments = builder.segments
        changed()
    }

    /// Every 100 ms while recording: levels, elapsed time, settling without new audio, and the health rules.
    private func startPulse(_ run: StretchRun) {
        let othersDeliversSilence = MeetingHealthMonitor.deliversSilence(for: app)
        othersLivenessRules = othersDeliversSilence
        run.pulse = Task { @MainActor [weak self] in
            var monitor = MeetingHealthMonitor(othersDeliversSilence: othersDeliversSilence)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.run === run, !run.stopped, self.lifecycle.phase == .recording, let host = self.host else { return }
                let now = self.monotonic()
                let readings = run.rings.mapValues { MeetingRingReading(samplesCaptured: $0.ring.samplesCaptured, status: $0.ring.status, level: $0.ring.level) }
                for (source, reading) in readings {
                    self.levels[source] = min(1, reading.level * 7)
                    self.feedSettled(source, run, now: now - run.liveAt)
                }
                self.elapsed = self.clock.offset(at: now) ?? self.elapsed
                let verdicts = monitor.poll(elapsed: now - run.liveAt, you: readings[.you] ?? MeetingRingReading(samplesCaptured: 0),
                                            others: readings[.others], microphoneAuthorized: host.microphoneAuthorized)
                for verdict in verdicts {
                    switch verdict {
                    case .startFailed(let reason):
                        // The other source already gave words: keep the stretch and pause instead of removing it.
                        let worded = self.builder.segments.count > run.segmentsAtStart
                        // A stretch about to be removed must never gain a turn.
                        if !worded { run.dropsWords = true }
                        self.send(worded ? .health(reason, generation: run.beginGeneration) : .startFailed(reason, generation: run.beginGeneration))
                        return
                    case .pause(let reason):
                        self.send(.health(reason, generation: run.beginGeneration)); return
                    case .rollover:
                        self.send(.rollover(generation: run.beginGeneration)); return
                    case .quiet(let source):
                        self.sourceStates[source] = .quiet
                    case .heard(let source):
                        self.sourceStates[source] = .live
                    }
                }
            }
        }
    }

    private func stopSources() {
        for source in sources { source.stop() }
        sourceStates = sourceStates.mapValues { $0 == .lost ? .lost : .off }
        levels = [:]
        guard let run, !run.stopped else { return }
        run.stopped = true
        run.pulse?.cancel()
        if stretchEnd == nil { stretchEnd = clock.offset(at: monotonic()) }
        if run.live { host?.captureDraining(run.session) }
    }

    private func closeStretch(_ reason: MeetingStretchEnd) {
        guard let index = meeting?.stretches.indices.last, let stretch = meeting?.stretches[index], stretch.end == nil else { return }
        let end = max(stretchEnd ?? clock.offset(at: monotonic()) ?? stretch.lastCheckpoint, stretch.start)
        meeting?.stretches[index].end = end
        meeting?.stretches[index].ended = reason
        meeting?.stretches[index].lastCheckpoint = end
        stretchEnd = nil
        elapsed = end
        changed()
        switch reason {
        case .durationLimit:
            notice = Self.rolloverNotice
            host?.announce(Self.rolloverNotice)
        case .finished, .quit, .quitBeforeDrain: host?.announce("Meeting notes finished. Microphone off.")
        case .lockOrSleep, .userSwitched: break  // Announced after unlock, not while the screen locks.
        case .pauseButton: host?.announce("Meeting notes paused. Microphone off.")
        default:
            let detail = MeetingGap(start: end, end: end, reason: reason).detail(appName: meeting?.appName ?? "") ?? ""
            host?.announce("Meeting notes paused: \(detail). Microphone off.")
        }
    }

    // MARK: Saving

    /// The record changed: it is written by the deadline even if nothing else happens.
    private func changed() {
        guard meeting != nil else { return }
        meeting?.modified = Date()
        lifecycle.holdsContent = holdsContent
        markDirty()
    }

    private func markDirty() {
        guard writer != nil else { return }
        dirty = true
        guard deadline == nil else { return }
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.checkpointDeadline)
            guard let self, !Task.isCancelled else { return }
            self.deadline = nil
            if self.dirty { await self.checkpoint() }
        }
    }

    private func edited() {
        changed()
        editSave?.cancel()
        editSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.editDebounce)
            guard let self, !Task.isCancelled else { return }
            await self.checkpoint()
        }
    }

    private var holdsContent: Bool {
        guard let meeting else { return false }
        return !meeting.segments.isEmpty || !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes the record as it is now, with the open stretch's checkpoint time. Returns whether it is on disk.
    @discardableResult private func checkpoint() async -> Bool {
        guard let writer, let id = meeting?.id else { return !notSaved }
        deadline?.cancel(); deadline = nil; dirty = false
        if let index = meeting?.stretches.indices.last, let stretch = meeting?.stretches[index], stretch.end == nil,
           let now = clock.offset(at: monotonic()) {
            meeting?.stretches[index].lastCheckpoint = max(stretch.lastCheckpoint, min(now, stretchEnd ?? now))
        }
        guard let snapshot = meeting else { return !notSaved }
        revision += 1
        saving += 1
        let outcome = await writer.write(snapshot, revision: revision)
        saving -= 1
        guard meeting?.id == id else { return outcome == .saved }
        switch outcome {
        case .saved:
            checkpointsWritten += 1
            notSaved = false
        case .failed:
            checkpointFailures += 1
            if !notSaved { host?.announce(Self.notSavedMessage) }
            notSaved = true
            // Capture continues and the next deadline tries again.
            changed()
        case .superseded: break
        }
        return outcome == .saved
    }

    private func cancelSaves() {
        deadline?.cancel(); deadline = nil
        editSave?.cancel(); editSave = nil
        dirty = false
    }

    /// Discard, or a new meeting that never held anything: nothing pending may bring it back, and no model copy
    /// stays loaded for it. Returns whether the file is gone; if not, the record stays with `deletionPending`.
    @discardableResult private func deleteRecord() async -> Bool {
        cancelSaves()
        guard let id = meeting?.id else {
            meeting = nil
            await speech?.releaseDedicatedModels()
            return true
        }
        deleting = id
        let deleted = await writer?.delete(id) ?? true
        if deleting == id { deleting = nil }
        await speech?.releaseDedicatedModels()
        guard deleted else {
            if meeting?.id == id { deletionPending = true; refuse(Self.notDeletedMessage) }
            return false
        }
        if meeting?.id == id {
            meeting = nil
            builder = MeetingTranscriptBuilder()
            notSaved = false; deletionPending = false; provisional = [:]
        }
        return true
    }

    private func monotonic() -> TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

/// One stretch's task and the generations it reports with: `sourcesLive` and `startFailed` with the one
/// it began with, `drained` and a speech error during the drain with the drain's.
@MainActor private final class StretchRun {
    let serial: Int
    let beginGeneration: Int
    let session: UUID
    let segmentsAtStart: Int
    var task: Task<Void, Never>?
    var pulse: Task<Void, Never>?
    var rings: [MeetingSource: (ring: AudioRing, rate: Double)] = [:]
    var live = false, stopped = false
    /// No more of its words are kept: its start failed after going live (the stretch is removed), it was
    /// cancelled, or the quit stopped waiting for it.
    var dropsWords = false
    /// The quit watchdog gave up on its drain.
    var abandoned = false
    var liveAt: TimeInterval = 0
    var filter = MeetingUpdateFilter()
    var settles: [MeetingSource: MeetingSettle] = [:]
    var volatile: [MeetingSource: String] = [:]
    var fed: [MeetingSource: String] = [:]
    private(set) var drainGeneration: Int?
    private var drainWaiters: [CheckedContinuation<Int, Never>] = []

    init(serial: Int, generation: Int, session: UUID, segmentsAtStart: Int) {
        self.serial = serial; beginGeneration = generation; self.session = session; self.segmentsAtStart = segmentsAtStart
    }

    func requestDrain(_ generation: Int) {
        drainGeneration = generation
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume(returning: generation) }
    }

    func drainRequested() async -> Int {
        if let drainGeneration { return drainGeneration }
        return await withCheckedContinuation { drainWaiters.append($0) }
    }
}

private enum StretchFailure: Error { case sessionLost }

private struct StretchUpdate: Sendable {
    enum Kind: Sendable { case update(NamedStreamUpdate), final(NamedStreamResult) }
    let serial: Int
    let source: MeetingSource
    let sequence: Int
    let kind: Kind
    var isFinal: Bool { if case .final = kind { return true }; return false }
}

private final class SequenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
