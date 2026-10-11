import AVFoundation
import FluidAudio
import WithinCore

/// The only owner of model residency and serial inference. No capture APIs here.
actor LocalSpeech {
    private var models: AsrModels?
    private var loadedDirectory: URL?
    private var stream: SlidingWindowAsrManager?
    /// Named sessions for longer modes (a meeting's "you" and "others"). Dictation uses `stream` only.
    private var namedStreams: [String: SlidingWindowAsrManager] = [:]
    /// The second model copy a meeting's "others" session uses, kept between stretches so Resume doesn't
    /// reload it. Dropped whenever `models` is cleared or reloaded, and when the meeting finishes or is deleted.
    private var dedicatedModels: AsrModels?
    private(set) var dedicatedModelLoads = 0
    var dedicatedModelsResident: Bool { dedicatedModels != nil }
    /// Bumped by `cancelStreams()` and `unload()`, so a named session still starting is never installed after them.
    private var streamGeneration = 0
    /// Named sessions share one set of loaded models. Running two sessions' windows at the
    /// same moment lost most of one transcript in the Sep 27 fixture, so model work takes turns.
    private var modelWorkBusy = false
    private var modelWorkWaiters: [CheckedContinuation<Void, Never>] = []
    private var verification = ModelVerificationCache()
    private var loadedManifest: ModelManifest?
    private var verificationTask: Task<Void, Never>?
    private var startingSession = false
    private var integrityFailureHandler: (@Sendable () async -> Void)?

    init() { ModelHub.offlineMode = true }

    func setIntegrityFailureHandler(_ handler: @escaping @Sendable () async -> Void) {
        integrityFailureHandler = handler
    }

    func prepare(directory: URL, manifest: ModelManifest) async throws {
        guard stream == nil, namedStreams.isEmpty, !startingSession else { throw SpeechFailure.busy }
        do {
            try verification.verify(manifest, at: directory, force: models == nil)
            if models == nil || loadedDirectory != directory || loadedManifest != manifest {
                try Task.checkCancellation()
                dedicatedModels = nil
                models = try AsrModels.loadLocal(from: directory, version: .v3, encoderPrecision: .int8V2)
                loadedDirectory = directory; loadedManifest = manifest
            }
            try Task.checkCancellation()
            scheduleVerification()
        } catch {
            verification.invalidate(); models = nil; dedicatedModels = nil; loadedDirectory = nil; loadedManifest = nil
            verificationTask?.cancel(); verificationTask = nil
            throw error
        }
    }

    private func scheduleVerification() {
        guard verificationTask == nil else { return }
        verificationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: ModelVerificationCache.maximumAge) } catch { return }
                guard let self else { return }
                await self.reverifyIfIdle()
            }
        }
    }
    private func reverifyIfIdle() async {
        guard stream == nil, namedStreams.isEmpty, !startingSession, models != nil,
              let directory = loadedDirectory, let manifest = loadedManifest else { return }
        do { try verification.verify(manifest, at: directory, force: true) }
        catch {
            guard !Task.isCancelled else { return }
            verification.invalidate(); models = nil; dedicatedModels = nil; loadedDirectory = nil; loadedManifest = nil
            verificationTask?.cancel(); verificationTask = nil
            await integrityFailureHandler?()
        }
    }

    /// Dictation and Notes use the proven 11 s window. Smaller windows showed text sooner in a
    /// fixture comparison but left boundary fragments in the final text (Sep 27), so they are benchmark-only.
    func begin(config: SlidingWindowAsrConfig = .default) async throws {
        guard let models else { throw SpeechFailure.notReady }
        guard stream == nil, namedStreams.isEmpty, !startingSession else { throw SpeechFailure.busy }
        startingSession = true
        defer { startingSession = false }
        let next = SlidingWindowAsrManager(config: config)
        try await next.loadModels(models)
        try await next.withinBegin()
        stream = next
    }

    /// `onUpdate` receives confirmed and still-changing text at most every `updateInterval`.
    /// Dictation passes nil: no partial text leaves this actor before Stop.
    func consume(_ ring: AudioRing, sampleRate: Double, updateInterval: Duration = .milliseconds(500),
                 onUpdate: (@Sendable (_ confirmed: String, _ volatile: String) -> Void)? = nil) async throws -> String {
        guard let stream else { throw SpeechFailure.notReady }
        let clock = ContinuousClock()
        var lastUpdate = clock.now
        let converter = AudioConverter()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { throw SpeechFailure.format }
        do {
            while ring.status == 0 || ring.pending > 0 {
                try Task.checkCancellation()
                let samples = ring.drain(upTo: max(1, Int(sampleRate / 10)))
                if samples.isEmpty { try await Task.sleep(for: .milliseconds(15)); continue }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw SpeechFailure.format }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { input in
                    buffer.floatChannelData![0].update(from: input.baseAddress!, count: samples.count)
                }
                let resampled = try converter.resampleBuffer(buffer)
                // At most one 0.1 second buffer is in flight. A slow engine fills the
                // fixed ring and causes a visible stop; no unbounded SDK stream is used.
                try await stream.withinAppendSamples(resampled)
                if let onUpdate, lastUpdate.duration(to: clock.now) >= updateInterval {
                    lastUpdate = clock.now
                    onUpdate(await stream.confirmedTranscript, await stream.volatileTranscript)
                }
            }
            let text = try await stream.withinFinish()
            await stream.cleanup()
            self.stream = nil
            try Task.checkCancellation()
            return ring.meanEnergy < 0.0000002 ? "" : TranscriptFormatting.clean(text)
        } catch {
            let canceled = error is CancellationError || Task.isCancelled
            let confirmed = await stream.confirmedTranscript
            let volatile = await stream.volatileTranscript
            let partial = canceled ? "" : TranscriptFormatting.clean([confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " "))
            await stream.cleanup()
            self.stream = nil
            if !partial.isEmpty { throw SpeechFailure.partial(partial) }
            throw error
        }
    }

    func cancel() async {
        await stream?.cleanup()
        stream = nil
    }

    // MARK: Named sessions (meetings). Same bounded serial ingress as `consume`, kept separate
    // so the dictation path above is unchanged.

    /// `dedicatedModels` uses a second copy from the same verified directory: two sessions sharing
    /// one model instance lost words in the Sep 27 two-stream fixture. The copy is loaded once and kept
    /// between stretches. A session that `cancelStreams()` or `unload()` overtook is never installed.
    func beginStream(_ key: String, dedicatedModels dedicated: Bool = false) async throws {
        guard let models, let directory = loadedDirectory else { throw SpeechFailure.notReady }
        guard stream == nil, namedStreams[key] == nil, !startingSession else { throw SpeechFailure.busy }
        startingSession = true
        defer { startingSession = false }
        let generation = streamGeneration
        var sessionModels = models
        if dedicated {
            let copy = try dedicatedModels ?? AsrModels.loadLocal(from: directory, version: .v3, encoderPrecision: .int8V2)
            if dedicatedModels == nil { dedicatedModels = copy; dedicatedModelLoads += 1 }
            sessionModels = copy
        }
        let next = SlidingWindowAsrManager(config: .default)
        do {
            try await next.loadModels(sessionModels)
            try stillStarting(generation)
            try await next.withinBegin()
            try stillStarting(generation)
        } catch {
            await next.cleanup()
            throw error
        }
        namedStreams[key] = next
    }

    private func stillStarting(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == streamGeneration else { throw CancellationError() }
    }

    /// Never throws and never drops words silently. Once the flush has returned, the text is `flushed` even
    /// if the task was cancelled meanwhile. Before that, a cancellation or speech error returns the confirmed
    /// and still-changing parts separately with the failure, and the meeting decides what it may keep.
    /// `onUpdate` also carries the seconds of audio appended since the previous update.
    func consumeStream(_ key: String, ring: AudioRing, sampleRate: Double, updateInterval: Duration = .milliseconds(500),
                       onUpdate: (@Sendable (NamedStreamUpdate) -> Void)? = nil) async -> NamedStreamResult {
        guard let named = namedStreams[key] else { return NamedStreamResult(failure: SpeechFailure.notReady) }
        let converter = AudioConverter()
        let clock = ContinuousClock()
        var lastUpdate = clock.now
        var appended = 0.0
        func reportIfDue() async {
            guard let onUpdate, lastUpdate.duration(to: clock.now) >= updateInterval else { return }
            lastUpdate = clock.now
            onUpdate(NamedStreamUpdate(confirmed: await named.confirmedTranscript, volatile: await named.volatileTranscript, appendedSeconds: appended))
            appended = 0
        }
        do {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { throw SpeechFailure.format }
            while ring.status == 0 || ring.pending > 0 {
                try Task.checkCancellation()
                let samples = ring.drain(upTo: max(1, Int(sampleRate / 10)))
                if samples.isEmpty {
                    // A source may send nothing in silence, so audio appended since the last report is still reported.
                    if appended > 0 { await reportIfDue() }
                    try await Task.sleep(for: .milliseconds(15)); continue
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw SpeechFailure.format }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { input in
                    buffer.floatChannelData![0].update(from: input.baseAddress!, count: samples.count)
                }
                let resampled = try converter.resampleBuffer(buffer)
                try await takingTurns { try await named.withinAppendSamples(resampled) }
                appended += Double(samples.count) / sampleRate
                await reportIfDue()
            }
            _ = try await takingTurns { try await named.withinFinish() }
        } catch {
            let partial = NamedStreamResult(confirmed: await named.confirmedTranscript, volatile: await named.volatileTranscript, failure: error)
            await end(key, named)
            return partial
        }
        // The construction every live update used, not the flush's re-decoded text, which can differ in spacing.
        // No whole-ring energy test: one quiet or brief turn in a long stretch is still speech the meeting has shown.
        let result = NamedStreamResult(confirmed: await named.confirmedTranscript, volatile: await named.volatileTranscript, flushed: true)
        await end(key, named)
        return result
    }

    /// Clears the key only while it still holds this session, so a stretch that ended late never removes the next one.
    private func end(_ key: String, _ named: SlidingWindowAsrManager) async {
        await named.cleanup()
        if namedStreams[key] === named { namedStreams[key] = nil }
    }

    private func takingTurns<T>(_ work: () async throws -> T) async throws -> T {
        if modelWorkBusy { await withCheckedContinuation { modelWorkWaiters.append($0) } } else { modelWorkBusy = true }
        defer { if modelWorkWaiters.isEmpty { modelWorkBusy = false } else { modelWorkWaiters.removeFirst().resume() } }
        return try await work()
    }

    func cancelStream(_ key: String) async {
        guard let named = namedStreams[key] else { return }
        await end(key, named)
    }
    /// Every named session, including one still starting. A meeting's stretch calls it after its consumers
    /// return or when its start fails; `cancel()` covers only dictation's stream.
    func cancelStreams() async {
        streamGeneration += 1
        for key in Array(namedStreams.keys) { await cancelStream(key) }
    }
    /// When a meeting finishes or is deleted; the copy is otherwise kept so Resume is fast.
    func releaseDedicatedModels() { dedicatedModels = nil }
    func unload() async {
        verificationTask?.cancel(); verificationTask = nil
        verification.invalidate(); loadedManifest = nil
        await cancel()
        await cancelStreams()
        models = nil; dedicatedModels = nil; loadedDirectory = nil
    }

    // Developer fixture paths only. No file picker or file-transcription UI is exposed.
    /// Runs the periodic integrity check now, as it would run while a meeting is paused.
    func reverifyForFixture() async { await reverifyIfIdle() }

    func benchmark(samples: [Float]) async throws -> String {
        try await begin()
        guard let stream else { throw SpeechFailure.notReady }
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            try await stream.withinAppendSamples(Array(samples[offset..<min(offset + 1600, samples.count)]))
        }
        let text = try await stream.withinFinish()
        await stream.cleanup(); self.stream = nil
        return TranscriptFormatting.clean(text)
    }
}

enum SpeechFailure: Error { case notReady, busy, format, unexpectedNetwork
    case partial(String) }

/// A meeting session's text. `confirmed` and the still-changing `volatile` tail stay separate, so without a
/// flush the meeting can keep confirmed and settled words only.
struct NamedStreamResult: Sendable {
    var confirmed = "", volatile = ""
    var flushed = false
    var failure: Error?
    /// Confirmed, one space, volatile: the same construction as every live update.
    var text: String { [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ") }
    /// Developer fixtures: the cleaned text, or the failure.
    func checkedText() throws -> String {
        if let failure { throw failure }
        return TranscriptFormatting.clean(text)
    }
}

struct NamedStreamUpdate: Sendable {
    let confirmed: String
    let volatile: String
    let appendedSeconds: Double
}
