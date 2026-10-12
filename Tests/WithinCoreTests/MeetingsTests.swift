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

    // Changed deliberately in Stage A: stretches and state are required, and no released build wrote a meeting.
    func testStoredMeetingHasOnlyTextFields() throws {
        let meeting = Meeting(created: now, appName: "Zoom", segments: [MeetingSegment(source: .you, offset: 1, text: "Hi")])
        XCTAssertEqual(try keys(meeting), ["id", "title", "created", "modified", "appName", "segments", "notes", "stretches", "state"])
        XCTAssertEqual(meeting.displayTitle, "Zoom meeting")
    }

    func testClosedAndOpenStretchesStoreOnlyTimesSourcesAndReason() throws {
        let closed = MeetingStretch(start: 0, sources: [.you, .others], end: 60, ended: .lockOrSleep)
        XCTAssertEqual(try keys(closed), ["id", "start", "end", "lastCheckpoint", "sources", "ended"])
        XCTAssertEqual(try keys(MeetingStretch(start: 90, sources: [.you])), ["id", "start", "lastCheckpoint", "sources"])
    }

    func testSegmentStoresOnlyTheTranscription() throws {
        XCTAssertEqual(try keys(MeetingSegment(source: .you, offset: 1, text: "Hi")), ["id", "source", "offset", "text"])
    }

    /// Before the dictionary was applied on read, a changed turn stored its fixed text with the transcription in
    /// `original`. Such a file still decodes, keeping the transcription, and is saved back without the key.
    func testSegmentWithAnEarlierOriginalKeyKeepsTheTranscription() throws {
        let earlier = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","source":"you","offset":1,"text":"Synthetic Wurd","original":"synthetic wurd"}"#
        let segment = try JSONDecoder().decode(MeetingSegment.self, from: Data(earlier.utf8))
        XCTAssertEqual(segment, MeetingSegment(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FE")!, source: .you, offset: 1, text: "synthetic wurd"))
        XCTAssertEqual(try keys(segment), ["id", "source", "offset", "text"])
        let plain = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","source":"others","offset":2,"text":"as transcribed"}"#
        XCTAssertEqual(try JSONDecoder().decode(MeetingSegment.self, from: Data(plain.utf8)).text, "as transcribed")
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingSegment.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","source":"you","offset":1,"original":"x"}"#.utf8)))
    }

    /// Builds 12 to 17 had this shape but never created a meeting store or wrote a meeting file, so stretches
    /// and state are required and no compatibility decoding exists.
    func testMeetingInTheShapeBeforeStretchesIsNotDecoded() {
        let earlier = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"","created":810000000,"modified":810000000,"appName":"Zoom","segments":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","source":"you","offset":1,"text":"Hi"}],"notes":""}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Meeting.self, from: Data(earlier.utf8)))
    }

    func testMeetingRoundTripsWithStretchesAndState() throws {
        var meeting = Meeting(title: "Weekly sync", created: now, appName: "Zoom",
                              segments: [MeetingSegment(source: .you, offset: 3, text: "gira")], notes: "Typed",
                              stretches: [MeetingStretch(start: 0, sources: [.you, .others], end: 40, ended: .pauseButton), MeetingStretch(start: 70, sources: [.you])])
        meeting.state = .finished
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting)), meeting)
    }

    func testStretchEndsAreAClosedSetOfStableNames() {
        XCTAssertEqual(MeetingStretchEnd.allCases.map(\.rawValue), [
            "finished", "pause_button", "lock_or_sleep", "user_switched", "call_ended", "microphone_lost", "microphone_stalled",
            "microphone_permission", "computer_audio_lost", "computer_audio_changed", "computer_audio_stalled",
            "processing_fell_behind", "duration_limit", "speech_error", "quit", "quit_before_drain", "unexpected_exit"])
    }

    func testUntitledMeetingIsNamedByItsAppOrJustMeeting() {
        XCTAssertEqual(Meeting(title: "  Plan ", created: now, appName: "Zoom").displayTitle, "Plan")
        XCTAssertEqual(Meeting(created: now, appName: "Microsoft Teams").displayTitle, "Microsoft Teams meeting")
        XCTAssertEqual(Meeting(created: now, appName: Meeting.microphoneOnly).displayTitle, "Meeting")
    }

    // MARK: Builder hardening

    func testRespacedPunctuationReanchorsWithoutLosingOrRepeatingWords() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "I will finish it today .", at: 1)
        builder.update(.others, transcript: "Great", at: 2)
        builder.update(.you, transcript: "I will finish it today. Thanks", at: 3)
        XCTAssertEqual(builder.segments.map(\.text), ["I will finish it today .", "Great", "Thanks"])
    }

    func testRetiredTrailingWordRegrowsInTheOpenTurn() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "we ship on Friday", at: 1)
        builder.update(.you, transcript: "we ship on", at: 2)
        XCTAssertEqual(builder.segments.map(\.text), ["we ship on"])
        builder.update(.you, transcript: "we ship on Friday morning", at: 3)
        XCTAssertEqual(builder.segments.map(\.text), ["we ship on Friday morning"])
        XCTAssertEqual(builder.segments.map(\.offset), [1])
    }

    func testWordRetiredAfterItsTurnClosedLeavesTheNextTurnWhole() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "we ship today", at: 1)
        builder.update(.others, transcript: "Sounds good", at: 2)
        builder.update(.you, transcript: "we ship", at: 3)
        XCTAssertEqual(builder.segments.count, 2)
        builder.update(.you, transcript: "we ship tomorrow instead", at: 4)
        XCTAssertEqual(builder.segments.map(\.text), ["we ship today", "Sounds good", "tomorrow instead"])
    }

    func testTurnNeverStartsMidWord() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "the libr", at: 1)
        builder.update(.others, transcript: "Yes", at: 2)
        builder.update(.you, transcript: "the library is quiet", at: 3)
        XCTAssertEqual(builder.segments.map(\.text), ["the libr", "Yes", "library is quiet"])
    }

    func testJoinedTokenAtTheTurnStartStaysWhole() {
        let cases = [("it costs 3", "it costs 3,000 dollars", "3,000 dollars"), ("meet at 3", "meet at 3:30 today", "3:30 today"),
                     ("it grew 3", "it grew 3.5 million", "3.5 million"), ("visit example", "visit example.com today", "example.com today"),
                     ("in the U", "in the U.S. office", "U.S. office"), ("in the U.", "in the U.S. office", "U.S. office"),
                     ("we don", "we don't know", "don't know"), ("over here", "over here, sounds good", "sounds good"),
                     ("done at 3", "done at 3. Thanks", "Thanks")]
        for (closed, regrown, turn) in cases {
            var builder = MeetingTranscriptBuilder()
            builder.update(.you, transcript: closed, at: 1)
            builder.update(.others, transcript: "Okay", at: 2)
            builder.update(.you, transcript: regrown, at: 3)
            XCTAssertEqual(builder.segments.map(\.text), [closed, "Okay", turn], regrown)
        }
    }

    func testWordThatDivergesAfterTheTurnClosedIsKeptWhole() {
        for (closed, regrown, turn) in [("we ship today", "we ship to Boston", "to Boston"), ("we use online", "we use on line tools", "on line tools"),
                                         ("hello world", "hello there", "there")] {
            var builder = MeetingTranscriptBuilder()
            builder.update(.you, transcript: closed, at: 1)
            builder.update(.others, transcript: "Okay", at: 2)
            builder.update(.you, transcript: regrown, at: 3)
            XCTAssertEqual(builder.segments.map(\.text), [closed, "Okay", turn], regrown)
        }
    }

    func testFinalFlushAfterAlternatingTurnsAddsOnlyTheNewWords() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.others, transcript: "Thanks for joining", at: 2)
        builder.update(.you, transcript: "Happy to be here", at: 5)
        builder.update(.others, transcript: "Thanks for joining. Let's start", at: 7)
        builder.update(.you, transcript: "Happy to be here . Sounds good", at: 9)
        builder.update(.others, transcript: "Thanks for joining . Let's start with the plan.", at: 10)
        XCTAssertEqual(builder.segments.map(\.text), ["Thanks for joining", "Happy to be here", "Let's start", "Sounds good", "with the plan."])
        XCTAssertEqual(builder.segments.map(\.source), [.others, .you, .others, .you, .others])
    }

    func testOpenTurnKeepsItsStartTrimmedAsItGrows() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.others, transcript: "Welcome", at: 1)
        builder.update(.you, transcript: "Hi", at: 2)
        builder.update(.others, transcript: "Welcome. Agenda first", at: 3)
        builder.update(.others, transcript: "Welcome. Agenda first, then questions", at: 4)
        XCTAssertEqual(builder.segments.last?.text, "Agenda first, then questions")
    }

    func testUpdateFromBeforeAGapChangesNothing() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "Before the lock", at: 1, stretch: builder.stretch)
        let earlier = builder.stretch
        builder.markGap()
        builder.update(.you, transcript: "Before the lock and a late flush", at: 30, stretch: earlier)
        XCTAssertEqual(builder.segments.map(\.text), ["Before the lock"])
        builder.update(.you, transcript: "After unlocking", at: 40, stretch: builder.stretch)
        XCTAssertEqual(builder.segments.map(\.text), ["Before the lock", "After unlocking"])
    }

    func testClosingPunctuationInAnyScriptIsTrimmedButOpeningMarksStay() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.others, transcript: "Hola", at: 1)
        builder.update(.you, transcript: "Hi", at: 2)
        builder.update(.others, transcript: "Hola… ¿Qué tal?", at: 3)
        builder.update(.you, transcript: "Hi」 (quietly) fine", at: 4)
        XCTAssertEqual(builder.segments.map(\.text), ["Hola", "Hi", "¿Qué tal?", "(quietly) fine"])
    }

    func testOpenTurnWhoseWordsWereWithdrawnIsRemoved() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.others, transcript: "Morning", at: 1)
        builder.update(.you, transcript: "Hello", at: 2)
        builder.update(.you, transcript: "", at: 3)
        XCTAssertEqual(builder.segments.map(\.text), ["Morning"])
        builder.update(.others, transcript: "Morning all", at: 4)
        builder.update(.you, transcript: "Hello there", at: 5)
        XCTAssertEqual(builder.segments.map(\.text), ["Morning", "all", "Hello there"])
    }

    // MARK: Personal dictionary in meetings

    private func dictionary(_ writeAs: String, _ heardAs: String) -> DictionaryMatcher {
        DictionaryMatcher(PersonalDictionary(entries: [DictionaryEntry(heardAs: [heardAs], writeAs: writeAs, created: now)]))
    }

    private func shown(_ builder: MeetingTranscriptBuilder, _ words: DictionaryMatcher) -> [String] {
        builder.segments.map { MeetingSpellings.turn($0, dictionary: words).text }
    }

    func testStoredSegmentTextStaysRaw() {
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "I moved it to gira", at: 1)
        builder.update(.others, transcript: "check gira", at: 2)
        builder.update(.you, transcript: "I moved it to gira. Done", at: 3)
        XCTAssertEqual(builder.segments.map(\.text), ["I moved it to gira", "check gira", "Done"])
    }

    func testYouAndOthersTurnsAreShownInYourSpellings() {
        let meeting = Meeting(created: now, appName: "Zoom", segments: [MeetingSegment(source: .you, offset: 1, text: "I moved it to gira"),
                                                                       MeetingSegment(source: .others, offset: 2, text: "check gira and gira"),
                                                                       MeetingSegment(source: .others, offset: 3, text: "No change here")])
        let words = dictionary("Jira", "gira")
        let turns = meeting.segments.map { MeetingSpellings.turn($0, dictionary: words) }
        XCTAssertEqual(turns.map(\.text), ["I moved it to Jira", "check Jira and Jira", "No change here"])
        XCTAssertEqual(turns.map(\.original), meeting.segments.map(\.text))
        XCTAssertEqual(turns.map(\.changes.count), [1, 2, 0])
        XCTAssertEqual(MeetingSpellings.fixedTurns(in: meeting, dictionary: words), 2)
    }

    func testEditingTheDictionaryChangesHowAMeetingReads() {
        let segment = MeetingSegment(source: .others, offset: 1, text: "ask shivon about gira")
        let meeting = Meeting(created: now, appName: "Zoom", segments: [segment])
        XCTAssertEqual(MeetingSpellings.turn(segment, dictionary: dictionary("Jira", "gira")).text, "ask shivon about Jira")
        XCTAssertEqual(MeetingSpellings.turn(segment, dictionary: dictionary("Siobhan", "shivon")).text, "ask Siobhan about gira")
        XCTAssertEqual(MeetingSpellings.turn(segment, dictionary: .empty), DictionaryResult(unchanged: "ask shivon about gira"))
        XCTAssertEqual(MeetingSpellings.fixedTurns(in: meeting, dictionary: .empty), 0)
        XCTAssertEqual(MeetingSpellings.fixedTurns(in: meeting, dictionary: DictionaryMatcher(PersonalDictionary(enabled: false, entries: [
            DictionaryEntry(heardAs: ["gira"], writeAs: "Jira", created: now)]))), 0)
    }

    func testTurnStartingAfterAnotherTurnMatchesAPhraseAtItsStart() {
        let words = dictionary("Jira", "gira")
        var builder = MeetingTranscriptBuilder()
        builder.update(.you, transcript: "we moved it to gi", at: 1)
        builder.update(.others, transcript: "Okay", at: 2)
        builder.update(.you, transcript: "we moved it to gira today", at: 3)
        builder.update(.others, transcript: "Okay. gira board is ready", at: 4)
        XCTAssertEqual(builder.segments.map(\.text), ["we moved it to gi", "Okay", "gira today", "gira board is ready"])
        XCTAssertEqual(shown(builder, words), ["we moved it to gi", "Okay", "Jira today", "Jira board is ready"])
    }

    func testDictionaryNeverChangesPartOfAJoinedToken() {
        var builder = MeetingTranscriptBuilder()
        let words = dictionary("COM", "com")
        builder.update(.you, transcript: "visit example", at: 1)
        builder.update(.others, transcript: "Okay", at: 2)
        builder.update(.you, transcript: "visit example.com today", at: 3)
        XCTAssertEqual(shown(builder, words).last, "example.com today")
        XCTAssertFalse(MeetingSpellings.turn(builder.segments[2], dictionary: words).changed)
        builder.update(.you, transcript: "visit example.com today com", at: 4)
        XCTAssertEqual(shown(builder, words).last, "example.com today COM")
    }

    func testPhraseSplitAcrossTurnsNeverMatches() {
        var builder = MeetingTranscriptBuilder()
        let words = dictionary("Synthetic Phrase", "synthetic phrase")
        builder.update(.you, transcript: "a synthetic", at: 1)
        builder.update(.others, transcript: "Go on", at: 2)
        builder.update(.you, transcript: "a synthetic phrase", at: 3)
        XCTAssertEqual(shown(builder, words), ["a synthetic", "Go on", "phrase"])
        XCTAssertEqual(MeetingSpellings.fixedTurns(in: Meeting(created: now, appName: "Zoom", segments: builder.segments), dictionary: words), 0)
        builder.update(.you, transcript: "a synthetic phrase, a synthetic phrase", at: 4)
        XCTAssertEqual(shown(builder, words).last, "phrase, a Synthetic Phrase")
    }

    /// One visible row's cost in a three-hour meeting, and the whole meeting's count; recorded, never gated.
    func testReadingAThreeHourMeetingTimeIsRecorded() {
        let entries = (0..<500).map { DictionaryEntry(heardAs: ["wurd\($0)"], writeAs: "Wurd\($0)", created: now.addingTimeInterval(Double($0))) }
        let words = DictionaryMatcher(PersonalDictionary(entries: entries))
        let segments = (0..<2_000).map { index in
            MeetingSegment(source: index % 2 == 0 ? .you : .others, offset: Double(index) * 5,
                           text: (0..<15).map { "wurd\((index * 15 + $0) % 700)" }.joined(separator: " ") + ".")
        }
        let meeting = Meeting(created: now, appName: "Zoom", segments: segments)
        let expected = (0..<2_000).filter { index in (0..<15).contains { (index * 15 + $0) % 700 < 500 } }.count
        XCTAssertEqual(MeetingSpellings.fixedTurns(in: meeting, dictionary: words), expected)
        XCTAssertEqual(MeetingSpellings.turn(segments[1], dictionary: words).text, "Wurd15 Wurd16 Wurd17 Wurd18 Wurd19 Wurd20 Wurd21 Wurd22 Wurd23 Wurd24 Wurd25 Wurd26 Wurd27 Wurd28 Wurd29.")
        measure {
            _ = MeetingSpellings.turn(segments[1_000], dictionary: words)
            _ = MeetingSpellings.fixedTurns(in: meeting, dictionary: words)
        }
    }

    // MARK: Settled text

    func testTailSettlesAfterOneWindowOfFurtherAudio() {
        var settle = MeetingSettle()
        settle.observe(confirmed: "", volatile: "see you", appendedSeconds: 1, at: 0)
        settle.observe(confirmed: "", volatile: "see you", appendedSeconds: 12.5, at: 12.5)
        XCTAssertFalse(settle.isSettled(at: 12.5))
        settle.observe(confirmed: "", volatile: "see you", appendedSeconds: 0.5, at: 13)
        XCTAssertTrue(settle.isSettled(at: 13))
        XCTAssertEqual(MeetingSettle.audioSeconds, 13)
    }

    func testTailSettlesAfterFifteenSecondsWithoutAudio() {
        var settle = MeetingSettle()
        settle.observe(confirmed: "", volatile: "see you", appendedSeconds: 1, at: 100)
        XCTAssertFalse(settle.isSettled(at: 114.9))
        XCTAssertTrue(settle.isSettled(at: 115))
        XCTAssertEqual(MeetingSettle.wallSeconds, 15)
    }

    func testChangedTailStartsCountingAgain() {
        var settle = MeetingSettle()
        settle.observe(confirmed: "", volatile: "see", appendedSeconds: 10, at: 0)
        settle.observe(confirmed: "", volatile: "see", appendedSeconds: 10, at: 10)
        settle.observe(confirmed: "", volatile: "see you", appendedSeconds: 1, at: 11)
        XCTAssertFalse(settle.isSettled(at: 11))
        XCTAssertFalse(settle.isSettled(at: 25.9))
        XCTAssertFalse(MeetingSettle().isSettled(at: 100))
    }

    func testFedTextNeverGetsShorterThanTheLastSettledText() {
        var settle = MeetingSettle()
        settle.observe(confirmed: "Bye", volatile: "see you soon", appendedSeconds: 1, at: 0)
        XCTAssertEqual(settle.feed(at: 1), "Bye")
        XCTAssertEqual(settle.feed(at: 15), "Bye see you soon")
        settle.observe(confirmed: "Bye", volatile: "see you soon and", appendedSeconds: 1, at: 20)
        XCTAssertEqual(settle.feed(at: 20), "Bye see you soon")
        settle.observe(confirmed: "Bye see you soon", volatile: "and then", appendedSeconds: 1, at: 21)
        XCTAssertEqual(settle.feed(at: 21), "Bye see you soon")
        settle.observe(confirmed: "Bye see you soon and", volatile: "then", appendedSeconds: 1, at: 22)
        XCTAssertEqual(settle.feed(at: 22), "Bye see you soon and")
    }

    func testPromotedTailIsFedOnceBecauseBothPartsComeFromOneReport() {
        var settle = MeetingSettle()
        settle.observe(confirmed: "Bye", volatile: "see you soon", appendedSeconds: 1, at: 0)
        XCTAssertEqual(settle.feed(at: 15), "Bye see you soon")
        settle.observe(confirmed: "Bye see you soon", volatile: "", appendedSeconds: 0.5, at: 15.5)
        XCTAssertEqual(settle.feed(at: 15.5), "Bye see you soon")
        XCTAssertEqual(settle.feed(at: 40), "Bye see you soon")
    }

    // MARK: Detector and reminder

    func testDebounceNeedsConsecutiveReadingsToOfferAndWithdraw() {
        var detector = MeetingDetector(enabled: true, confirmations: 2, withdrawConfirmations: 3)
        let inCall = [AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)]
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe([], now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [.offer(.zoom)])
        XCTAssertEqual(detector.observe([], now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe([], now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        for _ in 0..<2 { XCTAssertEqual(detector.observe([], now: now, captureActive: false), []) }
        XCTAssertEqual(detector.observe([], now: now, captureActive: false), [.withdraw(.zoom)])
    }

    func testTurningRemindersOffAndOnKeepsADismissedCallDismissed() {
        var detector = MeetingDetector(enabled: true)
        let inCall = [AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)]
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [.offer(.zoom)])
        detector.dismiss(.zoom)
        detector.enabled = false
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        detector.enabled = true
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe([], now: now, captureActive: false), [.withdraw(.zoom)])
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [.offer(.zoom)])
    }

    func testCallThatStartedDuringCaptureIsNotOfferedOnceCaptureEnds() {
        var detector = MeetingDetector(enabled: true, confirmations: 2, withdrawConfirmations: 3)
        let inCall = [AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true)]
        for _ in 0..<2 { XCTAssertEqual(detector.observe(inCall, now: now, captureActive: true), []) }
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        for _ in 0..<2 { XCTAssertEqual(detector.observe([], now: now, captureActive: false), []) }
        XCTAssertEqual(detector.observe([], now: now, captureActive: false), [.withdraw(.zoom)])
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [])
        XCTAssertEqual(detector.observe(inCall, now: now, captureActive: false), [.offer(.zoom)])
    }

    func testZoomOnlyDetectorNeverOffersTeams() {
        var detector = MeetingDetector(enabled: true, apps: [.zoom], confirmations: 2, withdrawConfirmations: 3)
        let teams = [AudioClientSnapshot(bundleID: "com.microsoft.teams2", runningInput: true)]
        for _ in 0..<3 { XCTAssertEqual(detector.observe(teams, now: now, captureActive: false), []) }
    }

    func testReminderHidesOnWithdrawLockCaptureStartOrRemindersOff() {
        for (event, effects) in [(MeetingReminderState.Event.withdraw(.zoom), [MeetingReminderState.Effect]()),
                                 (.lockOrSleep, [.dismissCall(.zoom)]), (.captureStarted, [.dismissCall(.zoom)]), (.remindersOff, [])] {
            var reminder = MeetingReminderState()
            _ = reminder.handle(.offer(.zoom, pausedMeeting: false), now: now)
            XCTAssertEqual(reminder.shown, MeetingReminderState.Reminder(app: .zoom, pausedMeeting: false))
            XCTAssertEqual(reminder.handle(event, now: now), effects)
            XCTAssertNil(reminder.shown)
        }
        var other = MeetingReminderState()
        _ = other.handle(.offer(.zoom, pausedMeeting: false), now: now)
        XCTAssertEqual(other.handle(.withdraw(.teams), now: now), [])
        XCTAssertNotNil(other.shown)
    }

    func testDismissAndSnoozeNeverOfferThisCallAgain() {
        var reminder = MeetingReminderState()
        _ = reminder.handle(.offer(.teams, pausedMeeting: false), now: now)
        XCTAssertEqual(reminder.handle(.dismiss, now: now), [.dismissCall(.teams)])
        _ = reminder.handle(.offer(.zoom, pausedMeeting: false), now: now)
        XCTAssertEqual(reminder.handle(.snooze, now: now), [.snooze(until: now.addingTimeInterval(3600)), .dismissCall(.zoom)])
        XCTAssertNil(reminder.shown)
        XCTAssertEqual(reminder.handle(.startNotes, now: now), [])
    }

    func testStartNotesFinishesAPausedMeetingFirst() {
        var reminder = MeetingReminderState()
        _ = reminder.handle(.offer(.zoom, pausedMeeting: true), now: now)
        XCTAssertEqual(reminder.handle(.startNotes, now: now), [.finishPausedMeeting, .startMeeting(.zoom)])
        _ = reminder.handle(.offer(.zoom, pausedMeeting: false), now: now)
        XCTAssertEqual(reminder.handle(.startNotes, now: now), [.startMeeting(.zoom)])
    }

    private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        return Set(object.keys)
    }
}
