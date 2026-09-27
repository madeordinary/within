import Foundation
import WithinCore

/// Optional dictation history lives in one owner-only file on this Mac.
/// The folder is excluded from Time Machine; nothing here is synced or uploaded.
/// Removing entries rewrites or deletes the file; it is not a secure erase of the disk.
struct HistoryStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("dictation-history.json") }

    func load() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: file))
    }

    func save(_ entries: [HistoryEntry]) throws {
        guard !entries.isEmpty else { try removeAll(); return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let data = try JSONEncoder().encode(entries)
        let staging = directory.appendingPathComponent(".dictation-history-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(staging.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    func removeAll() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
