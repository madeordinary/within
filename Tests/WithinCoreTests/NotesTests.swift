import XCTest
@testable import WithinCore

final class NotesTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    func testDisplayTitlePrefersTitleThenFirstWords() {
        XCTAssertEqual(Note(title: "  Plan ", created: day).displayTitle, "Plan")
        XCTAssertEqual(Note(created: day, body: "one two three four five six seven").displayTitle, "one two three four five six")
        XCTAssertEqual(Note(created: day).displayTitle, "New note")
    }

    func testTranscriptBecomesItsOwnParagraph() {
        XCTAssertEqual(NoteText.appending("  First thought. ", to: ""), "First thought.")
        XCTAssertEqual(NoteText.appending("Second.", to: "Typed line  \n"), "Typed line\n\nSecond.")
        XCTAssertEqual(NoteText.appending(" <|nospeech|> ", to: "Keep"), "Keep")
    }

    func testSearchMatchesTitleOrBodyIgnoringCaseAndAccents() {
        let notes = [Note(title: "Café ideas", created: day), Note(created: day, body: "Groceries and errands")]
        XCTAssertEqual(NoteText.matching(notes, query: "cafe").count, 1)
        XCTAssertEqual(NoteText.matching(notes, query: "ERRANDS").count, 1)
        XCTAssertEqual(NoteText.matching(notes, query: " ").count, 2)
    }

    func testNewestModifiedFirst() {
        var older = Note(title: "older", created: day)
        var newer = Note(title: "newer", created: day)
        older.modified = day.addingTimeInterval(10); newer.modified = day.addingTimeInterval(20)
        XCTAssertEqual(NoteText.newestFirst([older, newer]).map(\.title), ["newer", "older"])
    }

    func testStoredNoteHasOnlyTextFields() throws {
        let data = try JSONEncoder().encode(Note(title: "T", created: day, body: "B"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "title", "created", "modified", "body"])
    }
}
