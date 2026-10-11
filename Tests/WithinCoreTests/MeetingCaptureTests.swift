import XCTest
@testable import WithinCore

final class MeetingCaptureTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Clock

    func testFirstStretchOfANewMeetingStartsAtZero() {
        var clock = MeetingClock()
        XCTAssertNil(clock.offset(at: 50))
        XCTAssertEqual(clock.startStretch(of: Meeting(created: created, appName: "Zoom"), monotonic: 50, now: created), 0)
        XCTAssertEqual(clock.offset(at: 62.5), 12.5)
    }

    func testLaterStretchStartsAtThePreviousEndPlusTheMeasuredPause() {
        var clock = MeetingClock()
        var meeting = Meeting(created: created, appName: "Zoom")
        _ = clock.startStretch(of: meeting, monotonic: 100, now: created)
        meeting.stretches = [MeetingStretch(start: 0, sources: [.you], end: 30, ended: .pauseButton)]
        // The wall clock moved back while paused; the monotonic clock still counts the 45 s pause.
        XCTAssertEqual(clock.startStretch(of: meeting, monotonic: 175, now: created.addingTimeInterval(10)), 75)
        XCTAssertEqual(clock.offset(at: 180), 80)
    }

    func testContinuingAfterARelaunchUsesTheTimeSinceTheMeetingWasCreated() {
        var clock = MeetingClock()
        var meeting = Meeting(created: created, appName: "Zoom")
        meeting.stretches = [MeetingStretch(start: 0, sources: [.you], end: 600, ended: .finished)]
        XCTAssertEqual(clock.startStretch(of: meeting, monotonic: 5, now: created.addingTimeInterval(3600)), 3600)
        XCTAssertEqual(clock.offset(at: 15), 3610)
    }

    func testRelaunchedStartIsNeverBeforeTheLastEndOrTheLastWords() {
        var meeting = Meeting(created: created, appName: "Zoom")
        meeting.stretches = [MeetingStretch(start: 0, sources: [.you], end: 600, ended: .finished)]
        meeting.segments = [MeetingSegment(source: .you, offset: 650, text: "late words")]
        var behindTheWords = MeetingClock()
        // The wall clock was set back while Within was closed.
        XCTAssertEqual(behindTheWords.startStretch(of: meeting, monotonic: 0, now: created.addingTimeInterval(100)), 650)
        meeting.segments = []
        var behindTheEnd = MeetingClock()
        XCTAssertEqual(behindTheEnd.startStretch(of: meeting, monotonic: 0, now: created.addingTimeInterval(-50)), 600)
    }

    func testOpenStretchCountsUpToItsLastCheckpoint() {
        var meeting = Meeting(created: created, appName: "Zoom")
        var open = MeetingStretch(start: 0, sources: [.you])
        open.lastCheckpoint = 40
        meeting.stretches = [open]
        var clock = MeetingClock()
        XCTAssertEqual(clock.startStretch(of: meeting, monotonic: 0, now: created.addingTimeInterval(20)), 40)
    }

    func testTextDuringTheDrainIsClampedToTheStretchEnd() {
        XCTAssertEqual(MeetingClock.textOffset(130, stretchEnd: 120, lastSegment: 100), 120)
        XCTAssertEqual(MeetingClock.textOffset(110, stretchEnd: nil, lastSegment: 100), 110)
    }

    func testTextOffsetsNeverGoBackwards() {
        XCTAssertEqual(MeetingClock.textOffset(90, stretchEnd: nil, lastSegment: 100), 100)
        XCTAssertEqual(MeetingClock.textOffset(90, stretchEnd: 95, lastSegment: 100), 100)
        XCTAssertEqual(MeetingClock.textOffset(5, stretchEnd: nil, lastSegment: nil), 5)
    }

    // MARK: Update filter

    func testUpdatesOfAnEarlierStretchAreDropped() {
        var filter = MeetingUpdateFilter()
        XCTAssertFalse(filter.admit(stretch: 1, source: .you, sequence: 1, final: false))
        filter.begin(stretch: 2)
        XCTAssertFalse(filter.admit(stretch: 1, source: .you, sequence: 5, final: false))
        XCTAssertTrue(filter.admit(stretch: 2, source: .you, sequence: 1, final: false))
    }

    func testAnOlderOrRepeatedUpdateOfASourceIsDropped() {
        var filter = MeetingUpdateFilter()
        filter.begin(stretch: 1)
        XCTAssertTrue(filter.admit(stretch: 1, source: .you, sequence: 2, final: false))
        XCTAssertFalse(filter.admit(stretch: 1, source: .you, sequence: 2, final: false))
        XCTAssertFalse(filter.admit(stretch: 1, source: .you, sequence: 1, final: false))
        XCTAssertTrue(filter.admit(stretch: 1, source: .others, sequence: 1, final: false))
        XCTAssertTrue(filter.admit(stretch: 1, source: .you, sequence: 3, final: false))
    }

    func testNothingOfASourceAppliesAfterItsFinalResult() {
        var filter = MeetingUpdateFilter()
        filter.begin(stretch: 1)
        XCTAssertTrue(filter.admit(stretch: 1, source: .you, sequence: 4, final: true))
        XCTAssertFalse(filter.admit(stretch: 1, source: .you, sequence: 5, final: false))
        XCTAssertFalse(filter.admit(stretch: 1, source: .you, sequence: 6, final: true))
        XCTAssertTrue(filter.admit(stretch: 1, source: .others, sequence: 5, final: false))
    }

    func testANewStretchStartsEverySourceAfresh() {
        var filter = MeetingUpdateFilter()
        filter.begin(stretch: 1)
        XCTAssertTrue(filter.admit(stretch: 1, source: .you, sequence: 9, final: true))
        filter.begin(stretch: 2)
        XCTAssertTrue(filter.admit(stretch: 2, source: .you, sequence: 1, final: false))
    }

    func testSourceStatesAreAClosedSetOfStableNames() {
        XCTAssertEqual([MeetingSourceState.off, .live, .quiet, .lost].map(\.rawValue), ["off", "live", "quiet", "lost"])
    }
}
