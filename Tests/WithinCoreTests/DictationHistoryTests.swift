import XCTest
@testable import WithinCore

final class DictationHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func entry(_ ageSeconds: TimeInterval, _ text: String = "Words") -> HistoryEntry {
        HistoryEntry(date: now.addingTimeInterval(-ageSeconds), text: text)
    }

    func testUnsetPreferenceIsNotAChoice() {
        XCTAssertNil(HistoryRetention.restored(from: nil))
        XCTAssertNil(HistoryRetention.restored(from: "unknown"))
        XCTAssertEqual(HistoryRetention.restored(from: "week"), .week)
    }

    func testOffKeepsNothingAndNeverAdds() {
        XCTAssertEqual(HistoryPolicy.prune([entry(1), entry(60)], now: now, retention: .off), [])
        XCTAssertEqual(HistoryPolicy.adding("Hello", at: now, to: [entry(1)], retention: .off), [])
    }

    func testRetentionBoundariesAndNewestFirst() {
        let kept = entry(7 * 86_400 - 1, "kept")
        let expired = entry(7 * 86_400 + 1, "expired")
        let newest = entry(5, "newest")
        XCTAssertEqual(HistoryPolicy.prune([kept, expired, newest], now: now, retention: .week), [newest, kept])
        XCTAssertEqual(HistoryPolicy.prune([entry(86_401)], now: now, retention: .day), [])
        XCTAssertEqual(HistoryPolicy.prune([entry(29 * 86_400)], now: now, retention: .month).count, 1)
    }

    func testForeverKeepsEverything() {
        let old = entry(3 * 365 * 86_400, "old")
        XCTAssertEqual(HistoryPolicy.prune([old, entry(1)], now: now, retention: .forever).count, 2)
    }

    func testShorterRetentionPrunesImmediately() {
        let entries = [entry(10), entry(2 * 86_400), entry(20 * 86_400)]
        let month = HistoryPolicy.prune(entries, now: now, retention: .month)
        XCTAssertEqual(month.count, 3)
        XCTAssertEqual(HistoryPolicy.prune(month, now: now, retention: .day).count, 1)
    }

    func testAddingTrimsAndSkipsBlankText() {
        let added = HistoryPolicy.adding("  Keep these words.\n", at: now, to: [], retention: .week)
        XCTAssertEqual(added.map(\.text), ["Keep these words."])
        XCTAssertEqual(HistoryPolicy.adding(" \n\t", at: now, to: added, retention: .week), added)
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let entries = [entry(1, "Café notes for Tuesday"), entry(2, "Groceries")]
        XCTAssertEqual(HistoryPolicy.matching(entries, query: "cafe").map(\.text), ["Café notes for Tuesday"])
        XCTAssertEqual(HistoryPolicy.matching(entries, query: "  ").count, 2)
    }

    func testStoredEntryContainsOnlyIdentifierDateAndText() throws {
        let data = try JSONEncoder().encode(entry(1, "Private words"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "date", "text"])
    }
}
