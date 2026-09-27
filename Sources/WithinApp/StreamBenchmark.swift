import Foundation
import AVFoundation
import FluidAudio
import WithinCore
import Darwin

/// Developer-only, file-backed substitute for microphone capture. It exercises
/// the production C ring, resampler, incremental inference, and final flush.
func streamBenchmark() async {
    guard CommandLine.arguments.count == 5 else { print("Usage: Within --stream-benchmark model-directory fixture-audio output-json"); exit(2) }
    do {
        URLProtocol.registerClass(OfflineProbe.self)
        defer { URLProtocol.unregisterClass(OfflineProbe.self) }
        let manifest = try loadManifest()
        let speech = LocalSpeech()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[3]))
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0, file.length > 1600,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw SpeechFailure.format }
        try file.read(into: buffer)
        guard let pointer = buffer.floatChannelData?[0] else { throw SpeechFailure.format }
        let samples = Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
        let rate = format.sampleRate
        let clock = ContinuousClock()
        let start = clock.now
        try await speech.prepare(directory: URL(fileURLWithPath: CommandLine.arguments[2]), manifest: manifest)
        let loaded = clock.now
        try await speech.begin()
        let ring = AudioRing(capacity: Int(rate * 20), sampleLimit: UInt64(rate * 300))
        let recognition = Task { try await speech.consume(ring, sampleRate: rate) }
        let recordingStart = clock.now
        let block = Int(rate / 10)
        for offset in stride(from: 0, to: samples.count, by: block) {
            let count = min(block, samples.count - offset)
            let status = samples.withUnsafeBufferPointer { ring.push($0.baseAddress!.advanced(by: offset), count: count) }
            if status != 0 { break }
            let next = recordingStart.advanced(by: .seconds(Double(offset + count) / rate))
            try await clock.sleep(until: next)
        }
        ring.close()
        let stopped = clock.now
        let text = try await recognition.value
        let finished = clock.now
        guard OfflineProbe.requestCount == 0, ring.status != 2 else { throw SpeechFailure.unexpectedNetwork }
        func seconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
            let value = from.duration(to: to).components; return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["fixtureOnly": true, "pacedAtRealTime": true, "sdkOfflineMode": ModelHub.offlineMode,
            "audioSeconds": Double(samples.count) / rate, "capturedSeconds": Double(ring.samplesCaptured) / rate,
            "loadSeconds": seconds(start, loaded), "captureWallSeconds": seconds(recordingStart, stopped),
            "releaseToResultSeconds": seconds(stopped, finished), "ringCapacitySamples": ring.capacity,
            "ringFinalStatus": ring.status, "peakResidentBytes": usage.ru_maxrss, "interceptedNetworkRequests": OfflineProbe.requestCount,
            "syntheticFixtureTranscript": text, "modelRevision": manifest.revision]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
        await speech.unload()
        print("Paced local fixture run completed. No microphone was opened."); exit(0)
    } catch { print("Paced fixture check failed."); exit(1) }
}

/// Lock-protected latest update from the speech actor. Holds counts, never writes text to disk.
private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(wall: Double, confirmed: Int, volatile: Int)] = []
    private var latest = (confirmed: 0, volatile: 0)
    private let start = ContinuousClock.now
    func record(_ confirmed: String, _ volatile: String) {
        let elapsed = ContinuousClock.now - start
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        lock.lock(); defer { lock.unlock() }
        entries.append((wall, confirmed.count, volatile.count)); latest = (confirmed.count, volatile.count)
    }
    var snapshot: [(wall: Double, confirmed: Int, volatile: Int)] { lock.lock(); defer { lock.unlock() }; return entries }
    var current: (confirmed: Int, volatile: Int) { lock.lock(); defer { lock.unlock() }; return latest }
}

private func physicalFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

private func loadFixture(_ path: String) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0, file.length > 1600,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw SpeechFailure.format }
    try file.read(into: buffer)
    guard let pointer = buffer.floatChannelData?[0] else { throw SpeechFailure.format }
    return (Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength))), format.sampleRate)
}

/// Developer-only: real-time-paced fixture with live updates. Reports update timing and an
/// estimated text lag from character counts; the report contains no transcript text.
func liveTextBenchmark() async {
    guard CommandLine.arguments.count >= 6, let limit = Double(CommandLine.arguments[4]) else {
        print("Usage: Within --live-text-benchmark model-directory fixture-audio seconds output-json [chunk-seconds]"); exit(2)
    }
    let chunk = CommandLine.arguments.count == 7 ? Double(CommandLine.arguments[6]) : nil
    do {
        URLProtocol.registerClass(OfflineProbe.self)
        defer { URLProtocol.unregisterClass(OfflineProbe.self) }
        let (all, rate) = try loadFixture(CommandLine.arguments[3])
        let samples = Array(all.prefix(Int(min(limit, Double(all.count) / rate) * rate)))
        let speech = LocalSpeech()
        try await speech.prepare(directory: URL(fileURLWithPath: CommandLine.arguments[2]), manifest: try loadManifest())
        let config = chunk.map { SlidingWindowAsrConfig(chunkSeconds: $0, hypothesisChunkSeconds: 1, leftContextSeconds: min(3, 13 - $0),
            rightContextSeconds: 2, minContextForConfirmation: 10, confirmationThreshold: 0.85) } ?? .default
        try await speech.begin(config: config)
        let ring = AudioRing(capacity: Int(rate * 20), sampleLimit: UInt64(Double(samples.count) + rate))
        let log = UpdateLog()
        let pushed = PushedCounter()
        let recognition = Task { try await speech.consume(ring, sampleRate: rate) { confirmed, volatile in
            log.record(confirmed, volatile); pushed.mark()
        } }
        let clock = ContinuousClock()
        let start = clock.now
        let block = Int(rate / 10)
        for offset in stride(from: 0, to: samples.count, by: block) {
            let count = min(block, samples.count - offset)
            let status = samples.withUnsafeBufferPointer { ring.push($0.baseAddress!.advanced(by: offset), count: count) }
            if status != 0 { break }
            pushed.set(Double(offset + count) / rate)
            try await clock.sleep(until: start.advanced(by: .seconds(Double(offset + count) / rate)))
        }
        ring.close()
        let final = try await recognition.value
        guard OfflineProbe.requestCount == 0 else { throw SpeechFailure.unexpectedNetwork }
        let audio = Double(samples.count) / rate
        let entries = log.snapshot
        let positions = pushed.marks
        let finalCount = max(1, final.count)
        var confirmedLags: [Double] = [], shownLags: [Double] = []
        for (index, entry) in entries.enumerated() where index < positions.count && positions[index] > 15 {
            confirmedLags.append(positions[index] - Double(entry.confirmed) / Double(finalCount) * audio)
            shownLags.append(positions[index] - Double(entry.confirmed + entry.volatile + 1) / Double(finalCount) * audio)
        }
        func median(_ v: [Double]) -> Double { v.isEmpty ? -1 : v.sorted()[v.count / 2] }
        func p90(_ v: [Double]) -> Double { v.isEmpty ? -1 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.9))] }
        let gaps = zip(entries.dropFirst(), entries).map { $0.wall - $1.wall }
        let report: [String: Any] = ["fixtureOnly": true, "pacedAtRealTime": true, "audioSeconds": audio,
            "updates": entries.count, "firstUpdateWallSeconds": entries.first?.wall ?? -1,
            "firstNonEmptyTextAudioSeconds": zip(entries, positions).first { $0.0.confirmed + $0.0.volatile > 0 }?.1 ?? -1,
            "medianUpdateGapSeconds": median(gaps), "estimatedConfirmedLagSecondsMedian": median(confirmedLags),
            "estimatedConfirmedLagSecondsP90": p90(confirmedLags), "estimatedShownLagSecondsMedian": median(shownLags),
            "estimatedShownLagSecondsP90": p90(shownLags), "finalCharacters": final.count,
            "chunkSeconds": config.chunkSeconds, "leftContextSeconds": config.leftContextSeconds, "rightContextSeconds": config.rightContextSeconds,
            "syntheticFixtureTranscript": final,
            "lagMethod": "character share of final transcript × audio pushed; assumes even speech density; estimate only",
            "interceptedNetworkRequests": OfflineProbe.requestCount]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[5]))
        await speech.unload()
        print("Live-text fixture run completed. No microphone was opened."); exit(0)
    } catch { print("Live-text fixture check failed."); exit(1) }
}

/// Audio position at each update, recorded by the feeder; counts only.
private final class PushedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var position = 0.0
    private var positions: [Double] = []
    func set(_ seconds: Double) { lock.lock(); position = seconds; lock.unlock() }
    func mark() { lock.lock(); positions.append(position); lock.unlock() }
    var marks: [Double] { lock.lock(); defer { lock.unlock() }; return positions }
}

/// Developer-only: loops a fixture faster than real time through one session and samples
/// memory each simulated minute. Answers whether long Notes sessions need segment rollover.
func longSessionSoak() async {
    guard CommandLine.arguments.count == 6, let minutes = Double(CommandLine.arguments[4]) else {
        print("Usage: Within --long-session-soak model-directory fixture-audio minutes output-json"); exit(2)
    }
    do {
        URLProtocol.registerClass(OfflineProbe.self)
        defer { URLProtocol.unregisterClass(OfflineProbe.self) }
        let (samples, rate) = try loadFixture(CommandLine.arguments[3])
        let total = Int(minutes * 60 * rate)
        let speech = LocalSpeech()
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double { let c = start.duration(to: clock.now).components; return Double(c.seconds) + Double(c.attoseconds) / 1e18 }
        let baseline = physicalFootprintMB()
        try await speech.prepare(directory: URL(fileURLWithPath: CommandLine.arguments[2]), manifest: try loadManifest())
        let loaded = physicalFootprintMB()
        try await speech.begin()
        let ring = AudioRing(capacity: Int(rate * 20), sampleLimit: UInt64(total) + UInt64(rate))
        let log = UpdateLog()
        let recognition = Task { try await speech.consume(ring, sampleRate: rate) { log.record($0, $1) } }
        var minutesLog: [[String: Double]] = []
        let block = Int(rate / 10)
        var fed = 0, nextMinute = Int(60 * rate)
        while fed < total {
            if ring.pending > ring.capacity / 2 { try await Task.sleep(for: .milliseconds(5)); continue }
            let offset = fed % samples.count
            let count = min(block, samples.count - offset, total - fed)
            let status = samples.withUnsafeBufferPointer { ring.push($0.baseAddress!.advanced(by: offset), count: count) }
            if status != 0 { throw SpeechFailure.busy }
            fed += count
            if fed >= nextMinute {
                let latest = log.current
                minutesLog.append(["simulatedMinute": Double(nextMinute) / rate / 60, "wallSeconds": elapsed(),
                    "physicalFootprintMB": physicalFootprintMB(), "confirmedCharacters": Double(latest.confirmed), "updates": Double(log.snapshot.count)])
                nextMinute += Int(60 * rate)
            }
        }
        ring.close()
        let closed = elapsed()
        let final = try await recognition.value
        let finished = elapsed()
        guard OfflineProbe.requestCount == 0, ring.status != 2 else { throw SpeechFailure.unexpectedNetwork }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["fixtureOnly": true, "fasterThanRealTime": true, "simulatedMinutes": minutes,
            "baselineFootprintMB": baseline, "afterModelLoadFootprintMB": loaded, "perMinute": minutesLog,
            "finalFlushSeconds": finished - closed, "totalWallSeconds": finished, "finalCharacters": final.count,
            "peakResidentBytes": usage.ru_maxrss, "ringFinalStatus": ring.status, "interceptedNetworkRequests": OfflineProbe.requestCount]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[5]))
        await speech.unload()
        print("Long-session fixture soak completed. No microphone was opened."); exit(0)
    } catch { print("Long-session fixture soak failed."); exit(1) }
}
