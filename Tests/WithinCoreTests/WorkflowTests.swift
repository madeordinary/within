import XCTest
@testable import WithinCore

final class WorkflowTests: XCTestCase {
    func testCancellationInvalidatesEveryLateResult() {
        var state = SessionState()
        let first = state.begin()!
        XCTAssertTrue(state.recording(first))
        state.cancel()
        let second = state.begin()!
        XCTAssertFalse(state.stopped(first))
        XCTAssertFalse(state.recover("Late words", id: first))
        state.finish(first)
        XCTAssertTrue(state.isCurrent(second))
        XCTAssertEqual(state.phase, .preparing)
    }
    func testRecoveryCannotBeReplaced() {
        var state = SessionState()
        let id = state.begin()!
        _ = state.recording(id); _ = state.stopped(id)
        XCTAssertTrue(state.recover("Keep", id: id))
        XCTAssertNil(state.begin())
        XCTAssertEqual(state.transcript, "Keep")
        state.finish(id)
        XCTAssertNil(state.transcript)
    }
    func testFormattingIsDeterministicAndRejectsNonSpeech() {
        XCTAssertEqual(TranscriptFormatting.clean("<|nospeech|> . \n"), "")
        XCTAssertEqual(TranscriptFormatting.clean("  Hello\t  world.  "), "Hello world.")
        XCTAssertEqual(TranscriptFormatting.clean("Keep my words, exactly!"), "Keep my words, exactly!")
    }
    func testRingWrapPreservesOrderAndRejectsOverflow() {
        let ring = AudioRing(capacity: 4, sampleLimit: 20)
        [Float(1),2,3].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 3), 0) }
        XCTAssertEqual(ring.drain(upTo: 2), [1,2])
        [Float(4),5,6].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 3), 0) }
        XCTAssertEqual(ring.pending, 4)
        [Float(7)].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 1), 2) }
        XCTAssertEqual(ring.drain(upTo: 10), [3,4,5,6])
        XCTAssertEqual(ring.samplesCaptured, 6)
    }
    func testDurationLimitIsMeasuredInSamples() {
        let ring = AudioRing(capacity: 10, sampleLimit: 3)
        [Float(1),2,3,4,5].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 5), 3) }
        XCTAssertEqual(ring.samplesCaptured, 3)
        XCTAssertEqual(ring.drain(upTo: 10), [1,2,3])
        ring.close()
        XCTAssertEqual(ring.status, 3)
    }
    func testClosedRingRejectsNewAudio() {
        let ring = AudioRing(capacity: 8, sampleLimit: 20)
        ring.close()
        [Float(1)].withUnsafeBufferPointer { XCTAssertEqual(ring.push($0.baseAddress!, count: 1), 1) }
        XCTAssertEqual(ring.pending, 0)
    }
    func testStopDiagnosticsPreserveFirstCauseUntilNextSession() {
        let held = ShortcutChordState(controlHeld: true, shiftHeld: true, triggerHeld: true)
        var tracker = RecordingStopTracker()
        tracker.record(RecordingStopDiagnostic(cause: .hotKeyRelease, phase: .preparing,
            hardwareChord: held, sessionChord: held, eventListeningAllowed: true))
        tracker.record(RecordingStopDiagnostic(cause: .pipelineError, phase: .transcribing,
            hardwareChord: held, sessionChord: held, eventListeningAllowed: true))
        XCTAssertEqual(tracker.lastStop?.cause, .hotKeyRelease)
        XCTAssertEqual(tracker.lastStop?.phase, "preparing")
        tracker.begin()
        XCTAssertNil(tracker.lastStop)
        tracker.record(RecordingStopDiagnostic(cause: .holdWatchdog, phase: .recording,
            hardwareChord: held, sessionChord: held, eventListeningAllowed: false))
        XCTAssertEqual(tracker.lastStop?.cause, .holdWatchdog)
    }
    func testStopDiagnosticExportContainsOnlyClosedNonContentFields() throws {
        let held = ShortcutChordState(controlHeld: true, shiftHeld: true, triggerHeld: true)
        let released = ShortcutChordState(controlHeld: true, shiftHeld: true, triggerHeld: false)
        let observation = RecordingStopDiagnostic(cause: .holdWatchdog, phase: .recording,
            hardwareChord: released, sessionChord: held, eventListeningAllowed: false,
            audioConfiguration: AudioConfigurationObservation(engineRunning: true,
                deviceUnchanged: true, deviceAvailable: true, inputFormatUnchanged: true, tapFormatUnchanged: true))
        let report = DiagnosticsReport(appVersion: "test", macOSVersion: "test", architecture: "arm64",
            microphonePermission: "allowed", accessibilityPermission: true, shortcutRegistered: true,
            microphoneSelection: "system_default", modelInstalled: true, modelRevision: "test",
            lastModelCheck: "passed", lastErrorCode: "none", lastRecordingStop: observation)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.preview().utf8)) as? [String: Any])
        XCTAssertEqual(json["schema"] as? Int, 3)
        XCTAssertEqual(json["telemetry"] as? Bool, false)
        let stop = try XCTUnwrap(json["lastRecordingStop"] as? [String: Any])
        XCTAssertEqual(Set(stop.keys), ["cause", "phase", "hardwareChord", "sessionChord", "eventListeningAllowed", "audioConfiguration"])
        let configuration = try XCTUnwrap(stop["audioConfiguration"] as? [String: Any])
        XCTAssertEqual(Set(configuration.keys), ["engineRunning", "deviceUnchanged", "deviceAvailable", "inputFormatUnchanged", "tapFormatUnchanged"])
        XCTAssertTrue(configuration.values.allSatisfy { $0 is Bool })
        for field in ["hardwareChord", "sessionChord"] {
            let chord = try XCTUnwrap(stop[field] as? [String: Any])
            XCTAssertEqual(Set(chord.keys), ["controlHeld", "shiftHeld", "triggerHeld"])
            XCTAssertTrue(chord.values.allSatisfy { $0 is Bool })
        }
    }
    func testUnchangedRunningInputSurvivesConfigurationNotification() {
        let unchanged = AudioConfigurationObservation(engineRunning: true, deviceUnchanged: true,
            deviceAvailable: true, inputFormatUnchanged: true, tapFormatUnchanged: true)
        XCTAssertFalse(unchanged.requiresStop)
    }
    func testConfigurationChangesAndUnknownDeviceFailClosed() {
        // Each independent loss must stop capture, even when every other property still matches.
        for failingProperty in 0..<5 {
            let change = AudioConfigurationObservation(engineRunning: failingProperty != 0,
                deviceUnchanged: failingProperty != 1, deviceAvailable: failingProperty != 2,
                inputFormatUnchanged: failingProperty != 3, tapFormatUnchanged: failingProperty != 4)
            XCTAssertTrue(change.requiresStop, "Property \(failingProperty) must stop recording")
        }
    }
}
