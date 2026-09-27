import Foundation
import WithinCore

/// Voice notes live as one owner-only JSON file per note on this Mac. Unlike dictation
/// history, notes are deliberate documents, so they stay in Time Machine backups.
/// Nothing is synced or uploaded. Deleting a note is not a secure erase of the disk.
struct NotesStore {
    let directory: URL

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    func loadAll() -> (notes: [Note], unreadable: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], 0) }
        var notes: [Note] = [], unreadable = 0
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let note = try? JSONDecoder().decode(Note.self, from: data) { notes.append(note) } else { unreadable += 1 }
        }
        return (NoteText.newestFirst(notes), unreadable)
    }

    func save(_ note: Note) throws {
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
