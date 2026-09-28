import XCTest
@testable import WithinCore

final class OutputMuteTests: XCTestCase {
    private let me = "com.madeordinary.Within"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func client(_ id: String, input: Bool = false, output: Bool = false) -> AudioClientSnapshot {
        AudioClientSnapshot(bundleID: id, runningInput: input, runningOutput: output)
    }

    func testMutesOnlyWhenEnabledAndAnotherAppIsPlaying() {
        let youtube = [client("com.google.Chrome.helper", output: true), client(me, input: true)]
        XCTAssertTrue(OutputMutePolicy.shouldMute(enabled: true, clients: youtube, selfBundleID: me, deviceAlreadyMuted: false))
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: false, clients: youtube, selfBundleID: me, deviceAlreadyMuted: false))
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: true, clients: [client(me, input: true, output: true)], selfBundleID: me, deviceAlreadyMuted: false))
    }

    func testNeverMutesDuringACallOrWhenAlreadyMuted() {
        let call = [client("us.zoom.xos", input: true, output: true), client("com.spotify.client", output: true)]
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: true, clients: call, selfBundleID: me, deviceAlreadyMuted: false))
        let facetime = [client("com.apple.FaceTime", input: true, output: true)]
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: true, clients: facetime, selfBundleID: me, deviceAlreadyMuted: false))
        let music = [client("com.spotify.client", output: true)]
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: true, clients: music, selfBundleID: me, deviceAlreadyMuted: true))
    }

    func testAppleSystemServicesWithInputAreNotCalls() {
        let clients = [client("com.apple.corespeechd", input: true), client("org.mozilla.firefox", output: true)]
        XCTAssertTrue(OutputMutePolicy.shouldMute(enabled: true, clients: clients, selfBundleID: me, deviceAlreadyMuted: false))
    }

    func testRestoresOnlyWhatWithinMutedAndIsStillMuted() {
        let record = OutputMuteRecord(deviceUID: "speakers", mutedAt: now)
        XCTAssertTrue(OutputMutePolicy.shouldRestore(record: record, deviceStillMuted: true))
        XCTAssertFalse(OutputMutePolicy.shouldRestore(record: record, deviceStillMuted: false), "the user already unmuted")
        XCTAssertFalse(OutputMutePolicy.shouldRestore(record: record, deviceStillMuted: nil), "the device is gone")
        XCTAssertFalse(OutputMutePolicy.shouldRestore(record: nil, deviceStillMuted: true), "Within did not mute it")
    }

    func testLaunchRecoveryIsRecentAndBestEffort() {
        let record = OutputMuteRecord(deviceUID: "speakers", mutedAt: now)
        XCTAssertTrue(OutputMutePolicy.shouldRecoverAtLaunch(record: record, deviceStillMuted: true, now: now.addingTimeInterval(120)))
        XCTAssertFalse(OutputMutePolicy.shouldRecoverAtLaunch(record: record, deviceStillMuted: true, now: now.addingTimeInterval(3600)))
        XCTAssertFalse(OutputMutePolicy.shouldRecoverAtLaunch(record: record, deviceStillMuted: false, now: now.addingTimeInterval(60)))
    }
}
