import XCTest
import CryptoKit
@testable import WithinCore

final class IntegrityTests: XCTestCase {
    func manifest(path: String = "model/data.bin", data: Data = Data("trusted model".utf8)) throws -> ModelManifest {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let json: [String: Any] = ["schema": 1, "name": "Test", "repository": "FluidInference/parakeet-tdt-0.6b-v3-coreml", "revision": String(repeating: "a", count: 40), "license": "CC-BY-4.0", "licenseURL": "https://creativecommons.org/licenses/by/4.0/", "sourceURL": "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml", "encoder": "int8-v2", "files": [["path": path, "size": data.count, "sha256": digest]]]
        return try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("model"), withIntermediateDirectories: true)
        try Data("trusted model".utf8).write(to: root.appendingPathComponent("model/data.bin"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testValidFilesAndHashMutation() throws {
        let root = try fixture(); let manifest = try manifest()
        XCTAssertNoThrow(try ModelIntegrity.verify(manifest, at: root))
        try Data("changed model".utf8).write(to: root.appendingPathComponent("model/data.bin"))
        XCTAssertThrowsError(try ModelIntegrity.verify(manifest, at: root))
    }
    func testExtraFilesAreRefused() throws {
        let root = try fixture()
        try Data("untrusted".utf8).write(to: root.appendingPathComponent("extra.bin"))
        XCTAssertThrowsError(try ModelIntegrity.verify(manifest(), at: root)) { XCTAssertEqual($0 as? IntegrityError, .unexpectedFile) }
    }
    func testSymlinksAreRefused() throws {
        let root = try fixture()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("model"))
        XCTAssertThrowsError(try ModelIntegrity.verify(manifest(), at: root)) { XCTAssertEqual($0 as? IntegrityError, .unsafePath) }
    }
    func testTraversalAndAbsolutePathsAreRefused() throws {
        for path in ["../outside", "/outside", "model/../../file", "a//b", "a\\b", "a:b"] {
            XCTAssertThrowsError(try manifest(path: path).validate(), path)
        }
    }
    func testMissingFileIsRefused() throws {
        let root = try fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("model/data.bin"))
        XCTAssertThrowsError(try ModelIntegrity.verify(manifest(), at: root))
    }
    func testResidentVerificationExpiresAndExplicitInvalidationRehashes() throws {
        let root = try fixture(); let manifest = try manifest(); let now = ContinuousClock.now
        var cache = ModelVerificationCache()
        XCTAssertTrue(try cache.verify(manifest, at: root, now: now))
        XCTAssertFalse(try cache.verify(manifest, at: root, now: now.advanced(by: .seconds(299))))
        XCTAssertTrue(try cache.verify(manifest, at: root, now: now.advanced(by: .seconds(300))))
        XCTAssertTrue(try cache.verify(manifest, at: root, force: true, now: now.advanced(by: .seconds(301))))
        cache.invalidate()
        XCTAssertTrue(try cache.verify(manifest, at: root, now: now.advanced(by: .seconds(302))))
    }
    func testSameSizeMutationWithRestoredModificationDateIsRejectedAndClearsProof() throws {
        let root = try fixture(); let manifest = try manifest()
        let file = root.appendingPathComponent("model/data.bin")
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        var cache = ModelVerificationCache()
        try cache.verify(manifest, at: root)
        try Data("changed model".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        XCTAssertThrowsError(try cache.verify(manifest, at: root)) { XCTAssertEqual($0 as? IntegrityError, .wrongHash) }
        try Data("trusted model".utf8).write(to: file)
        XCTAssertTrue(try cache.verify(manifest, at: root))
        XCTAssertFalse(try cache.verify(manifest, at: root))
    }
    func testCachedVerificationRejectsAddedMissingAndSymbolicFiles() throws {
        for change in 0..<3 {
            let root = try fixture(); let manifest = try manifest()
            var cache = ModelVerificationCache()
            try cache.verify(manifest, at: root)
            switch change {
            case 0: try Data("extra".utf8).write(to: root.appendingPathComponent("extra"))
            case 1: try FileManager.default.removeItem(at: root.appendingPathComponent("model/data.bin"))
            default: try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("model"))
            }
            XCTAssertThrowsError(try cache.verify(manifest, at: root))
        }
    }
    func testVerificationProofIsBoundToManifestDirectoryAndFileIdentity() throws {
        let root = try fixture(); let otherRoot = try fixture(); let manifest = try manifest()
        var cache = ModelVerificationCache()
        try cache.verify(manifest, at: root)
        XCTAssertTrue(try cache.verify(manifest, at: otherRoot))
        let otherManifest = try self.manifest(data: Data("changed model".utf8))
        XCTAssertThrowsError(try cache.verify(otherManifest, at: otherRoot))
        try cache.verify(manifest, at: root)
        // Atomic replacement changes the file identity even if trusted bytes match.
        try Data("trusted model".utf8).write(to: root.appendingPathComponent("model/data.bin"), options: .atomic)
        XCTAssertTrue(try cache.verify(manifest, at: root))
    }
    func testRootSymlinkCannotReuseVerifiedTarget() throws {
        let root = try fixture(); let manifest = try manifest()
        var cache = ModelVerificationCache(); try cache.verify(manifest, at: root)
        let alias = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(try cache.verify(manifest, at: alias)) { XCTAssertEqual($0 as? IntegrityError, .unsafePath) }
    }
}
