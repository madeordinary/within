import Foundation
import CryptoKit
import Darwin

public struct ModelManifest: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
        public init(path: String, size: Int64, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
    }
    public let schema: Int
    public let name: String
    public let repository: String
    public let revision: String
    public let license: String
    public let licenseURL: String
    public let sourceURL: String
    public let encoder: String
    public let files: [Artifact]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public func validate() throws {
        guard schema == 1, revision.count == 40, revision.allSatisfy(\.isHexDigit),
              repository == "FluidInference/parakeet-tdt-0.6b-v3-coreml",
              encoder == "int8-v2", !files.isEmpty, files.count < 200,
              Set(files.map(\.path)).count == files.count else { throw IntegrityError.invalidManifest }
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !file.path.contains("\\"), !file.path.contains(":"), !file.path.contains("\0"),
                  file.size > 0, file.size < 2_000_000_000,
                  file.sha256.count == 64, file.sha256.allSatisfy(\.isHexDigit) else { throw IntegrityError.invalidManifest }
        }
    }
}

public enum IntegrityError: Error, Equatable { case invalidManifest, missing, unsafePath, wrongSize, wrongHash, unexpectedFile, changedDuringVerification }

/// A short-lived proof for resident models, never a persisted trust decision.
public struct ModelVerificationCache {
    public static let maximumAge: Duration = .seconds(300)
    private var manifest: ModelManifest?
    private var snapshot: ModelFileSnapshot?
    private var verifiedAt: ContinuousClock.Instant?
    public init() {}
    public mutating func invalidate() { manifest = nil; snapshot = nil; verifiedAt = nil }

    /// Returns true when full hashing ran. Metadata is inspected even on a cache hit.
    @discardableResult public mutating func verify(_ proposedManifest: ModelManifest, at root: URL,
        force: Bool = false, now: ContinuousClock.Instant = .now) throws -> Bool {
        do {
            let current = try ModelIntegrity.snapshot(proposedManifest, at: root)
            if !force, manifest == proposedManifest, snapshot == current,
               let verifiedAt, now >= verifiedAt, verifiedAt.duration(to: now) < Self.maximumAge { return false }
            invalidate()
            let verified = try ModelIntegrity.verifiedSnapshot(proposedManifest, at: root)
            try Task.checkCancellation()
            manifest = proposedManifest; snapshot = verified; verifiedAt = now
            return true
        } catch {
            invalidate()
            throw error
        }
    }
}

private struct ModelFileSnapshot: Equatable {
    struct Entry: Equatable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let links: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
    let root: String
    let entries: [Entry]
}

public enum ModelIntegrity {
    public static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ manifest: ModelManifest, at proposedRoot: URL) throws {
        _ = try verifiedSnapshot(manifest, at: proposedRoot)
    }

    fileprivate static func verifiedSnapshot(_ manifest: ModelManifest, at root: URL) throws -> ModelFileSnapshot {
        let before = try snapshot(manifest, at: root)
        for file in manifest.files {
            try Task.checkCancellation()
            guard try hash(root.appendingPathComponent(file.path)) == file.sha256 else { throw IntegrityError.wrongHash }
        }
        let after = try snapshot(manifest, at: root)
        guard before == after else { throw IntegrityError.changedDuringVerification }
        return after
    }

    fileprivate static func snapshot(_ manifest: ModelManifest, at proposedRoot: URL) throws -> ModelFileSnapshot {
        try manifest.validate()
        let fm = FileManager.default
        func entry(_ url: URL, path: String) throws -> ModelFileSnapshot.Entry {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ pointer in
                pointer.map { lstat($0, &info) } ?? -1
            }) == 0 else { throw IntegrityError.missing }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { throw IntegrityError.unsafePath }
            return .init(path: path, device: info.st_dev, inode: info.st_ino, size: info.st_size,
                mode: info.st_mode, links: info.st_nlink,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
        let proposed = try entry(proposedRoot, path: "")
        guard proposed.mode & S_IFMT == S_IFDIR else { throw IntegrityError.unsafePath }
        // Foundation may canonicalize /var to /private/var while enumerating.
        let root = proposedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.size) })
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries = [try entry(root, path: "")]
        var found = Set<String>()
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            enumerationFailed = true; return false
        }) else { throw IntegrityError.missing }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw IntegrityError.unsafePath }
            let relative = String(path.dropFirst(prefix.count))
            let value = try entry(url, path: relative)
            entries.append(value)
            if value.mode & S_IFMT == S_IFREG {
                guard let size = expected[relative] else { throw IntegrityError.unexpectedFile }
                guard value.size == size else { throw IntegrityError.wrongSize }
                found.insert(relative)
            }
        }
        guard !enumerationFailed, found == Set(expected.keys) else { throw IntegrityError.missing }
        return .init(root: root.path, entries: entries.sorted { $0.path < $1.path })
    }
}
