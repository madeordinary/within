import XCTest
@testable import WithinCore

final class UpdateCheckTests: XCTestCase {
    private func releases(_ entries: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: entries) }
    private func entry(_ tag: String, draft: Bool = false, prerelease: Bool = true, page: String = "https://github.com/madeordinary/within/releases/tag/x") -> [String: Any] {
        ["tag_name": tag, "name": "Within \(tag)", "body": "Notes", "html_url": page, "draft": draft, "prerelease": prerelease]
    }

    func testBuildNumberComesFromTheTag() {
        XCTAssertEqual(UpdateCheck.build(fromTag: "v0.1.0-build12"), 12)
        XCTAssertNil(UpdateCheck.build(fromTag: "v0.1.0"))
        XCTAssertNil(UpdateCheck.build(fromTag: "v0.1.0-build12-rc"))
    }

    func testNoPublishedReleasesIsItsOwnResult() {
        XCTAssertEqual(UpdateCheck.evaluate(statusCode: 200, data: releases([]), currentBuild: 12), .noReleases)
        XCTAssertEqual(UpdateCheck.evaluate(statusCode: 200, data: releases([entry("nightly")]), currentBuild: 12), .noReleases)
    }

    func testNewestNewerBuildIsOfferedIncludingPrereleases() {
        let result = UpdateCheck.evaluate(statusCode: 200, data: releases([entry("v0.1.0-build13"), entry("v0.1.0-build14")]), currentBuild: 12)
        guard case .available(let release) = result else { return XCTFail("expected an update") }
        XCTAssertEqual(release.build, 14)
        XCTAssertTrue(release.prerelease)
    }

    func testNeverOffersTheSameOrAnOlderBuild() {
        XCTAssertEqual(UpdateCheck.evaluate(statusCode: 200, data: releases([entry("v0.1.0-build12")]), currentBuild: 12), .upToDate(currentBuild: 12))
        XCTAssertEqual(UpdateCheck.evaluate(statusCode: 200, data: releases([entry("v0.1.0-build9")]), currentBuild: 12), .upToDate(currentBuild: 12))
    }

    func testDraftsAndForeignPagesAreIgnored() {
        let data = releases([entry("v0.1.0-build20", draft: true), entry("v0.1.0-build21", page: "https://example.com/within")])
        XCTAssertEqual(UpdateCheck.evaluate(statusCode: 200, data: data, currentBuild: 12), .noReleases)
    }

    func testErrorsAndMalformedResponsesAreUnavailable() {
        XCTAssertEqual(UpdateCheck.evaluate(statusCode: 403, data: releases([entry("v0.1.0-build13")]), currentBuild: 12), .unavailable)
        XCTAssertEqual(UpdateCheck.evaluate(statusCode: 200, data: Data("not json".utf8), currentBuild: 12), .unavailable)
    }

    func testAutomaticChecksRunOnlyWhenChosenAndWeekly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(UpdateCheck.automaticCheckDue(enabled: nil, lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.automaticCheckDue(enabled: false, lastCheck: nil, now: now))
        XCTAssertTrue(UpdateCheck.automaticCheckDue(enabled: true, lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.automaticCheckDue(enabled: true, lastCheck: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateCheck.automaticCheckDue(enabled: true, lastCheck: now.addingTimeInterval(-8 * 86_400), now: now))
    }

    func testNotesAreShownAsPlainTextWithoutTheRepeatedTitle() {
        let build13 = "Within 0.1.0 (build 13), engineering preview.\n\nNot signed yet.\n\nChanges:\n- Mute this Mac's sound\n- Add benchmarks"
        XCTAssertEqual(UpdateCheck.displayNotes(build13), "Not signed yet.\n\nChanges:\n• Mute this Mac's sound\n• Add benchmarks")
        let markdown = "## What's new\r\n\r\n\r\n* **Mute** while you [dictate](https://github.com/x)\n\n"
        XCTAssertEqual(UpdateCheck.displayNotes(markdown), "What's new\n\n• Mute while you dictate")
        XCTAssertEqual(UpdateCheck.displayNotes("a\nb\nc\n\nd", maximumLines: 3), "a\nb\nc\n…")
        XCTAssertEqual(UpdateCheck.displayNotes(" \n"), "")
    }

    /// Updates must keep reading files written by earlier builds: new fields have to be
    /// optional or custom-decoded. These are today's on-disk formats.
    func testFilesFromBuild11StillDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode([HistoryEntry].self, from: Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":810000000,"text":"Hello"}]"#.utf8)))
        XCTAssertNoThrow(try decoder.decode(Note.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"T","created":810000000,"modified":810000100,"body":"B"}"#.utf8)))
        XCTAssertNoThrow(try decoder.decode(Meeting.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"","created":810000000,"modified":810000000,"appName":"Zoom","segments":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","source":"you","offset":1,"text":"Hi"}],"notes":""}"#.utf8)))
    }
}
