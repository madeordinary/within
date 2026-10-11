import Foundation
import WithinCore

/// Saved documents (notes, meetings): text only, one per file, sorted by last change.
protocol LocalDocument: Codable, Equatable, Identifiable where ID == UUID {
    var modified: Date { get }
    /// Whether a store of this kind keeps its folder out of Time Machine unless it is built otherwise.
    static var excludedFromBackup: Bool { get }
}
/// Notes are deliberate documents, so they stay in backups.
extension Note: LocalDocument { static let excludedFromBackup = false }
/// Meetings hold other people's words, and backed-up copies can't be recalled: out of backups unless the user
/// turns backups on (owner answer to Q2: a switch, off by default).
extension Meeting: LocalDocument { static let excludedFromBackup = true }

typealias NotesStore = LocalDocumentStore<Note>
typealias MeetingStore = LocalDocumentStore<Meeting>

/// Voice notes and meetings live as one owner-only JSON file each on this Mac. A folder kept out of backups
/// is excluded before the first file is written. Nothing is synced or uploaded. Deleting one is not a
/// secure erase of the disk.
struct LocalDocumentStore<Document: LocalDocument> {
    let directory: URL
    /// Whether this store keeps its folder out of Time Machine: set when the folder is created, and changed on an
    /// existing folder only by `applyBackupChoice()`, so a store built with an older choice never undoes a newer one.
    let excludedFromBackup: Bool

    init(directory: URL, excludedFromBackup: Bool = Document.excludedFromBackup) {
        self.directory = directory; self.excludedFromBackup = excludedFromBackup
    }

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private static func isStaging(_ name: String) -> Bool { name.hasPrefix(".") && name.hasSuffix(".tmp") }

    /// Also removes staging files a crash left behind, so call it before this process saves anything; a later
    /// read passes `sweepingStaging: false`, as a save may be writing one. A missing folder holds nothing yet;
    /// one that exists but can't be listed is `unlistable`, not empty.
    func loadAll(sweepingStaging: Bool = true) -> (documents: [Document], unreadable: Int, unlistable: Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return ([], 0, FileManager.default.fileExists(atPath: directory.path))
        }
        for name in names where sweepingStaging && Self.isStaging(name) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        var documents: [Document] = [], unreadable = 0
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let document = try? JSONDecoder().decode(Document.self, from: data) { documents.append(document) } else { unreadable += 1 }
        }
        return (documents.sorted { $0.modified > $1.modified }, unreadable, false)
    }

    /// The owner-only folder. One this call creates (mkdir(2) says so) is out of backups, when the store excludes
    /// them, before anything else is done to it; if that can't be set, the still-empty folder is removed so the next
    /// save tries again. A folder made elsewhere keeps the backup choice it has.
    func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let created = mkdir(directory.path, 0o700) == 0, failure = errno
        guard created || failure == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        if created, excludedFromBackup {
            do { try Self.setExcludedFromBackup(true, directory) } catch { rmdir(directory.path); throw error }
        }
        // Throws when the name belongs to something other than a folder.
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func setExcludedFromBackup(_ excluded: Bool, _ url: URL) throws {
        var item = url
        var values = URLResourceValues(); values.isExcludedFromBackup = excluded
        try item.setResourceValues(values)
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
    init(meetingsIn base: URL, excludedFromBackup: Bool = Meeting.excludedFromBackup) {
        self.init(directory: base.appendingPathComponent("Meetings.noindex", isDirectory: true), excludedFromBackup: excludedFromBackup)
    }

    var exists: Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &folder) && folder.boolValue
    }

    /// Meeting files, readable or not, counted by name without reading them: nil when the folder exists but can't be
    /// listed, and 0 without a folder.
    var fileCount: Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return exists ? nil : 0 }
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.count
    }

    /// Applies this store's backup choice to the folder that exists, creating nothing and returning false without one.
    /// The exclusion is written only when a folder is created, so call this at every launch while the folder exists.
    /// Including also clears any exclusion a meeting file carries of its own (Within never sets one), so every meeting
    /// reaches backups. A file that can't be changed doesn't stop the rest; the first failure is thrown once all were
    /// tried.
    @discardableResult func applyBackupChoice() throws -> Bool {
        guard exists else { return false }
        try Self.setExcludedFromBackup(excludedFromBackup, directory)
        guard !excludedFromBackup else { return true }
        var failure: Error?
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".json") && !name.hasPrefix(".") {
            do { try Self.setExcludedFromBackup(false, directory.appendingPathComponent(name)) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
        return true
    }

    /// Delete all: every meeting file, including ones that couldn't be read, and crash leftovers. The folder stays.
    /// A file that can't be removed doesn't stop the rest; the first failure is thrown once all were tried.
    func removeAll() throws {
        var failure: Error?
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".json") || Self.isStaging(name) {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
}

/// Saved meetings' upkeep, whatever the developer default says, and only on a folder that already exists: it never
/// creates one, never starts capture and never writes a preference.
enum MeetingUpkeep {
    struct Result: Equatable {
        /// Meeting files left, readable or not.
        var saved = 0
        var recovered = 0, deleted = 0, pruned = 0, failed = 0
        var unlistable = false
        /// The meetings saved back as finished, still left after pruning: "to review" until opened in this run.
        var recoveredIDs: [UUID] = []
        /// The backup choice couldn't be applied to the folder.
        var backupFailed = false
    }

    /// At launch, before anything else uses the folder: the stored backup choice applied to it (it is written only
    /// when a folder is created, so this repairs a crash in between), crash leftovers swept, meetings a crash left
    /// open saved back as finished (or deleted when they hold nothing), then expired meetings deleted. Nil when there
    /// is no folder.
    static func atLaunch(base: URL, retention: DocumentRetention, excludedFromBackup: Bool = Meeting.excludedFromBackup, now: Date) -> Result? {
        run(MeetingStore(meetingsIn: base, excludedFromBackup: excludedFromBackup), retention: retention, now: now, launch: true, keeping: [])
    }

    /// Hourly and when retention changes: expired finished meetings only, leaving staging files a save may be
    /// writing, the backup choice and `keeping` alone.
    static func prune(base: URL, retention: DocumentRetention, excludedFromBackup: Bool = Meeting.excludedFromBackup, now: Date, keeping: Set<UUID>) -> Result? {
        run(MeetingStore(meetingsIn: base, excludedFromBackup: excludedFromBackup), retention: retention, now: now, launch: false, keeping: keeping)
    }

    private static func run(_ store: MeetingStore, retention: DocumentRetention, now: Date, launch: Bool, keeping: Set<UUID>) -> Result? {
        guard store.exists else { return nil }
        let backupFailed = launch && (try? store.applyBackupChoice()) == nil
        let loaded = store.loadAll(sweepingStaging: launch)
        var result = Result(unlistable: loaded.unlistable, backupFailed: backupFailed)
        var meetings = loaded.documents
        var recovered: [UUID] = []
        if launch {
            let recovery = MeetingRecovery.recover(meetings)
            for id in recovery.deleted {
                if (try? store.delete(id)) != nil { result.deleted += 1; meetings.removeAll { $0.id == id } } else { result.failed += 1 }
            }
            for meeting in recovery.recovered {
                // Checked again before each save, which would otherwise create a folder removed meanwhile.
                guard store.exists, (try? store.save(meeting)) != nil, let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { result.failed += 1; continue }
                meetings[index] = meeting
                result.recovered += 1; recovered.append(meeting.id)
            }
        }
        for id in retention.expired(meetings, now: now) where !keeping.contains(id) {
            if (try? store.delete(id)) != nil { result.pruned += 1; meetings.removeAll { $0.id == id } } else { result.failed += 1 }
        }
        result.recoveredIDs = recovered.filter { id in meetings.contains { $0.id == id } }
        result.saved = meetings.count + loaded.unreadable
        return result
    }
}
