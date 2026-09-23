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
}
