import AVFoundation
import FluidAudio
import WithinCore

/// The only owner of model residency and serial inference. No capture APIs here.
actor LocalSpeech {
    private var models: AsrModels?
    private var loadedDirectory: URL?
    private var stream: SlidingWindowAsrManager?
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
        guard stream == nil, !startingSession else { throw SpeechFailure.busy }
        do {
            try verification.verify(manifest, at: directory, force: models == nil)
            if models == nil || loadedDirectory != directory || loadedManifest != manifest {
                try Task.checkCancellation()
                models = try AsrModels.loadLocal(from: directory, version: .v3, encoderPrecision: .int8V2)
                loadedDirectory = directory; loadedManifest = manifest
            }
            try Task.checkCancellation()
            scheduleVerification()
        } catch {
            verification.invalidate(); models = nil; loadedDirectory = nil; loadedManifest = nil
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
        guard stream == nil, !startingSession, models != nil,
              let directory = loadedDirectory, let manifest = loadedManifest else { return }
        do { try verification.verify(manifest, at: directory, force: true) }
        catch {
            guard !Task.isCancelled else { return }
            verification.invalidate(); models = nil; loadedDirectory = nil; loadedManifest = nil
            verificationTask?.cancel(); verificationTask = nil
            await integrityFailureHandler?()
        }
    }

    func begin() async throws {
        guard let models else { throw SpeechFailure.notReady }
        guard stream == nil, !startingSession else { throw SpeechFailure.busy }
        startingSession = true
        defer { startingSession = false }
        let next = SlidingWindowAsrManager(config: .default)
        try await next.loadModels(models)
        try await next.withinBegin()
        stream = next
    }

    func consume(_ ring: AudioRing, sampleRate: Double) async throws -> String {
        guard let stream else { throw SpeechFailure.notReady }
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
    func unload() async {
        verificationTask?.cancel(); verificationTask = nil
        verification.invalidate(); loadedManifest = nil
        await cancel()
        models = nil; loadedDirectory = nil
    }

    // Developer fixture path only. No file picker or file-transcription UI is exposed.
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
