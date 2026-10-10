import Foundation
import WithinCore

/// Saved documents (notes, meetings): text only, one per file, sorted by last change.
protocol LocalDocument: Codable, Equatable, Identifiable where ID == UUID {
    var modified: Date { get }
    /// Whether every store of this kind keeps its folder out of Time Machine, however it was built.
    static var excludedFromBackup: Bool { get }
}
/// Notes are deliberate documents, so they stay in backups.
extension Note: LocalDocument { static let excludedFromBackup = false }
/// Meetings hold other people's words, and backed-up copies can't be recalled: out of backups until the
/// owner decides otherwise (Q2).
extension Meeting: LocalDocument { static let excludedFromBackup = true }

typealias NotesStore = LocalDocumentStore<Note>
typealias MeetingStore = LocalDocumentStore<Meeting>

/// Voice notes and meetings live as one owner-only JSON file each on this Mac. A folder kept out of backups
/// is excluded before the first file is written. Nothing is synced or uploaded. Deleting one is not a
/// secure erase of the disk.
struct LocalDocumentStore<Document: LocalDocument> {
    let directory: URL

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private static func isStaging(_ name: String) -> Bool { name.hasPrefix(".") && name.hasSuffix(".tmp") }

    /// Also removes staging files a crash left behind, so call it before this process saves anything. A
    /// missing folder holds nothing yet; one that exists but can't be listed is `unlistable`, not empty.
    func loadAll() -> (documents: [Document], unreadable: Int, unlistable: Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return ([], 0, FileManager.default.fileExists(atPath: directory.path))
        }
        for name in names where Self.isStaging(name) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        var documents: [Document] = [], unreadable = 0
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let document = try? JSONDecoder().decode(Document.self, from: data) { documents.append(document) } else { unreadable += 1 }
        }
        return (documents.sorted { $0.modified > $1.modified }, unreadable, false)
    }

    /// The owner-only folder, already out of backups when its kind of document is.
    func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard Document.excludedFromBackup else { return }
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    func save(_ note: Document) throws {
        let manager = FileManager.default
        try prepareDirectory()
        let data = try JSONEncoder().encode(note)
        let staging = directory.appendingPathComponent(".\(note.id.uuidString)-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(staging.path, file(for: note.id).path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    func delete(_ id: UUID) throws {
        let target = file(for: id)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}

extension LocalDocumentStore where Document == Meeting {
    /// The meetings folder under `base`. The `.noindex` name is meant to keep Spotlight out; that is
    /// unverified until the owner's Spotlight check.
    init(meetingsIn base: URL) { self.init(directory: base.appendingPathComponent("Meetings.noindex", isDirectory: true)) }
}
