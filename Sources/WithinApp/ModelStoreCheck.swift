import Foundation
import WithinCore

/// Developer fixture check of the real downloader with a small, pinned subset
/// of public artifacts. This subset is never loaded as a speech model.
func modelStoreCheck() async {
    guard CommandLine.arguments.count == 4 else { print("Usage: Within --model-store-check fixture-directory report-json"); exit(2) }
    do {
        let complete = try loadManifest()
        let data = try JSONEncoder().encode(complete)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["files"] = (object["files"] as! [[String: Any]]).filter { ($0["size"] as! NSNumber).int64Value < 2_000_000 }
        let subset = try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: object))
        let base = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(UUID().uuidString)
        let store = ModelStore(manifest: subset, base: base)
        defer { try? FileManager.default.removeItem(at: base) }
        try await store.install { _ in }
        try await store.verify()
        let installed = await store.isInstalled()
        let directory = await store.directory
        let artifact = directory.appendingPathComponent(subset.files[0].path)
        let handle = try FileHandle(forWritingTo: artifact)
        try handle.write(contentsOf: Data([0xFF])); try handle.close()
        var corruptRefused = false
        do { try await store.verify() } catch { corruptRefused = true }
        try await store.remove()
        let removed = !(await store.isInstalled())
        var cancellationObject = object
        cancellationObject["files"] = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["files"] as! [[String: Any]]
        cancellationObject["files"] = (cancellationObject["files"] as! [[String: Any]]).filter { ($0["size"] as! NSNumber).int64Value > 100_000_000 }.prefix(1).map { $0 }
        let cancellationManifest = try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: cancellationObject))
        let cancellationBase = base.appendingPathComponent("cancellation")
        let cancellationStore = ModelStore(manifest: cancellationManifest, base: cancellationBase)
        let (events, continuation) = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let job = Task {
            defer { continuation.finish() }
            try await cancellationStore.install { continuation.yield($0.completedBytes) }
        }
        var cancelRequested = false
        for await bytes in events {
            if bytes >= 1_048_576 { cancelRequested = true; job.cancel(); break }
        }
        var canceled = false
        do { try await job.value } catch { canceled = cancelRequested }
        let installedAfterCancel = await cancellationStore.isInstalled()
        let staging = cancellationBase.appendingPathComponent("Model Downloads")
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        let cancellationClean = canceled && !installedAfterCancel && remaining.isEmpty
        let report: [String: Any] = ["publicPinnedArtifactSubsetOnly": true, "files": subset.files.count, "bytes": subset.totalBytes,
            "downloadAndVerifyPassed": installed, "corruptedArtifactRefused": corruptRefused, "removalPassed": removed,
            "cancellationRemovedStaging": cancellationClean, "allPassed": installed && corruptRefused && removed && cancellationClean]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        guard installed && corruptRefused && removed && cancellationClean else { throw ModelStoreError.download }
        print("Public model download, integrity refusal, and removal checks passed."); exit(0)
    } catch { print("Model-store fixture check failed."); exit(1) }
}
