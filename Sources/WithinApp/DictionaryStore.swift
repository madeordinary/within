import Foundation
import WithinCore

/// What the model knows about the saved dictionary. Only a missing or loaded file is ever changed or saved.
enum DictionaryState: Equatable { case missing, loaded, unreadable, newerVersion }

/// The personal dictionary lives in one owner-only file on this Mac. The user wrote it, so it stays
/// in Time Machine backups. Nothing is synced or uploaded. The model never saves over a file it couldn't
/// read or one from a newer version; it can only set it aside or remove it. Removing is not a secure erase.
struct DictionaryStore {
    let directory: URL
    enum Loaded: Equatable { case missing, loaded(PersonalDictionary), unreadable, newerVersion }
    private var file: URL { directory.appendingPathComponent("personal-dictionary.json") }

    func load() -> Loaded {
        for staging in stagingFiles() { try? FileManager.default.removeItem(at: staging) }
        // Only "no such file" is missing. A file in a folder Within can't search is unreadable, so it is never saved over.
        guard access(file.path, F_OK) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: PersonalDictionary.maximumFileSize + 1) else { return .unreadable }
        switch PersonalDictionary.decode(data) {
        case .loaded(let dictionary): return .loaded(dictionary)
        case .unreadable: return .unreadable
        case .newerVersion: return .newerVersion
        }
    }

    func save(_ dictionary: PersonalDictionary) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var current = dictionary
        current.version = PersonalDictionary.currentVersion
        let data = try JSONEncoder().encode(current)
        let staging = directory.appendingPathComponent(".personal-dictionary-\(UUID().uuidString).tmp")
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

    /// The file, every set-aside copy and every staging file. Tries them all, then reports the first failure.
    /// A folder that can't be listed is a failure, never an empty folder.
    func removeAll() throws {
        var failure: Error?
        for url in try files({ $0 == file.lastPathComponent || Self.isSetAside($0) || Self.isStaging($0) }) {
            do { try FileManager.default.removeItem(at: url) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    /// Keeps the file in the same folder under a name no other set-aside can take, still owner-only.
    func setAside() throws -> URL {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyyMMdd"
        let target = directory.appendingPathComponent("personal-dictionary.unreadable-\(day.string(from: Date()))-\(UUID().uuidString).json")
        guard rename(file.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    func setAsideFiles() -> [URL] { (try? files(Self.isSetAside)) ?? [] }
    private func stagingFiles() -> [URL] { (try? files(Self.isStaging)) ?? [] }
    private static func isSetAside(_ name: String) -> Bool { name.hasPrefix("personal-dictionary.unreadable-") && name.hasSuffix(".json") }
    private static func isStaging(_ name: String) -> Bool { name.hasPrefix(".personal-dictionary-") && name.hasSuffix(".tmp") }
    /// Only a folder that isn't there lists as empty.
    private func files(_ matching: (String) -> Bool) throws -> [URL] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) } catch CocoaError.fileReadNoSuchFile { return [] }
        return names.filter(matching).sorted().map { directory.appendingPathComponent($0) }
    }
}
