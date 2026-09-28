import AVFoundation
import Foundation
import Speech

/// Developer-only comparison of Apple's on-device SpeechTranscriber (macOS 26+) with the
/// Parakeet fixtures. Synthetic audio only; no microphone. Assets download only with consent.
@available(macOS 26.0, *)
func appleSpeechStatus() async {
    let locale = Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    let supported = await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == "en-US" }
    let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == "en-US" }
    let status = await AssetInventory.status(forModules: [transcriber])
    print("en-US supported=\(supported) installed=\(installed) assetStatus=\(status)")
    exit(0)
}

/// Accumulates finalized text and the latest volatile tail, by audio position and wall time.
private final class AppleResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var finalized = ""
    private(set) var volatile = ""
    private(set) var updates: [(wall: Double, audio: Double, final: Int, volatile: Int)] = []
    func record(_ text: String, isFinal: Bool, wall: Double, audio: Double) {
        lock.lock(); defer { lock.unlock() }
        if isFinal { finalized += text; volatile = "" } else { volatile = text }
        updates.append((wall, audio, finalized.count, volatile.count))
    }
    var snapshot: (String, [(wall: Double, audio: Double, final: Int, volatile: Int)]) { lock.lock(); defer { lock.unlock() }; return (finalized, updates) }
}

/// `paced` feeds real time for latency; `fast` feeds as quickly as accepted for throughput and accuracy.
@available(macOS 26.0, *)
func appleSpeechBenchmark() async {
    let args = CommandLine.arguments
    guard args.count >= 6, let seconds = Double(args[3]) else {
        print("Usage: Within --apple-speech-benchmark fixture-audio seconds output-json paced|fast [allow-asset-download]"); exit(2)
    }
    let paced = args[5] == "paced"
    var report: [String: Any] = ["fixtureOnly": true, "engine": "Apple SpeechTranscriber (progressiveTranscription, en-US)", "paced": paced]
    let output = URL(fileURLWithPath: args[4])
    func finish(_ code: Int32) -> Never {
        _ = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output); exit(code)
    }
    do {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        report["assetStatusBefore"] = "\(status)"
        if status != .installed {
            // Without consent to download, try with what the system already has and report any failure.
            if args.count == 7, args[6] == "allow-asset-download" {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
                report["assetStatusAfter"] = "\(await AssetInventory.status(forModules: [transcriber]))"
            }
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
        let sourceFormat = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), seconds * sourceFormat.sampleRate))
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { throw SpeechFailure.format }
        try file.read(into: source, frameCount: frames)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: sourceFormat),
              let converter = AVAudioConverter(from: sourceFormat, to: format) else { throw SpeechFailure.format }
        report["analyzerSampleRate"] = format.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (inputs, builder) = AsyncStream<AnalyzerInput>.makeStream()
        let results = AppleResults()
        let clock = ContinuousClock()
        let start = clock.now
        let pushed = PushedPosition()
        @Sendable func wall() -> Double { let c = start.duration(to: ContinuousClock.now).components; return Double(c.seconds) + Double(c.attoseconds) / 1e18 }
        let collector = Task {
            for try await result in transcriber.results {
                results.record(String(result.text.characters), isFinal: result.isFinal, wall: wall(), audio: pushed.value)
            }
        }
        try await analyzer.start(inputSequence: inputs)
        let block = AVAudioFrameCount(sourceFormat.sampleRate / 10)
        var offset: AVAudioFrameCount = 0
        while offset < source.frameLength {
            let count = min(block, source.frameLength - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count) else { throw SpeechFailure.format }
            slice.frameLength = count
            for channel in 0..<Int(sourceFormat.channelCount) {
                slice.floatChannelData![channel].update(from: source.floatChannelData![channel].advanced(by: Int(offset)), count: Int(count))
            }
            let capacity = AVAudioFrameCount(Double(count) * format.sampleRate / sourceFormat.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw SpeechFailure.format }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return slice
            }
            if let conversionError { throw conversionError }
            builder.yield(AnalyzerInput(buffer: converted))
            offset += count
            pushed.set(Double(offset) / sourceFormat.sampleRate)
            if paced { try await clock.sleep(until: start.advanced(by: .seconds(Double(offset) / sourceFormat.sampleRate))) }
        }
        let fed = wall()
        builder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try? await collector.value
        let done = wall()
        let (text, updates) = results.snapshot
        let audio = Double(source.frameLength) / sourceFormat.sampleRate
        let total = max(1, text.count)
        var shown: [Double] = [], confirmed: [Double] = []
        for update in updates where update.audio > 15 {
            shown.append(update.audio - Double(update.final + update.volatile) / Double(total) * audio)
            confirmed.append(update.audio - Double(update.final) / Double(total) * audio)
        }
        func median(_ v: [Double]) -> Double { v.isEmpty ? -1 : v.sorted()[v.count / 2] }
        func p90(_ v: [Double]) -> Double { v.isEmpty ? -1 : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.9))] }
        report["audioSeconds"] = audio
        report["feedWallSeconds"] = fed
        report["finishAfterInputSeconds"] = done - fed
        report["totalWallSeconds"] = done
        report["updates"] = updates.count
        report["firstNonEmptyTextAudioSeconds"] = updates.first { $0.final + $0.volatile > 0 }?.audio ?? -1
        report["estimatedShownLagSecondsMedian"] = median(shown); report["estimatedShownLagSecondsP90"] = p90(shown)
        report["estimatedConfirmedLagSecondsMedian"] = median(confirmed)
        report["peakResidentBytes"] = { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return usage.ru_maxrss }()
        report["syntheticFixtureTranscript"] = text
        print("Apple speech fixture completed. No microphone was opened."); finish(0)
    } catch {
        report["error"] = "\(error)"; print("Apple speech fixture failed."); finish(1)
    }
}

private final class PushedPosition: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    func set(_ value: Double) { lock.lock(); seconds = value; lock.unlock() }
    var value: Double { lock.lock(); defer { lock.unlock() }; return seconds }
}
