import XCTest
@testable import WithinCore

final class MeetingHealthTests: XCTestCase {
    private func ring(_ samples: UInt64, status: Int = 0, level: Float = 0.1) -> MeetingRingReading {
        MeetingRingReading(samplesCaptured: samples, status: status, level: level)
    }

    func testNoMicrophoneAudioWithinFiveSecondsFailsTheStart() {
        var health = MeetingHealthMonitor()
        XCTAssertEqual(health.poll(elapsed: 4.9, you: ring(0), others: nil, microphoneAuthorized: true), [])
        XCTAssertEqual(health.poll(elapsed: 5, you: ring(0), others: nil, microphoneAuthorized: true), [.startFailed(.microphoneStalled)])
    }

    func testMicrophoneThatStopsAdvancingForFiveSecondsPauses() {
        var health = MeetingHealthMonitor()
        XCTAssertEqual(health.poll(elapsed: 1, you: ring(4_800), others: nil, microphoneAuthorized: true), [])
        XCTAssertEqual(health.poll(elapsed: 5.9, you: ring(4_800), others: nil, microphoneAuthorized: true), [])
        XCTAssertEqual(health.poll(elapsed: 6, you: ring(4_800), others: nil, microphoneAuthorized: true), [.pause(.microphoneStalled)])
    }

    func testRingStatusPausesBothSourcesOrRollsOver() {
        var behind = MeetingHealthMonitor()
        XCTAssertEqual(behind.poll(elapsed: 1, you: ring(10), others: ring(10, status: 2), microphoneAuthorized: true), [.pause(.processingFellBehind)])
        var limit = MeetingHealthMonitor()
        XCTAssertEqual(limit.poll(elapsed: 1, you: ring(10, status: 3), others: ring(10), microphoneAuthorized: true), [.rollover])
        var both = MeetingHealthMonitor()
        XCTAssertEqual(both.poll(elapsed: 1, you: ring(10, status: 3), others: ring(10, status: 2), microphoneAuthorized: true), [.pause(.processingFellBehind)])
        var closed = MeetingHealthMonitor()
        XCTAssertEqual(closed.poll(elapsed: 1, you: ring(10, status: 1), others: nil, microphoneAuthorized: true), [])
    }

    func testRevokedMicrophonePermissionPauses() {
        var health = MeetingHealthMonitor()
        XCTAssertEqual(health.poll(elapsed: 1, you: ring(10), others: nil, microphoneAuthorized: false), [.pause(.microphonePermission)])
    }

    func testOthersStartAndStallRulesRunOnlyWhenTheAppDeliversSilence() {
        var unproven = MeetingHealthMonitor()
        XCTAssertEqual(unproven.poll(elapsed: 1, you: ring(10), others: ring(0), microphoneAuthorized: true), [])
        XCTAssertEqual(unproven.poll(elapsed: 10, you: ring(20), others: ring(0), microphoneAuthorized: true), [])
        var proven = MeetingHealthMonitor(othersDeliversSilence: true)
        XCTAssertEqual(proven.poll(elapsed: 5, you: ring(10), others: ring(0), microphoneAuthorized: true), [.startFailed(.computerAudioStalled)])
        var stalled = MeetingHealthMonitor(othersDeliversSilence: true)
        XCTAssertEqual(stalled.poll(elapsed: 1, you: ring(10), others: ring(10), microphoneAuthorized: true), [])
        XCTAssertEqual(stalled.poll(elapsed: 6, you: ring(20), others: ring(10), microphoneAuthorized: true), [.pause(.computerAudioStalled)])
    }

    func testOnlyZoomDeliversSilenceSoFar() {
        XCTAssertTrue(MeetingHealthMonitor.deliversSilence(for: .zoom))
        XCTAssertFalse(MeetingHealthMonitor.deliversSilence(for: .teams))
        XCTAssertFalse(MeetingHealthMonitor.deliversSilence(for: nil))
        XCTAssertFalse(MeetingHealthMonitor.deliversSilence(for: MeetingApp(name: "Synthetic app", bundlePrefixes: ["us.zoom.", "com.example."])))
        XCTAssertFalse(MeetingHealthMonitor().othersDeliversSilence)
    }

    func testZoomMeetingFailsWithoutFirstAudioAndPausesWhenItsSoundStalls() {
        var silent = MeetingHealthMonitor(othersDeliversSilence: MeetingHealthMonitor.deliversSilence(for: .zoom))
        XCTAssertEqual(silent.poll(elapsed: 4.9, you: ring(10), others: ring(0), microphoneAuthorized: true), [])
        XCTAssertEqual(silent.poll(elapsed: 5, you: ring(20), others: ring(0), microphoneAuthorized: true), [.startFailed(.computerAudioStalled)])
        var stalled = MeetingHealthMonitor(othersDeliversSilence: MeetingHealthMonitor.deliversSilence(for: .zoom))
        XCTAssertEqual(stalled.poll(elapsed: 1, you: ring(10), others: ring(4_800, level: 0), microphoneAuthorized: true), [])
        XCTAssertEqual(stalled.poll(elapsed: 5.9, you: ring(20), others: ring(4_800, level: 0), microphoneAuthorized: true), [])
        XCTAssertEqual(stalled.poll(elapsed: 6, you: ring(30), others: ring(4_800, level: 0), microphoneAuthorized: true), [.pause(.computerAudioStalled)])
    }

    func testOtherAppsAndMicrophoneOnlyMeetingsNeverStopForTheAppSound() {
        for app in [MeetingApp.teams, nil] {
            var health = MeetingHealthMonitor(othersDeliversSilence: MeetingHealthMonitor.deliversSilence(for: app))
            XCTAssertEqual(health.poll(elapsed: 5, you: ring(10), others: app == nil ? nil : ring(0), microphoneAuthorized: true), [])
            XCTAssertEqual(health.poll(elapsed: 20, you: ring(20), others: app == nil ? nil : ring(0), microphoneAuthorized: true), [])
            XCTAssertEqual(health.poll(elapsed: 25, you: ring(30), others: app == nil ? nil : ring(4_800), microphoneAuthorized: true), [])
            XCTAssertEqual(health.poll(elapsed: 31, you: ring(40), others: app == nil ? nil : ring(4_800), microphoneAuthorized: true), [])
        }
    }

    func testQuietOtherSideIsOnlyAnAdvisoryNeverAPause() {
        var health = MeetingHealthMonitor()
        var verdicts: [MeetingHealthVerdict] = []
        for tenth in 1...6_000 {
            let elapsed = Double(tenth) / 10
            verdicts += health.poll(elapsed: elapsed, you: ring(UInt64(tenth) * 4_800), others: ring(UInt64(tenth) * 4_800, level: 0), microphoneAuthorized: true)
        }
        XCTAssertEqual(verdicts, [.quiet(.others)])
        XCTAssertEqual(health.poll(elapsed: 600.1, you: ring(3_000_000), others: ring(3_000_000, level: 0.2), microphoneAuthorized: true), [.heard(.others)])
    }

    func testOtherSideDeliveringNothingCountsAsQuiet() {
        var health = MeetingHealthMonitor()
        _ = health.poll(elapsed: 1, you: ring(10), others: ring(500, level: 0.3), microphoneAuthorized: true)
        XCTAssertEqual(health.poll(elapsed: 2, you: ring(20), others: ring(500, level: 0.3), microphoneAuthorized: true), [])
        XCTAssertEqual(health.poll(elapsed: 31.5, you: ring(30), others: ring(500, level: 0.3), microphoneAuthorized: true), [])
        XCTAssertEqual(health.poll(elapsed: 32, you: ring(40), others: ring(500, level: 0.3), microphoneAuthorized: true), [.quiet(.others)])
    }

    // MARK: Call end

    func testCallEndsAfterThreeReadingsWithoutTheMicrophone() {
        var call = MeetingCallMonitor(app: .zoom)
        XCTAssertFalse(call.observe(usingMicrophone: true))
        XCTAssertFalse(call.observe(usingMicrophone: false))
        XCTAssertFalse(call.observe(usingMicrophone: false))
        XCTAssertFalse(call.observe(usingMicrophone: true))
        for _ in 0..<2 { XCTAssertFalse(call.observe(usingMicrophone: false)) }
        XCTAssertTrue(call.observe(usingMicrophone: false))
        XCTAssertFalse(call.observe(usingMicrophone: false))
        XCTAssertEqual(MeetingCallMonitor.endConfirmations, 3)
    }

    func testNoCallEndWithoutACallSeenFirst() {
        var call = MeetingCallMonitor(app: .teams)
        for _ in 0..<10 { XCTAssertFalse(call.observe(usingMicrophone: false)) }
    }

    func testCallEndIsIndependentOfReminderState() {
        let inCall = [AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: true), AudioClientSnapshot(bundleID: "com.microsoft.teams2", runningInput: false)]
        var reminders = MeetingDetector(enabled: true)
        var call = MeetingCallMonitor(app: .zoom)
        _ = reminders.observe(inCall, now: Date(timeIntervalSince1970: 1_800_000_000), captureActive: false)
        reminders.dismiss(.zoom)
        reminders.enabled = false
        XCTAssertFalse(call.observe(inCall))
        let ends = (0..<3).map { _ in call.observe([AudioClientSnapshot(bundleID: "us.zoom.xos", runningInput: false)]) }
        XCTAssertEqual(ends, [false, false, true])
        XCTAssertEqual(reminders.observe([], now: Date(timeIntervalSince1970: 1_800_000_000), captureActive: false), [])
    }
}
