import XCTest
@testable import WithinCore

final class MeetingExportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private var words: DictionaryMatcher {
        DictionaryMatcher(PersonalDictionary(entries: [DictionaryEntry(heardAs: ["gira"], writeAs: "Jira", created: now),
                                                       DictionaryEntry(heardAs: ["shivon"], writeAs: "Siobhan", created: now.addingTimeInterval(1))]))
    }

    private var weeklySync: Meeting {
        Meeting(title: "Weekly sync", created: now, appName: "Zoom",
                segments: [MeetingSegment(source: .others, offset: 12, text: "Thanks for joining everyone."),
                           MeetingSegment(source: .you, offset: 20, text: "Happy to be here."),
                           MeetingSegment(source: .you, offset: 2830, text: "Back again with gira.")],
                notes: "Typed *line*\n# not a heading",
                stretches: [MeetingStretch(start: 0, sources: [.you, .others], end: 2710, ended: .lockOrSleep),
                            MeetingStretch(start: 2822, sources: [.you, .others], end: 4324, ended: .finished)],
                state: .finished)
    }

    // MARK: Gaps

    func testGapsRunFromEachClosedStretchToTheNextWithItsReason() {
        let meeting = Meeting(created: now, appName: "Zoom", stretches: [
            MeetingStretch(start: 0, sources: [.you, .others], end: 100, ended: .lockOrSleep),
            MeetingStretch(start: 130, sources: [.you], end: 200, ended: .durationLimit),
            MeetingStretch(start: 204, sources: [.you], end: 300, ended: .quitBeforeDrain),
            MeetingStretch(start: 400, sources: [.you])])
        XCTAssertEqual(meeting.gaps, [MeetingGap(start: 100, end: 130, reason: .lockOrSleep), MeetingGap(start: 200, end: 204, reason: .durationLimit),
                                      MeetingGap(start: 300, end: 400, reason: .quitBeforeDrain)])
        XCTAssertEqual(Meeting(created: now, appName: "Zoom", stretches: [MeetingStretch(start: 0, sources: [.you])]).gaps, [])
    }

    func testGapWordsNameTheAppAndTheRollover() {
        XCTAssertEqual(MeetingGap(start: 0, end: 1, reason: .computerAudioLost).detail(appName: "Zoom"), "Zoom’s sound or the output device changed")
        XCTAssertEqual(MeetingGap(start: 0, end: 1, reason: .durationLimit).label, "Continued past three hours (untested length)")
        XCTAssertNil(MeetingGap(start: 0, end: 1, reason: .pauseButton).detail(appName: "Zoom"))
        for reason in MeetingStretchEnd.allCases where reason != .pauseButton && reason != .durationLimit {
            XCTAssertNotNil(MeetingGap(start: 0, end: 1, reason: reason).detail(appName: "Zoom"), "\(reason)")
        }
    }

    // MARK: Markdown

    func testMarkdownHasHeaderLabelsTimestampsGapsAndNotesVerbatim() {
        XCTAssertEqual(MeetingExport.markdown(weeklySync, dictionary: words, timeZone: utc), """
            # Weekly sync

            2027-01-15 08:00 · Zoom · 1:12:04

            Transcribed on this Mac by Within. "You" is the microphone; "Others" is Zoom’s audio. Labels are sources, not people.

            Personal dictionary fixes were applied in 1 turn. The original transcription stays in Within.

            ## Transcript

            **[00:00:12] Others:** Thanks for joining everyone.

            **[00:00:20] You:** Happy to be here.

            *— Paused 00:45:10–00:47:02 · the Mac locked or slept —*

            **[00:47:10] You:** Back again with Jira.

            ## My notes

            Typed *line*
            # not a heading

            """)
    }

    func testDefaultExportNeverContainsTheOriginalTranscription() {
        let markdown = MeetingExport.markdown(weeklySync, dictionary: words, timeZone: utc)
        XCTAssertFalse(markdown.contains("gira"))
        XCTAssertTrue(markdown.contains("Back again with Jira."))
    }

    func testOriginalTranscriptionExportIsOptInAndHasOnlyThatVersion() {
        let markdown = MeetingExport.markdown(weeklySync, dictionary: words, useOriginalTranscription: true, timeZone: utc)
        XCTAssertTrue(markdown.contains("Original transcription, without personal dictionary fixes."))
        XCTAssertTrue(markdown.contains("**[00:47:10] You:** Back again with gira."))
        XCTAssertFalse(markdown.contains("Jira"))
        XCTAssertFalse(markdown.contains("fixes were applied"))
    }

    func testExportFixesOthersTurnsAndCountsWithTheCurrentDictionary() {
        var meeting = weeklySync
        meeting.segments.insert(MeetingSegment(source: .others, offset: 2840, text: "Ask shivon about gira."), at: 3)
        let markdown = MeetingExport.markdown(meeting, dictionary: words, timeZone: utc)
        XCTAssertTrue(markdown.contains("Personal dictionary fixes were applied in 2 turns. The original transcription stays in Within."))
        XCTAssertTrue(markdown.contains("**[00:47:20] Others:** Ask Siobhan about Jira."))
        let edited = DictionaryMatcher(PersonalDictionary(entries: [DictionaryEntry(heardAs: ["shivon"], writeAs: "Siobhan", created: now)]))
        let later = MeetingExport.markdown(meeting, dictionary: edited, timeZone: utc)
        XCTAssertTrue(later.contains("Personal dictionary fixes were applied in 1 turn."))
        XCTAssertTrue(later.contains("**[00:47:10] You:** Back again with gira."))
        XCTAssertTrue(later.contains("**[00:47:20] Others:** Ask Siobhan about gira."))
        let original = MeetingExport.markdown(meeting, dictionary: words, useOriginalTranscription: true, timeZone: utc)
        XCTAssertTrue(original.contains("**[00:47:20] Others:** Ask shivon about gira."))
        XCTAssertFalse(original.contains("Siobhan") || original.contains("Jira"))
    }

    func testEmptyDictionaryExportIsTheTranscriptionWithoutADictionaryLine() {
        let plain = MeetingExport.markdown(weeklySync, dictionary: .empty, timeZone: utc)
        XCTAssertEqual(plain, MeetingExport.markdown(weeklySync, dictionary: .empty, useOriginalTranscription: true, timeZone: utc))
        XCTAssertEqual(plain, MeetingExport.markdown(weeklySync, dictionary: words, useOriginalTranscription: true, timeZone: utc)
            .replacingOccurrences(of: "Original transcription, without personal dictionary fixes.\n\n", with: ""))
        XCTAssertFalse(plain.contains("dictionary"))
        XCTAssertTrue(plain.contains("**[00:47:10] You:** Back again with gira."))
    }

    func testMicrophoneOnlyExportWithoutFixesOrNotes() {
        let meeting = Meeting(created: now, appName: Meeting.microphoneOnly,
                              segments: [MeetingSegment(source: .you, offset: 3_725, text: "Note to self.")],
                              stretches: [MeetingStretch(start: 0, sources: [.you], end: 100, ended: .pauseButton),
                                          MeetingStretch(start: 3_700, sources: [.you], end: 3_800, ended: .microphoneLost),
                                          MeetingStretch(start: 3_900, sources: [.you], end: 3_950, ended: .finished)])
        XCTAssertEqual(MeetingExport.markdown(meeting, dictionary: .empty, timeZone: utc), """
            # Meeting

            2027-01-15 08:00 · Microphone only · 1:05:50

            Transcribed on this Mac by Within. "You" is the microphone. Labels are sources, not people.

            ## Transcript

            *— Paused 00:01:40–01:01:40 —*

            **[01:02:05] You:** Note to self.

            *— Paused 01:03:20–01:05:00 · the microphone was disconnected or changed —*

            """)
    }

    func testMeetingThatEndedWithoutItsLastWordsSaysWhereItStopped() throws {
        let quit = Meeting(created: now, appName: "Zoom", segments: [MeetingSegment(source: .you, offset: 10, text: "Last words")],
                           stretches: [MeetingStretch(start: 0, sources: [.you, .others], end: 60, ended: .quitBeforeDrain)], state: .finished)
        XCTAssertEqual(quit.gaps, [])
        XCTAssertEqual(quit.stop, MeetingStop(at: 60, reason: .quitBeforeDrain))
        XCTAssertTrue(MeetingExport.markdown(quit, dictionary: .empty, timeZone: utc).hasSuffix("""
            **[00:00:10] You:** Last words

            *— Stopped at 00:01:00 · Within quit before the last seconds were transcribed —*

            """))

        var open = MeetingStretch(start: 0, sources: [.you])
        open.lastCheckpoint = 50
        let crashed = Meeting(created: now, appName: Meeting.microphoneOnly, segments: [MeetingSegment(source: .you, offset: 10, text: "Before")], stretches: [open])
        let recovered = try XCTUnwrap(MeetingRecovery.recover([crashed]).recovered.first)
        XCTAssertEqual(recovered.stop, MeetingStop(at: 50, reason: .unexpectedExit))
        XCTAssertTrue(MeetingExport.markdown(recovered, dictionary: .empty, timeZone: utc).contains("*— Stopped at 00:00:50 · Within closed unexpectedly; the last words may be missing —*"))

        var speechError = quit
        speechError.stretches = [MeetingStretch(start: 0, sources: [.you], end: 40, ended: .speechError)]
        XCTAssertEqual(speechError.stop?.detail(appName: "Zoom"), "a speech processing error; the last words may be missing")
    }

    func testOnlyAFinishedMeetingThatLostItsLastWordsGetsAStopMarker() {
        let continued = Meeting(created: now, appName: "Zoom", stretches: [MeetingStretch(start: 0, sources: [.you], end: 60, ended: .unexpectedExit),
                                                                           MeetingStretch(start: 90, sources: [.you], end: 120, ended: .finished)], state: .finished)
        XCTAssertNil(continued.stop)
        XCTAssertEqual(continued.gaps.map(\.reason), [.unexpectedExit])
        let paused = Meeting(created: now, appName: "Zoom", stretches: [MeetingStretch(start: 0, sources: [.you], end: 60, ended: .speechError)])
        XCTAssertNil(paused.stop)
        for reason in MeetingStretchEnd.allCases {
            let finished = Meeting(created: now, appName: "Zoom", stretches: [MeetingStretch(start: 0, sources: [.you], end: 60, ended: reason)], state: .finished)
            XCTAssertEqual(finished.stop != nil, [.quitBeforeDrain, .unexpectedExit, .speechError].contains(reason), "\(reason)")
            XCTAssertFalse(MeetingExport.markdown(finished, dictionary: .empty, timeZone: utc).contains("Paused"), "\(reason)")
        }
    }

    func testExportFileNameUsesTheTitleAndDateWithSafeCharacters() {
        var meeting = weeklySync
        XCTAssertEqual(MeetingExport.fileName(meeting, timeZone: utc), "Weekly sync 2027-01-15.md")
        meeting.title = "Q3/Q4: plan"
        XCTAssertEqual(MeetingExport.fileName(meeting, timeZone: utc), "Q3-Q4- plan 2027-01-15.md")
        meeting.title = ".hidden"
        XCTAssertEqual(MeetingExport.fileName(meeting, timeZone: utc), "hidden 2027-01-15.md")
        meeting.title = ""
        XCTAssertEqual(MeetingExport.fileName(meeting, timeZone: utc), "Zoom meeting 2027-01-15.md")
    }

    // MARK: Search

    func testSearchMatchesTitleNotesAndEitherSpellingIgnoringCaseAndAccents() {
        let others = Meeting(title: "Standup", created: now, appName: "Zoom", segments: [MeetingSegment(source: .others, offset: 1, text: "Ask shivon first.")])
        let meetings = [weeklySync, Meeting(title: "Café plan", created: now, appName: "Zoom"),
                        Meeting(created: now, appName: "Zoom", notes: "Errands"), others]
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "cafe", dictionary: words).map(\.title), ["Café plan"])
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "ERRANDS", dictionary: words).count, 1)
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "happy to", dictionary: words).map(\.title), ["Weekly sync"])
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "gira", dictionary: words).map(\.title), ["Weekly sync"])
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "with jira", dictionary: words).map(\.title), ["Weekly sync"])
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "SIOBHÁN", dictionary: words).map(\.title), ["Standup"])
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "shivon", dictionary: words).map(\.title), ["Standup"])
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "jira", dictionary: .empty).count, 0)
        XCTAssertEqual(MeetingSearch.matching(meetings, query: " ", dictionary: words).count, 4)
        XCTAssertEqual(MeetingSearch.matching(meetings, query: "absent", dictionary: words).count, 0)
    }

    // MARK: Recovery

    func testRecoveryClosesTheOpenStretchAtItsLastKnownPoint() {
        var stretch = MeetingStretch(start: 90, sources: [.you, .others])
        stretch.lastCheckpoint = 130
        let open = Meeting(created: now, appName: "Zoom",
                           segments: [MeetingSegment(source: .you, offset: 10, text: "Early"), MeetingSegment(source: .others, offset: 140, text: "Late")],
                           stretches: [MeetingStretch(start: 0, sources: [.you, .others], end: 60, ended: .pauseButton), stretch])
        let result = MeetingRecovery.recover([open])
        XCTAssertEqual(result.deleted, [])
        let recovered = result.recovered.first
        XCTAssertEqual(recovered?.state, .finished)
        XCTAssertEqual(recovered?.stretches.map(\.end), [60, 140])
        XCTAssertEqual(recovered?.stretches.map(\.ended), [.pauseButton, .unexpectedExit])

        var quiet = open
        quiet.segments = [MeetingSegment(source: .you, offset: 10, text: "Early")]
        XCTAssertEqual(MeetingRecovery.recover([quiet]).recovered.first?.stretches.last?.end, 130)
    }

    func testRecoveryOfAMeetingThatCrashedWhilePausedKeepsTheRealReason() {
        let paused = Meeting(created: now, appName: "Zoom", segments: [MeetingSegment(source: .you, offset: 10, text: "Before")],
                             stretches: [MeetingStretch(start: 0, sources: [.you, .others], end: 60, ended: .callEnded)])
        let recovered = MeetingRecovery.recover([paused]).recovered
        XCTAssertEqual(recovered.map(\.state), [.finished])
        XCTAssertEqual(recovered.first?.stretches, paused.stretches)
    }

    func testRecoveryDeletesOnlyEmptyOpenMeetingsAndLeavesFinishedOnesAlone() {
        let empty = Meeting(title: " ", created: now, appName: "Zoom", notes: "\n", stretches: [MeetingStretch(start: 0, sources: [.you])])
        let titled = Meeting(title: "Planning", created: now, appName: "Zoom", stretches: [MeetingStretch(start: 0, sources: [.you])])
        var finished = weeklySync
        finished.state = .finished
        let result = MeetingRecovery.recover([empty, titled, finished])
        XCTAssertEqual(result.deleted, [empty.id])
        XCTAssertEqual(result.recovered.map(\.id), [titled.id])
        XCTAssertEqual(result.recovered.first?.stretches.first?.ended, .unexpectedExit)
        XCTAssertEqual(result.recovered.first?.stretches.first?.end, 0)
    }

    // MARK: Retention

    private func meeting(createdDaysAgo days: Double, lastEnd: TimeInterval, state: MeetingRecordState = .finished) -> Meeting {
        Meeting(created: now.addingTimeInterval(-days * 86_400), appName: "Zoom",
                stretches: [MeetingStretch(start: 0, sources: [.you], end: lastEnd, ended: .finished)], state: state)
    }

    func testRetentionCountsFromTheLastCapture() {
        let old = meeting(createdDaysAgo: 31, lastEnd: 3_600)
        let edge = Meeting(created: now.addingTimeInterval(-30 * 86_400), appName: "Zoom", state: .finished)
        let recent = meeting(createdDaysAgo: 29, lastEnd: 60)
        XCTAssertEqual(DocumentRetention.days30.expired([old, edge, recent], now: now), [old.id, edge.id])
        XCTAssertEqual(DocumentRetention.untilDeleted.expired([old, edge, recent], now: now), [])
        XCTAssertEqual(DocumentRetention.days365.expired([old, edge, recent], now: now), [])
    }

    func testContinuedOldMeetingIsNotExpired() {
        let continued = meeting(createdDaysAgo: 400, lastEnd: 399 * 86_400)
        XCTAssertEqual(continued.lastCapture, now.addingTimeInterval(-86_400))
        XCTAssertEqual(DocumentRetention.days30.expired([continued], now: now), [])
    }

    func testOpenMeetingIsNeverExpired() {
        XCTAssertEqual(DocumentRetention.days30.expired([meeting(createdDaysAgo: 400, lastEnd: 60, state: .open)], now: now), [])
    }

    func testRetentionChoiceDefaultsToUntilDeleted() {
        XCTAssertEqual(DocumentRetention.restored(from: nil), .untilDeleted)
        XCTAssertEqual(DocumentRetention.restored(from: "days90"), .days90)
        XCTAssertEqual(DocumentRetention.restored(from: "forever"), .untilDeleted)
        XCTAssertEqual(DocumentRetention.allCases.map(\.interval), [nil, 30 * 86_400, 90 * 86_400, 365 * 86_400])
        let id = UUID()
        XCTAssertEqual(DocumentRetention.days90.expired([(id, now.addingTimeInterval(-90 * 86_400))], now: now), [id])
        XCTAssertEqual(DocumentRetention.days90.expired([(id, now.addingTimeInterval(-90 * 86_400 + 1))], now: now), [])
    }
}
