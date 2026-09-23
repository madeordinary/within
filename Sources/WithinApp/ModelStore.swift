import Foundation
import WithinCore

struct ModelProgress: Sendable { let completedBytes: Int64; let totalBytes: Int64; let file: Int; let count: Int }

actor ModelStore {
    let manifest: ModelManifest
    let base: URL
    var directory: URL { base.appendingPathComponent("Models/parakeet-tdt-0.6b-v3-coreml", isDirectory: true) }
    init(manifest: ModelManifest, base: URL) { self.manifest = manifest; self.base = base }

    func isInstalled() -> Bool { FileManager.default.fileExists(atPath: directory.path) }
    func verify() throws { try ModelIntegrity.verify(manifest, at: directory) }

    func install(progress: @Sendable @escaping (ModelProgress) -> Void) async throws {
        try manifest.validate()
        let fm = FileManager.default
        let staging = base.appendingPathComponent("Model Downloads/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 3600
        var complete: Int64 = 0
        for (index, file) in manifest.files.enumerated() {
            try Task.checkCancellation()
            progress(.init(completedBytes: complete, totalBytes: manifest.totalBytes, file: index + 1, count: manifest.files.count))
            let endpoint = "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(file.path)"
            guard let url = URL(string: endpoint) else { throw IntegrityError.invalidManifest }
            var request = URLRequest(url: url)
            request.setValue("Within/0.1", forHTTPHeaderField: "User-Agent")
            let priorBytes = complete
            let boundary = ModelDownloadBoundary(destination: staging.appendingPathComponent(".incoming-\(UUID().uuidString)"), maximumBytes: file.size) { bytes in
                progress(.init(completedBytes: priorBytes + bytes, totalBytes: self.manifest.totalBytes, file: index + 1, count: self.manifest.files.count))
            }
            let session = URLSession(configuration: config, delegate: boundary, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (temporary, response) = try await boundary.download(request, using: session)
            try Task.checkCancellation()
            defer { try? fm.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let finalURL = response.url, NetworkBoundary.permitsModelDownload(finalURL) else { throw ModelStoreError.download }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard Int64(size ?? -1) == file.size else { throw IntegrityError.wrongSize }
            guard try ModelIntegrity.hash(temporary) == file.sha256 else { throw IntegrityError.wrongHash }
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: target)
            complete += file.size
        }
        try ModelIntegrity.verify(manifest, at: staging)
        try Task.checkCancellation()
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A known installation is never replaced implicitly. Remove via the explicit UI first.
        guard !fm.fileExists(atPath: directory.path) else { throw ModelStoreError.alreadyInstalled }
        try fm.moveItem(at: staging, to: directory)
        progress(.init(completedBytes: complete, totalBytes: manifest.totalBytes, file: manifest.files.count, count: manifest.files.count))
    }

    func remove() throws {
        if isInstalled() { try FileManager.default.removeItem(at: directory) }
    }
    func cleanInterruptedDownloads() throws {
        let parent = base.appendingPathComponent("Model Downloads", isDirectory: true)
        if FileManager.default.fileExists(atPath: parent.path) { try FileManager.default.removeItem(at: parent) }
    }
}

enum ModelStoreError: Error { case download, alreadyInstalled }

/// A delegate-driven transfer is intentional: Foundation's async convenience
/// download path does not consistently forward progress to the session delegate.
/// The lock protects only task/continuation/progress metadata, never audio.
final class ModelDownloadBoundary: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var lastReportedBytes: Int64 = 0
    private var canceled = false
    private var transfer: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(destination: URL, maximumBytes: Int64, progress: @Sendable @escaping (Int64) -> Void) {
        self.destination = destination; self.maximumBytes = maximumBytes; self.progress = progress
    }
    func download(_ request: URLRequest, using session: URLSession) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if canceled {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                transfer = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); canceled = true; let task = transfer; lock.unlock()
        task?.cancel()
        complete(.failure(CancellationError()))
    }
    private func complete(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let waiting = continuation; continuation = nil
        let shouldCancel = canceled
        lock.unlock()
        if shouldCancel { waiting?.resume(throwing: CancellationError()) }
        else { waiting?.resume(with: result) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(NetworkBoundary.permitsModelDownload) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            downloadTask.cancel(); complete(.failure(IntegrityError.wrongSize)); return
        }
        lock.lock()
        let report = totalBytesWritten == maximumBytes || totalBytesWritten - lastReportedBytes >= 1_048_576
        if report { lastReportedBytes = totalBytesWritten }
        lock.unlock()
        if report { progress(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let shouldCancel = canceled; lock.unlock()
        guard !shouldCancel, let response = downloadTask.response else { complete(.failure(CancellationError())); return }
        do {
            // URLSession owns and deletes `location` after this callback returns.
            // Move it into our staging area before resuming the awaiting actor.
            try FileManager.default.moveItem(at: location, to: destination)
            complete(.success((destination, response)))
        } catch { complete(.failure(ModelStoreError.download)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        complete(.failure(error ?? ModelStoreError.download))
    }
}
