import Foundation
import AVFoundation
import CoreAudio
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

// MARK: Meetings feasibility (developer-only)

private func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

/// Lists audio clients by bundle ID with their running-input/output flags. This is the
/// meeting-detection signal: it reads no window titles, audio, or call content.
func audioProcessList() {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { print("Process list unavailable."); exit(1) }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { print("Process list unavailable."); exit(1) }
    print("audio processes: \(objects.count)")
    for object in objects {
        let bundle = audioProperty(object, kAudioProcessPropertyBundleID, nil as CFString?).flatMap { $0 as String? } ?? "(none)"
        let input = audioProperty(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0
        let output = audioProperty(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0
        print("\(bundle)\tinput=\(input)\toutput=\(output)")
    }
    exit(0)
}

/// Plays a synthetic fixture through afplay, taps only that process (muted so nothing is
/// heard), and transcribes the tapped audio locally. Measures app-audio capture quality.
@available(macOS 14.2, *)
func appAudioTapFixture() async {
    guard CommandLine.arguments.count == 6, let seconds = Double(CommandLine.arguments[4]) else {
        print("Usage: Within --app-audio-tap-fixture model-directory fixture-audio seconds output-json"); exit(2)
    }
    var report: [String: Any] = ["fixtureOnly": true, "tappedProcess": "afplay", "muted": true]
    let output = URL(fileURLWithPath: CommandLine.arguments[5])
    func finish(_ code: Int32) -> Never {
        _ = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        exit(code)
    }
    do {
        URLProtocol.registerClass(OfflineProbe.self)
        let (all, rate) = try loadFixture(CommandLine.arguments[3])
        // Two seconds of leading silence let the muted tap attach before any sound starts.
        let samples = [Float](repeating: 0, count: Int(rate * 2)) + Array(all.prefix(Int(seconds * rate)))
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("within-tap-fixture-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: wav) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw SpeechFailure.format }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer)

        let speech = LocalSpeech()
        try await speech.prepare(directory: URL(fileURLWithPath: CommandLine.arguments[2]), manifest: try loadManifest())
        try await speech.begin()

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        try player.run()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        for _ in 0..<60 where processObject == kAudioObjectUnknown {
            var pid = player.processIdentifier
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject)
            if processObject == kAudioObjectUnknown { try await Task.sleep(for: .milliseconds(25)) }
        }
        report["processObjectFound"] = processObject != kAudioObjectUnknown
        guard processObject != kAudioObjectUnknown else { player.terminate(); finish(1) }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        report["defaultTapUUIDWasZero"] = description.uuid.uuidString == "00000000-0000-0000-0000-000000000000"
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        report["tapStatus"] = tapStatus
        guard tapStatus == noErr else { player.terminate(); finish(1) }
        defer { AudioHardwareDestroyProcessTap(tap) }

        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        outputDevice = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, outputDevice) ?? outputDevice
        let outputUID = audioProperty(outputDevice, kAudioDevicePropertyDeviceUID, nil as CFString?).flatMap { $0 as String? } ?? ""
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Within fixture tap", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        report["aggregateStatus"] = aggregateStatus
        guard aggregateStatus == noErr else { player.terminate(); finish(1) }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        var tapFormat = AudioStreamBasicDescription()
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &tapFormat)
        let tapRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48_000
        report["tapSampleRate"] = tapRate; report["tapChannels"] = tapFormat.mChannelsPerFrame

        let ring = AudioRing(capacity: Int(tapRate * 20), sampleLimit: UInt64(tapRate * (seconds + 30)))
        let mono = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
        defer { mono.deallocate() }
        // Spike-only counters, written on the IO thread and read after the device stops.
        let counters = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        counters.initialize(repeating: 0, count: 3)
        defer { counters.deallocate() }
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, _, _ in
            // Real-time path: downmix interleaved channels into a preallocated buffer, push to the ring.
            counters[0] += 1
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            counters[1] = max(counters[1], list.count)
            for buffer in list {
                counters[2] += Int(buffer.mDataByteSize)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frames = min(16_384, Int(buffer.mDataByteSize) / (4 * channels))
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += data[frame * channels + channel] }
                    mono[frame] = sum / Float(channels)
                }
                _ = ring.push(mono, count: frames)
            }
        }
        report["ioProcStatus"] = procStatus
        guard procStatus == noErr, let procID else { player.terminate(); finish(1) }
        defer { AudioDeviceDestroyIOProcID(aggregate, procID) }
        report["startStatus"] = AudioDeviceStart(aggregate, procID)

        let recognition = Task { try await speech.consume(ring, sampleRate: tapRate) }
        while player.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(500))
        AudioDeviceStop(aggregate, procID)
        ring.close()
        let text = try await recognition.value
        await speech.unload()
        report["ioCallbacks"] = counters[0]; report["maxInputBuffers"] = counters[1]; report["inputBytes"] = counters[2]
        report["capturedSeconds"] = Double(ring.samplesCaptured) / tapRate
        report["captureMeanEnergy"] = ring.meanEnergy
        report["likelySilentBecauseNotPermitted"] = ring.meanEnergy < 0.0000002
        report["syntheticFixtureTranscript"] = text
        report["interceptedNetworkRequests"] = OfflineProbe.requestCount
        print("App-audio tap fixture completed. No microphone was opened.")
        finish(0)
    } catch {
        report["error"] = "\(type(of: error))"
        print("App-audio tap fixture failed."); finish(1)
    }
}
