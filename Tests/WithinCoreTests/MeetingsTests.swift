import XCTest
@testable import WithinCore

final class MeetingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTranscriptAlternatesTurnsAndGrowsTheOpenTurn() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.others, transcript: "Thanks for joining", at: 2)
        builder.update(.others, transcript: "Thanks for joining everyone", at: 3)
        builder.update(.you, transcript: "Happy to be here", at: 5)
        builder.update(.others, transcript: "Thanks for joining everyone. Let's start", at: 7)
        XCTAssertEqual(builder.segments.map(\.source), [.others, .you, .others])
        XCTAssertEqual(builder.segments.map(\.text), ["Thanks for joining everyone", "Happy to be here", "Let's start"])
        XCTAssertEqual(builder.segments.map(\.offset), [2, 5, 7])
    }

    func testOpenTurnIsRederivedSoPartialWordsAreNotSplit() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "the libr", at: 1)
        builder.update(.you, transcript: "the library is quiet", at: 2)
        XCTAssertEqual(builder.segments.map(\.text), ["the library is quiet"])
    }

    func testGapStartsNewTurnsForRestartedSessions() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "Before the lock", at: 1)
        builder.markGap()
        builder.update(.you, transcript: "After unlocking", at: 40)
        XCTAssertEqual(builder.segments.map(\.text), ["Before the lock", "After unlocking"])
    }

    func testBlankAndNonSpeechTextIsIgnored() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.others, transcript: " <|nospeech|> ", at: 1)
        XCTAssertTrue(builder.segments.isEmpty)
    }

    func testLaunchingAMeetingAppNeverOffers() {
        var detector = MeetingDetector(enabled: true)
        XCTAssertEqual(detector.observe([AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: false)], now: now, captureActive: false), [])
    }

    func testMicrophoneStartOffersOncePerCallAndWithdrawsAtEnd() {
        var detector = MeetingDetector(enabled: true)
        let inCall = [AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)]
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [.offer(.zoom)])
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe([], now: now, captureActive: false), [.withdraw(.zoom)])
    }

    func testDismissHoldsUntilTheCallEnds() {
        var detector = MeetingDetector(enabled: true)
        let inCall = [AudioClientSnapshot(bundleID: "com.microsoft.teams2", runningInput: true)]
        _ = detector.observe(inCall, now: now, captureActive: false)
        detector.dismiss(.teams)
        _ = detector.observe([], now: now, captureActive: false)
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [.offer(.teams)])
    }

    func testSnoozeSuppressesWithoutBackfill() {
        var detector = MeetingDetector(enabled: true)
        detector.snooze(until: now.addingTimeInterval(3600))
        let inCall = [AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)]
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe(inCall, now: now.addingTimeInterval(7200), captureActive: false), [])
    }

    func testNoOfferWhileCapturingOrWhenDisabled() {
        var busy = MeetingDetector(enabled: true)
        XCTAssertEqual(busy.observe([AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)], now: now, captureActive: true), [])
        var off = MeetingDetector(enabled: false)
        XCTAssertEqual(off.observe([AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)], now: now, captureActive: false), [])
    }

    func testTeamsMatchesNewAndClassicBundles() {
        XCTAssertTrue(MeetingApp.teams.matches("com.microsoft.teams2"))
        XCTAssertTrue(MeetingApp.teams.matches("com.microsoft.teams"))
        XCTAssertFalse(MeetingApp.zoom.matches("com.microsoft.teams2"))
    }

    func testStoredMeetingHasOnlyTextFields() throws {
        let meeting = Meeting(created: now, appName: "Zoom", segments: [MeetingSegment(source: .you, offset: 1, text: "Hi")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "title", "created", "modified", "appName", "segments", "notes"])
        XCTAssertEqual(meeting.displayTitle, "Zoom meeting")
    }
}
