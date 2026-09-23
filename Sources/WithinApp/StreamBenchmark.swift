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
