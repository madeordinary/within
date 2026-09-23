import Foundation
import FluidAudio
import WithinCore

func speechSafetyCheck() async {
    guard CommandLine.arguments.count == 5 else { print("Usage: Within --speech-safety-check model-directory public-fixture-directory report-json"); exit(2) }
    do {
        URLProtocol.registerClass(OfflineProbe.self)
        defer { URLProtocol.unregisterClass(OfflineProbe.self) }
        let speech = LocalSpeech()
        try await speech.prepare(directory: URL(fileURLWithPath: CommandLine.arguments[2]), manifest: loadManifest())
        try await speech.begin()
        let canceledRing = AudioRing(capacity: 320000, sampleLimit: 4800000)
        let values = [Float](repeating: 0.01, count: 256000)
        values.withUnsafeBufferPointer { _ = canceledRing.push($0.baseAddress!, count: values.count) }
        let canceledJob = Task { try await speech.consume(canceledRing, sampleRate: 16000) }
        try await Task.sleep(for: .milliseconds(30))
        canceledJob.cancel(); canceledRing.close()
        var cancellationRefusedOutput = false
        do { _ = try await canceledJob.value } catch is CancellationError { cancellationRefusedOutput = true }
        catch { cancellationRefusedOutput = false }

        func consume(_ samples: [Float]) async throws -> String {
            try await speech.begin()
            let ring = AudioRing(capacity: 320000, sampleLimit: 4800000)
            let job = Task { try await speech.consume(ring, sampleRate: 16000) }
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                let count = min(1600, samples.count - offset)
                while ring.pending + count > ring.capacity { try await Task.sleep(for: .milliseconds(1)) }
                let result = samples.withUnsafeBufferPointer { ring.push($0.baseAddress!.advanced(by: offset), count: count) }
                guard result == 0 else { job.cancel(); ring.close(); throw SpeechFailure.format }
            }
            ring.close()
            return try await job.value
        }
        let silence = try await consume([Float](repeating: 0, count: 16000))
        let fixtures = [("01-validation-request-21.4s.wav", "help them out"),
                        ("02-release-readiness-19.8s.wav", "cutting a release"),
                        ("03-diff-explanation-16.9s.wav", "in that difference")]
        var fixtureReports: [[String: Any]] = []
        for (name, tail) in fixtures {
            let file = URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent(name)
            let samples = try AudioConverter().resampleAudioFile(file)
            let text = try await consume(samples)
            let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            fixtureReports.append(["fixture": name, "audioSeconds": Double(samples.count) / 16000,
                "expectedTailPresent": normalized.contains(tail), "publicFixtureTranscript": text,
                "seamArtifactAbsent": name != "03-diff-explanation-16.9s.wav" || !text.lowercased().contains("and an,")])
        }
        let allPassed = cancellationRefusedOutput && silence.isEmpty && OfflineProbe.requestCount == 0
            && fixtureReports.allSatisfy { $0["expectedTailPresent"] as? Bool == true && $0["seamArtifactAbsent"] as? Bool == true }
        let report: [String: Any] = ["fixtureOnly": true, "cancelReturnedNoText": cancellationRefusedOutput,
            "subsequentSessionSucceeded": true, "silenceProducedNoText": silence.isEmpty,
            "interceptedNetworkRequests": OfflineProbe.requestCount, "publicFixtures": fixtureReports, "allPassed": allPassed,
            "limitations": "Three public upstream regression clips and synthetic cancellation/silence inputs, not a general accuracy benchmark or live microphone test."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
        await speech.unload()
        guard allPassed else { throw SpeechFailure.format }
        print("Local speech cancellation, silence, restart, and public-fixture seam checks passed."); exit(0)
    } catch { print("Local speech safety fixture check failed."); exit(1) }
}
