import Foundation
import AppKit
import AVFoundation
import FluidAudio
import WithinCore

func benchmark() async {
    guard CommandLine.arguments.count == 5 else { print("Usage: Within --benchmark model-directory synthetic-audio output-json"); exit(2) }
    do {
        URLProtocol.registerClass(OfflineProbe.self)
        defer { URLProtocol.unregisterClass(OfflineProbe.self) }
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: Bundle.module.url(forResource: "model-manifest", withExtension: "json")!))
        let engine = LocalSpeech()
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.prepare(directory: URL(fileURLWithPath: CommandLine.arguments[2]), manifest: manifest)
        let loadDuration = start.duration(to: clock.now)
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: CommandLine.arguments[3]))
        guard samples.count >= 1600 else { throw SpeechFailure.format }
        let inferenceStart = clock.now
        let text = try await engine.benchmark(samples: samples)
        let duration = inferenceStart.duration(to: clock.now)
        guard OfflineProbe.requestCount == 0 else { throw SpeechFailure.unexpectedNetwork }
        let report: [String: Any] = ["fixtureOnly": true, "interceptedNetworkRequests": OfflineProbe.requestCount, "sdkOfflineMode": ModelHub.offlineMode,
            "audioSeconds": Double(samples.count) / 16000,
            "loadSeconds": Double(loadDuration.components.seconds) + Double(loadDuration.components.attoseconds) / 1e18,
            "inferenceSeconds": Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18,
            "syntheticFixtureTranscript": text,
            "modelRevision": manifest.revision]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
        if CommandLine.arguments[1] == "--crash-fixture" { withExtendedLifetime((text, samples)) { abort() } }
        await engine.unload()
        print("Development fixture benchmark completed. Results contain synthetic fixture text only.")
        exit(0)
    } catch {
        // Do not serialize SDK errors: their descriptions may contain text or paths.
        print("Local model fixture check failed (integrity, loading, or inference).")
        exit(1)
    }
}

if CommandLine.arguments.contains("--speech-safety-check") {
    Task { await speechSafetyCheck() }
    dispatchMain()
} else if CommandLine.arguments.contains("--model-store-check") {
    Task { await modelStoreCheck() }
    dispatchMain()
} else if CommandLine.arguments.contains("--stream-benchmark") {
    Task { await streamBenchmark() }
    dispatchMain()
} else if CommandLine.arguments.contains("--benchmark") || CommandLine.arguments.contains("--crash-fixture") {
    Task { await benchmark() }
    dispatchMain()
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--native-checks" {
    MainActor.assumeIsolated {
        do { try nativeChecks(to: URL(fileURLWithPath: CommandLine.arguments[2])); print("Synthetic named-pasteboard checks passed.") }
        catch { print("Native fixture checks failed."); exit(1) }
    }
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-previews" {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        do { try renderPreviews(to: URL(fileURLWithPath: CommandLine.arguments[2])); print("Rendered synthetic app states. No microphone or downloads.") }
        catch { print("Preview rendering failed."); exit(1) }
    }
} else if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
    print("Unknown developer command."); exit(2)
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
