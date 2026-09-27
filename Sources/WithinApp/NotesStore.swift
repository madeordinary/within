import Foundation
import WithinCore

/// Saved documents (notes, meetings): text only, one per file, sorted by last change.
protocol LocalDocument: Codable, Equatable, Identifiable where ID == UUID {
    var modified: Date { get }
}
extension Note: LocalDocument {}
extension Meeting: LocalDocument {}

typealias NotesStore = LocalDocumentStore<Note>
typealias MeetingStore = LocalDocumentStore<Meeting>

/// Voice notes and meetings live as one owner-only JSON file each on this Mac. Unlike
/// dictation history, they are deliberate documents, so they stay in Time Machine backups.
/// Nothing is synced or uploaded. Deleting one is not a secure erase of the disk.
struct LocalDocumentStore<Document: LocalDocument> {
    let directory: URL

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    func loadAll() -> (notes: [Document], unreadable: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], 0) }
        var documents: [Document] = [], unreadable = 0
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let document = try? JSONDecoder().decode(Document.self, from: data) { documents.append(document) } else { unreadable += 1 }
        }
        return (documents.sorted { $0.modified > $1.modified }, unreadable)
    }

    func save(_ note: Document) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
