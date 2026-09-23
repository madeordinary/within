import Foundation
import CryptoKit

public struct ModelManifest: Codable, Sendable {
    public struct Artifact: Codable, Sendable {
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

public enum IntegrityError: Error, Equatable { case invalidManifest, missing, unsafePath, wrongSize, wrongHash, unexpectedFile }

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
        try manifest.validate()
        let fm = FileManager.default
        guard (try proposedRoot.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw IntegrityError.unsafePath }
        // Foundation may canonicalize /var to /private/var while enumerating.
        let root = proposedRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: root.path) else { throw IntegrityError.missing }
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw IntegrityError.unsafePath }
        let expected = Set(manifest.files.map(\.path))
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { throw IntegrityError.missing }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw IntegrityError.unsafePath }
            if values.isRegularFile == true {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                guard path.hasPrefix(prefix) else { throw IntegrityError.unsafePath }
                let relative = String(path.dropFirst(prefix.count))
                guard expected.contains(relative) else { throw IntegrityError.unexpectedFile }
            }
        }
        for file in manifest.files {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw IntegrityError.unsafePath }
            guard Int64(values.fileSize ?? -1) == file.size else { throw IntegrityError.wrongSize }
            guard try hash(url) == file.sha256 else { throw IntegrityError.wrongHash }
        }
    }
}
