import XCTest
@testable import WithinCore

final class MeetingLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    typealias Phase = MeetingLifecycle.Phase
    typealias Event = MeetingLifecycle.Event
    typealias Effect = MeetingLifecycle.Effect

    /// Performs the effects the way the controller will: sources, the record's stretches, and the completion owed.
    private struct Driver {
        var lifecycle: MeetingLifecycle
        var sourcesOn = false
        var record = false, deleted = false, finished = false, savedFinished = false
        var stretches: [MeetingStretchEnd?] = []
        var owed: Int?
        /// The generation of an acknowledged start whose save has not reported yet.
        var saving: Int?
        var rolloverDraining = false
        var violations: [String] = []

        init(finished: Bool = false, titled: Bool = false) {
            lifecycle = MeetingLifecycle(finished: finished)
            lifecycle.holdsContent = titled
            if finished { record = true; self.finished = true; savedFinished = true; stretches = [.finished] }
        }

        @discardableResult mutating func send(_ event: Event, at date: Date) -> [Effect] {
            let before = lifecycle
            let pendingSave = saving
            switch event {
            case .saved(let generation) where generation == saving, .saveFailed(let generation) where generation == saving: saving = nil
            default: break
            }
            let effects = lifecycle.handle(event, at: date)
            for effect in effects { apply(effect) }
            if sourcesOn != lifecycle.sourcesOn { violations.append("sources \(sourcesOn) in \(lifecycle.phase)") }
            // Only a resume, the save of an acknowledged start, or the drain of a rollover nothing interrupted, turns sources on.
            if effects.contains(where: { if case .beginStretch = $0 { return true }; return false }) {
                switch event {
                case .resume: break
                case .saved(let generation) where generation == pendingSave: break
                case .drained where rolloverDraining: break
                default: violations.append("\(event) turned sources on")
                }
            }
            if effects.contains(where: { if case .saveBeforeStart = $0 { return true }; return false }), event != .start(acknowledged: true) {
                violations.append("\(event) started a meeting")
            }
            if effects.contains(.deleteRecord), lifecycle.holdsContent, before.phase != .discarding {
                if case .saveFailed = event {} else { violations.append("\(event) deleted a meeting that holds content") }
            }
            switch event {
            case .rollover where before.phase == .recording && lifecycle.phase == .pausing: rolloverDraining = true
            case .pause, .boundary, .callEnded, .finish, .quit, .discard: rolloverDraining = false
            case .health(.speechError, let generation) where generation == before.generation: rolloverDraining = false
            default: if lifecycle.phase != .pausing { rolloverDraining = false }
            }
            return effects
        }

        mutating func apply(_ effect: Effect) {
            switch effect {
            case .stopSources: sourcesOn = false
            case .saveBeforeStart(let generation):
                saving = generation; record = true; deleted = false; savedFinished = finished
            case .beginStretch:
                if sourcesOn { violations.append("began while sources on") }
                if saving != nil { violations.append("began before its save") }
                sourcesOn = true; record = true; deleted = false; finished = false; stretches.append(nil); owed = nil
            case .drain(let generation), .cancelStretch(let generation): owed = generation
            case .closeStretch(let reason):
                guard stretches.last == .some(nil) else { violations.append("closed without an open stretch"); return }
                stretches[stretches.count - 1] = reason
            case .amendLastStretch(let reason):
                guard let last = stretches.last, last != nil else { violations.append("amended without a closed stretch"); return }
                stretches[stretches.count - 1] = reason
            case .removeStretch:
                guard stretches.last == .some(nil) else { violations.append("removed without an open stretch"); return }
                stretches.removeLast()
            case .markFinished: finished = true
            case .saveRecord: savedFinished = finished
            case .deleteRecord: record = false; deleted = true; stretches = []
            case .requestUnload, .refused: break
            }
        }

        /// Delivers the completion the last drain or cancel owes, and returns what it caused.
        @discardableResult mutating func complete(at date: Date) -> [Effect] {
            var effects: [Effect] = []
            while let generation = owed { owed = nil; effects += send(.drained(generation: generation), at: date) }
            return effects
        }
    }

    private func driver(in phase: Phase, titled: Bool = false) -> Driver {
        var driver = Driver(finished: phase == .finished, titled: titled)
        guard phase != .idle, phase != .finished else { return driver }
        driver.send(.start(acknowledged: true), at: now)
        driver.send(.saved(generation: driver.lifecycle.generation), at: now)
        guard phase != .preparing else { return driver }
        driver.send(.sourcesLive(generation: driver.lifecycle.generation), at: now)
        switch phase {
        case .pausing: driver.send(.pause, at: now)
        case .paused: driver.send(.pause, at: now); driver.complete(at: now)
        case .finishing: driver.send(.finish, at: now)
        case .discarding: driver.send(.discard, at: now)
        default: break
        }
        XCTAssertEqual(driver.lifecycle.phase, phase)
        return driver
    }

    /// A meeting paused at `now`, preparing its second stretch.
    private func resuming(acknowledged: Bool = true, at date: Date? = nil) -> Driver {
        var driver = driver(in: .paused)
        driver.send(.resume(acknowledged: acknowledged), at: date ?? now)
        XCTAssertEqual(driver.lifecycle.phase, .preparing)
        return driver
    }

    /// A stretch that reached its bound, drained, and is starting the next one.
    private func restartingAfterRollover() -> Driver {
        var driver = driver(in: .recording)
        driver.send(.rollover(generation: driver.lifecycle.generation), at: now)
        driver.complete(at: now)
        XCTAssertEqual(driver.lifecycle.phase, .preparing)
        XCTAssertEqual(driver.stretches, [.durationLimit, nil])
        return driver
    }

    private let allPhases: [Phase] = [.idle, .preparing, .recording, .pausing, .paused, .finishing, .discarding, .finished]

    private func stops(_ generation: Int) -> [Event] {
        [.pause, .health(.microphoneStalled, generation: generation), .boundary(.lockOrSleep), .boundary(.userSwitched), .callEnded,
         .sourceLost(.computerAudioLost, generation: generation), .rollover(generation: generation), .startFailed(.microphoneStalled, generation: generation),
         .finish, .quit, .discard]
    }

    // MARK: Starting

    func testStartNeedsAcknowledgmentAndSavesBeforeAnySourceStarts() {
        var lifecycle = MeetingLifecycle()
        XCTAssertEqual(lifecycle.handle(.start(acknowledged: false), at: now), [.refused(.acknowledgmentNeeded)])
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertEqual(lifecycle.handle(.start(acknowledged: true), at: now), [.saveBeforeStart(generation: 1)])
        XCTAssertEqual(lifecycle.phase, .preparing)
        XCTAssertFalse(lifecycle.sourcesOn)
        XCTAssertEqual(lifecycle.handle(.sourcesLive(generation: 1), at: now), [])
        XCTAssertEqual(lifecycle.phase, .preparing)
        XCTAssertEqual(lifecycle.handle(.saved(generation: 1), at: now), [.beginStretch(generation: 1)])
        XCTAssertTrue(lifecycle.sourcesOn)
        XCTAssertEqual(lifecycle.handle(.saved(generation: 1), at: now), [])
        XCTAssertEqual(lifecycle.handle(.sourcesLive(generation: 1), at: now), [])
        XCTAssertEqual(lifecycle.phase, .recording)
    }

    func testFailedFirstSaveRefusesTheStartBeforeAnythingStarts() {
        for titled in [false, true] {
            var driver = Driver(titled: titled)
            driver.send(.start(acknowledged: true), at: now)
            let generation = driver.lifecycle.generation
            // Nothing was ever written, so even a titled record is dropped; setup still holds what was typed.
            XCTAssertEqual(driver.send(.saveFailed(generation: generation), at: now), [.stopSources, .deleteRecord, .refused(.saveFailed)])
            XCTAssertEqual(driver.lifecycle.phase, .idle)
            XCTAssertEqual(driver.send(.saved(generation: generation), at: now), [])
            XCTAssertFalse(driver.sourcesOn)
            XCTAssertEqual(driver.violations, [])
        }
    }

    func testContinuingAFinishedMeetingSavesBeforeAnythingStarts() {
        var driver = driver(in: .finished)
        XCTAssertEqual(driver.send(.start(acknowledged: true), at: now), [.saveBeforeStart(generation: 1)])
        XCTAssertFalse(driver.sourcesOn)
        XCTAssertEqual(driver.send(.saveFailed(generation: 1), at: now), [.stopSources, .refused(.saveFailed)])
        XCTAssertEqual(driver.lifecycle.phase, .finished)
        XCTAssertEqual(driver.stretches, [.finished])
        XCTAssertTrue(driver.savedFinished)

        XCTAssertEqual(driver.send(.start(acknowledged: true), at: now), [.saveBeforeStart(generation: 3)])
        XCTAssertEqual(driver.send(.saved(generation: 3), at: now), [.beginStretch(generation: 3)])
        XCTAssertEqual(driver.stretches, [.finished, nil])
        XCTAssertEqual(driver.violations, [])
    }

    func testStoppingWhileTheFirstSaveIsPendingStartsNothing() {
        for event in [Event.pause, .boundary(.lockOrSleep), .callEnded, .finish, .quit, .discard] {
            var new = Driver()
            new.send(.start(acknowledged: true), at: now)
            let generation = new.lifecycle.generation
            XCTAssertEqual(new.send(event, at: now), [.stopSources, .cancelStretch(generation: generation + 1)], "\(event)")
            XCTAssertEqual(new.send(.saved(generation: generation), at: now), [], "\(event)")
            XCTAssertEqual(new.complete(at: now), [.deleteRecord] + (event == .boundary(.lockOrSleep) ? [.requestUnload] : []), "\(event)")
            XCTAssertEqual(new.lifecycle.phase, .idle, "\(event)")

            var continued = driver(in: .finished)
            continued.send(.start(acknowledged: true), at: now)
            continued.send(event, at: now)
            continued.complete(at: now)
            XCTAssertEqual(continued.lifecycle.phase, event == .discard ? .idle : .finished, "\(event)")
            if event != .discard { XCTAssertEqual(continued.stretches, [.finished], "\(event)") }
            XCTAssertEqual(new.violations + continued.violations, [], "\(event)")
        }
    }

    func testFailedStartReturnsWhereItCameFromWithoutItsStretch() {
        var new = driver(in: .preparing)
        new.send(.startFailed(.microphoneStalled, generation: new.lifecycle.generation), at: now)
        XCTAssertEqual(new.lifecycle.phase, .idle)
        XCTAssertTrue(new.deleted)
        XCTAssertEqual(new.lifecycle.startFailure, .microphoneStalled)

        var resumed = resuming()
        resumed.send(.startFailed(.computerAudioLost, generation: resumed.lifecycle.generation), at: now)
        XCTAssertEqual(resumed.lifecycle.phase, .paused)
        XCTAssertEqual(resumed.stretches, [.pauseButton])
        XCTAssertEqual(resumed.lifecycle.lastEnd, .pauseButton)

        var continued = driver(in: .finished)
        continued.send(.start(acknowledged: true), at: now)
        continued.send(.saved(generation: continued.lifecycle.generation), at: now)
        XCTAssertEqual(continued.lifecycle.phase, .preparing)
        continued.send(.startFailed(.microphoneStalled, generation: continued.lifecycle.generation), at: now)
        XCTAssertEqual(continued.lifecycle.phase, .finished)
        XCTAssertEqual(continued.stretches, [.finished])
        XCTAssertTrue(continued.savedFinished)
        XCTAssertEqual(new.violations + resumed.violations + continued.violations, [])
    }

    func testNewMeetingWithATitleOrNotesIsKeptWhenItsStartNeverDeliversAudio() {
        var failed = driver(in: .preparing, titled: true)
        XCTAssertEqual(failed.send(.startFailed(.computerAudioLost, generation: failed.lifecycle.generation), at: now),
                       [.stopSources, .removeStretch, .markFinished, .saveRecord])
        XCTAssertEqual(failed.lifecycle.phase, .finished)
        XCTAssertTrue(failed.record && failed.savedFinished)
        XCTAssertEqual(failed.stretches, [])

        // Notes typed while the permission prompt was open count too.
        var quit = driver(in: .preparing)
        quit.lifecycle.holdsContent = true
        quit.send(.quit, at: now)
        XCTAssertEqual(quit.complete(at: now), [.removeStretch, .markFinished, .saveRecord])
        XCTAssertTrue(quit.record && quit.savedFinished)

        var locked = Driver(titled: true)
        locked.send(.start(acknowledged: true), at: now)
        locked.send(.boundary(.lockOrSleep), at: now)
        XCTAssertEqual(locked.complete(at: now), [.markFinished, .saveRecord, .requestUnload])
        XCTAssertEqual(locked.lifecycle.phase, .finished)

        var silent = driver(in: .recording, titled: true)
        silent.send(.startFailed(.microphoneStalled, generation: silent.lifecycle.generation), at: now)
        XCTAssertEqual(silent.complete(at: now), [.removeStretch, .markFinished, .saveRecord])
        XCTAssertEqual(failed.violations + quit.violations + locked.violations + silent.violations, [])
    }

    func testFirstAudioFailureAfterGoingLiveRemovesTheEmptyStretchOnDrain() {
        var driver = resuming()
        driver.send(.sourcesLive(generation: driver.lifecycle.generation), at: now)
        let generation = driver.lifecycle.generation
        XCTAssertEqual(driver.send(.startFailed(.microphoneStalled, generation: generation), at: now),
                       [.stopSources, .cancelStretch(generation: generation + 1)])
        XCTAssertEqual(driver.lifecycle.phase, .pausing)
        XCTAssertEqual(driver.complete(at: now), [.removeStretch, .saveRecord])
        XCTAssertEqual(driver.lifecycle.phase, .paused)
        XCTAssertEqual(driver.stretches, [.pauseButton])

        var new = self.driver(in: .recording)
        new.send(.startFailed(.microphoneStalled, generation: new.lifecycle.generation), at: now)
        XCTAssertEqual(new.lifecycle.phase, .pausing)
        XCTAssertEqual(new.complete(at: now), [.deleteRecord])
        XCTAssertEqual(new.lifecycle.phase, .idle)
        XCTAssertEqual(driver.violations + new.violations, [])
    }

    func testStoppingWhileStartingCancelsTheStart() {
        for event in [Event.pause, .boundary(.lockOrSleep), .callEnded, .finish, .quit] {
            var driver = driver(in: .preparing)
            let generation = driver.lifecycle.generation
            XCTAssertEqual(driver.send(event, at: now), [.stopSources, .cancelStretch(generation: generation + 1)], "\(event)")
            driver.send(.sourcesLive(generation: generation), at: now)
            driver.complete(at: now)
            XCTAssertEqual(driver.lifecycle.phase, .idle, "\(event)")
            XCTAssertTrue(driver.deleted, "\(event)")
            XCTAssertEqual(driver.violations, [], "\(event)")
        }
    }

    func testInterruptedResumeStaysPausedAndAsksAgainWhenTheCallMayHaveChanged() {
        let events: [(Int) -> Event] = [{ .sourceLost(.computerAudioLost, generation: $0) }, { _ in .callEnded }, { _ in .boundary(.userSwitched) }]
        for make in events {
            var driver = resuming()
            let generation = driver.lifecycle.generation
            let event = make(generation)
            XCTAssertEqual(driver.send(event, at: now), [.stopSources, .cancelStretch(generation: generation + 1)], "\(event)")
            let unload: [Effect] = event == .boundary(.userSwitched) ? [.requestUnload] : []
            XCTAssertEqual(driver.complete(at: now), [.removeStretch, .saveRecord] + unload, "\(event)")
            XCTAssertEqual(driver.lifecycle.phase, .paused, "\(event)")
            XCTAssertEqual(driver.stretches, [.pauseButton], "\(event)")
            XCTAssertTrue(driver.lifecycle.needsAcknowledgment(at: now), "\(event)")
            XCTAssertEqual(driver.send(.resume(acknowledged: false), at: now), [.refused(.acknowledgmentNeeded)], "\(event)")
            XCTAssertEqual(driver.violations, [], "\(event)")
        }
    }

    func testFinishOrQuitWhileResumingFinishesWithoutTheNewStretch() {
        for event in [Event.finish, .quit] {
            var driver = resuming()
            driver.send(event, at: now)
            XCTAssertEqual(driver.complete(at: now), [.removeStretch, .markFinished, .saveRecord], "\(event)")
            XCTAssertEqual(driver.lifecycle.phase, .finished, "\(event)")
            XCTAssertEqual(driver.stretches, [.pauseButton], "\(event)")
            XCTAssertTrue(driver.savedFinished, "\(event)")
        }
        var timedOut = resuming()
        timedOut.send(.quit, at: now)
        XCTAssertEqual(timedOut.send(.drainTimedOut(generation: timedOut.lifecycle.generation), at: now), [.removeStretch, .markFinished, .saveRecord])
        XCTAssertEqual(timedOut.lifecycle.phase, .finished)
        XCTAssertEqual(timedOut.violations, [])
    }

    // MARK: Pausing and resuming

    func testPauseDrainsThenClosesTheStretchAndSaves() {
        var driver = driver(in: .recording)
        let generation = driver.lifecycle.generation
        XCTAssertEqual(driver.send(.pause, at: now), [.stopSources, .drain(generation: generation + 1)])
        XCTAssertEqual(driver.send(.drained(generation: generation + 1), at: now), [.closeStretch(.pauseButton), .saveRecord])
        XCTAssertEqual(driver.lifecycle.phase, .paused)
        XCTAssertTrue(driver.lifecycle.isOpen)
        XCTAssertEqual(driver.send(.resume(acknowledged: false), at: now.addingTimeInterval(60)), [.beginStretch(generation: generation + 2)])
    }

    func testResumeAfterTheCallMayHaveChangedNeedsAcknowledgment() {
        let events: [(Int) -> Event] = [{ _ in .callEnded }, { _ in .boundary(.lockOrSleep) }, { _ in .boundary(.userSwitched) },
                                        { .sourceLost(.computerAudioLost, generation: $0) }]
        for make in events {
            var driver = driver(in: .recording)
            let event = make(driver.lifecycle.generation)
            driver.send(event, at: now)
            driver.complete(at: now)
            let before = driver.lifecycle
            XCTAssertEqual(driver.send(.resume(acknowledged: false), at: now.addingTimeInterval(1)), [.refused(.acknowledgmentNeeded)], "\(event)")
            XCTAssertEqual(driver.lifecycle, before, "\(event)")
            XCTAssertEqual(driver.send(.resume(acknowledged: true), at: now.addingTimeInterval(1)), [.beginStretch(generation: before.generation + 1)], "\(event)")
        }
    }

    func testSameCallChangesAndShortPausesResumeWithoutAcknowledgment() {
        let events: [(Int) -> Event] = [{ _ in .pause }, { .sourceLost(.computerAudioChanged, generation: $0) },
                                        { .sourceLost(.microphoneLost, generation: $0) }, { .health(.processingFellBehind, generation: $0) }]
        for make in events {
            var driver = driver(in: .recording)
            driver.send(make(driver.lifecycle.generation), at: now)
            driver.complete(at: now)
            XCTAssertFalse(driver.lifecycle.needsAcknowledgment(at: now.addingTimeInterval(15 * 60)))
            XCTAssertTrue(driver.lifecycle.needsAcknowledgment(at: now.addingTimeInterval(15 * 60 + 1)))
            XCTAssertEqual(driver.send(.resume(acknowledged: false), at: now.addingTimeInterval(15 * 60 + 1)), [.refused(.acknowledgmentNeeded)])
        }
        XCTAssertEqual(MeetingLifecycle.acknowledgmentAfterPause, 15 * 60)
    }

    func testFailedResumeKeepsThePauseClockUnlessItWasAcknowledged() {
        let fourteen = now.addingTimeInterval(14 * 60)
        var unacknowledged = resuming(acknowledged: false, at: fourteen)
        unacknowledged.send(.startFailed(.microphoneStalled, generation: unacknowledged.lifecycle.generation), at: fourteen)
        XCTAssertEqual(unacknowledged.lifecycle.phase, .paused)
        XCTAssertTrue(unacknowledged.lifecycle.needsAcknowledgment(at: now.addingTimeInterval(15 * 60 + 1)))
        XCTAssertEqual(unacknowledged.send(.resume(acknowledged: false), at: now.addingTimeInterval(28 * 60)), [.refused(.acknowledgmentNeeded)])

        var cancelled = resuming(acknowledged: false, at: fourteen)
        cancelled.send(.pause, at: fourteen)
        cancelled.complete(at: fourteen)
        XCTAssertTrue(cancelled.lifecycle.needsAcknowledgment(at: now.addingTimeInterval(15 * 60 + 1)))

        var acknowledged = resuming(acknowledged: true, at: fourteen)
        acknowledged.send(.startFailed(.microphoneStalled, generation: acknowledged.lifecycle.generation), at: fourteen)
        XCTAssertFalse(acknowledged.lifecycle.needsAcknowledgment(at: fourteen.addingTimeInterval(15 * 60)))
        XCTAssertTrue(acknowledged.lifecycle.needsAcknowledgment(at: fourteen.addingTimeInterval(15 * 60 + 1)))
        XCTAssertEqual(unacknowledged.violations + cancelled.violations + acknowledged.violations, [])
    }

    func testBoundaryOrCallEndWhilePausedOrDrainingNeedsAcknowledgment() {
        var paused = driver(in: .paused)
        XCTAssertEqual(paused.send(.boundary(.lockOrSleep), at: now), [.requestUnload])
        XCTAssertTrue(paused.lifecycle.needsAcknowledgment(at: now))
        var called = driver(in: .paused)
        XCTAssertEqual(called.send(.callEnded, at: now), [])
        XCTAssertTrue(called.lifecycle.needsAcknowledgment(at: now))

        var draining = driver(in: .pausing)
        XCTAssertEqual(draining.send(.boundary(.lockOrSleep), at: now), [])
        XCTAssertEqual(draining.complete(at: now), [.closeStretch(.pauseButton), .saveRecord, .requestUnload])
        XCTAssertEqual(draining.lifecycle.phase, .paused)
        XCTAssertTrue(draining.lifecycle.needsAcknowledgment(at: now))

        var callEndedWhileDraining = driver(in: .pausing)
        XCTAssertEqual(callEndedWhileDraining.send(.callEnded, at: now), [])
        XCTAssertEqual(callEndedWhileDraining.complete(at: now), [.closeStretch(.pauseButton), .saveRecord])
        XCTAssertTrue(callEndedWhileDraining.lifecycle.needsAcknowledgment(at: now))
        XCTAssertEqual(callEndedWhileDraining.send(.resume(acknowledged: false), at: now), [.refused(.acknowledgmentNeeded)])
    }

    func testLockWhileRecordingPausesThenUnloadsAfterTheDrain() {
        var driver = driver(in: .recording)
        driver.send(.boundary(.lockOrSleep), at: now)
        XCTAssertEqual(driver.send(.drained(generation: driver.lifecycle.generation), at: now), [.closeStretch(.lockOrSleep), .saveRecord, .requestUnload])
    }

    func testSpeechErrorWhileDrainingMarksTheLastWordsAsPossiblyMissing() {
        var pausing = driver(in: .pausing)
        XCTAssertEqual(pausing.send(.health(.speechError, generation: pausing.lifecycle.generation - 1), at: now), [])
        XCTAssertEqual(pausing.send(.health(.speechError, generation: pausing.lifecycle.generation), at: now), [])
        XCTAssertEqual(pausing.complete(at: now), [.closeStretch(.speechError), .saveRecord])

        var finishing = driver(in: .finishing)
        finishing.send(.health(.speechError, generation: finishing.lifecycle.generation), at: now)
        XCTAssertEqual(finishing.complete(at: now), [.closeStretch(.speechError), .markFinished, .saveRecord])

        var rolling = driver(in: .recording)
        rolling.send(.rollover(generation: rolling.lifecycle.generation), at: now)
        rolling.send(.health(.speechError, generation: rolling.lifecycle.generation), at: now)
        XCTAssertEqual(rolling.complete(at: now), [.closeStretch(.speechError), .saveRecord])
        XCTAssertEqual(rolling.lifecycle.phase, .paused)

        // Health rules stop mattering once the sources are off.
        var stalled = driver(in: .pausing)
        stalled.send(.health(.microphoneStalled, generation: stalled.lifecycle.generation), at: now)
        XCTAssertEqual(stalled.complete(at: now), [.closeStretch(.pauseButton), .saveRecord])
        XCTAssertEqual(pausing.violations + finishing.violations + rolling.violations + stalled.violations, [])
    }

    // MARK: Rollover

    func testRolloverContinuesWithoutAcknowledgment() {
        var driver = driver(in: .recording)
        let generation = driver.lifecycle.generation
        XCTAssertEqual(driver.send(.rollover(generation: generation), at: now), [.stopSources, .drain(generation: generation + 1)])
        XCTAssertEqual(driver.send(.drained(generation: generation + 1), at: now),
                       [.closeStretch(.durationLimit), .saveRecord, .beginStretch(generation: generation + 2)])
        XCTAssertEqual(driver.lifecycle.phase, .preparing)
        XCTAssertEqual(driver.stretches, [.durationLimit, nil])
        XCTAssertEqual(driver.violations, [])
    }

    func testInterruptedRolloverDrainEndsTheStretchForThatReason() {
        let cases: [(Event, MeetingStretchEnd, Phase)] = [(.pause, .pauseButton, .paused), (.boundary(.lockOrSleep), .lockOrSleep, .paused),
                                                          (.callEnded, .callEnded, .paused), (.finish, .finished, .finished), (.quit, .quit, .finished)]
        for (event, reason, phase) in cases {
            var driver = driver(in: .recording)
            driver.send(.rollover(generation: driver.lifecycle.generation), at: now)
            driver.send(event, at: now)
            driver.complete(at: now)
            XCTAssertEqual(driver.lifecycle.phase, phase, "\(event)")
            XCTAssertFalse(driver.sourcesOn)
            XCTAssertEqual(driver.stretches, [reason], "\(event)")
            XCTAssertEqual(driver.lifecycle.lastEnd, reason, "\(event)")
            XCTAssertEqual(driver.violations, [], "\(event)")
        }
    }

    func testRolloverRestartThatNeverDeliversAudioPausesWithTheRealReason() {
        var failed = restartingAfterRollover()
        XCTAssertEqual(failed.send(.startFailed(.microphoneStalled, generation: failed.lifecycle.generation), at: now),
                       [.stopSources, .removeStretch, .amendLastStretch(.microphoneStalled), .saveRecord])
        XCTAssertEqual(failed.lifecycle.phase, .paused)
        XCTAssertEqual(failed.stretches, [.microphoneStalled])
        XCTAssertEqual(failed.lifecycle.lastEnd, .microphoneStalled)
        XCTAssertFalse(failed.lifecycle.needsAcknowledgment(at: now.addingTimeInterval(15 * 60)))
        XCTAssertTrue(failed.lifecycle.needsAcknowledgment(at: now.addingTimeInterval(15 * 60 + 1)))

        var locked = restartingAfterRollover()
        locked.send(.boundary(.lockOrSleep), at: now)
        XCTAssertEqual(locked.complete(at: now), [.removeStretch, .amendLastStretch(.lockOrSleep), .saveRecord, .requestUnload])
        XCTAssertEqual(locked.stretches, [.lockOrSleep])
        XCTAssertTrue(locked.lifecycle.needsAcknowledgment(at: now))

        var silent = restartingAfterRollover()
        silent.send(.sourcesLive(generation: silent.lifecycle.generation), at: now)
        silent.send(.startFailed(.computerAudioStalled, generation: silent.lifecycle.generation), at: now)
        XCTAssertEqual(silent.complete(at: now), [.removeStretch, .amendLastStretch(.computerAudioStalled), .saveRecord])

        var finished = restartingAfterRollover()
        finished.send(.finish, at: now)
        XCTAssertEqual(finished.complete(at: now), [.removeStretch, .amendLastStretch(.finished), .markFinished, .saveRecord])
        XCTAssertEqual(finished.stretches, [.finished])
        XCTAssertEqual(failed.violations + locked.violations + silent.violations + finished.violations, [])
    }

    // MARK: Finishing, quitting and discarding

    func testFinishOrQuitWhileDrainingFinishesAfterTheDrain() {
        for event in [Event.finish, .quit] {
            var driver = driver(in: .pausing)
            XCTAssertEqual(driver.send(event, at: now), [])
            driver.complete(at: now)
            XCTAssertEqual(driver.lifecycle.phase, .finished)
            XCTAssertTrue(driver.savedFinished)
            XCTAssertEqual(driver.stretches, [.pauseButton])
        }
        var quitting = driver(in: .recording)
        quitting.send(.quit, at: now)
        quitting.complete(at: now)
        XCTAssertEqual(quitting.stretches, [.quit])
    }

    func testBoundaryWhileFinishingKeepsDrainingThenUnloads() {
        var driver = driver(in: .finishing)
        XCTAssertEqual(driver.send(.boundary(.lockOrSleep), at: now), [])
        XCTAssertEqual(driver.send(.drained(generation: driver.lifecycle.generation), at: now), [.closeStretch(.finished), .markFinished, .saveRecord, .requestUnload])
    }

    func testFinishWhilePausedIsInstant() {
        var driver = driver(in: .paused)
        XCTAssertEqual(driver.send(.finish, at: now), [.markFinished, .saveRecord])
        XCTAssertEqual(driver.lifecycle.phase, .finished)
        XCTAssertFalse(driver.lifecycle.isOpen)
    }

    func testQuitWatchdogClosesTheStretchAsQuitBeforeDrain() {
        for phase in [Phase.recording, .pausing] {
            var driver = driver(in: phase)
            driver.send(.quit, at: now)
            let draining = driver.lifecycle.generation
            XCTAssertEqual(driver.send(.drainTimedOut(generation: draining), at: now), [.closeStretch(.quitBeforeDrain), .markFinished, .saveRecord], "\(phase)")
            let finished = driver.lifecycle
            XCTAssertEqual(finished.phase, .finished, "\(phase)")
            driver.send(.drained(generation: draining), at: now)
            XCTAssertEqual(driver.lifecycle, finished, "\(phase)")
            XCTAssertEqual(driver.stretches, [.quitBeforeDrain], "\(phase)")
            XCTAssertEqual(driver.violations, [], "\(phase)")
        }
    }

    func testQuitWatchdogWhileStartingDeletesOnlyAnEmptyNewMeeting() {
        var empty = driver(in: .preparing)
        empty.send(.quit, at: now)
        XCTAssertEqual(empty.send(.drainTimedOut(generation: empty.lifecycle.generation), at: now), [.deleteRecord])
        XCTAssertEqual(empty.lifecycle.phase, .idle)

        var titled = driver(in: .preparing, titled: true)
        titled.send(.quit, at: now)
        XCTAssertEqual(titled.send(.drainTimedOut(generation: titled.lifecycle.generation), at: now), [.removeStretch, .markFinished, .saveRecord])
        XCTAssertEqual(titled.lifecycle.phase, .finished)
        XCTAssertTrue(titled.record && titled.savedFinished)
        XCTAssertEqual(empty.violations + titled.violations, [])
    }

    func testQuitWatchdogWhileDiscardingStillDeletesTheRecord() {
        var driver = driver(in: .discarding, titled: true)
        let discarding = driver.lifecycle.generation
        XCTAssertEqual(driver.send(.quit, at: now), [])
        XCTAssertEqual(driver.send(.drainTimedOut(generation: discarding), at: now), [.deleteRecord])
        XCTAssertEqual(driver.lifecycle.phase, .idle)
        XCTAssertTrue(driver.deleted && !driver.record)
        let deleted = driver.lifecycle
        driver.send(.drained(generation: discarding), at: now)
        XCTAssertEqual(driver.lifecycle, deleted)
        XCTAssertFalse(driver.sourcesOn)
        XCTAssertEqual(driver.violations, [])
    }

    func testWatchdogOfAnEarlierDrainChangesNothing() {
        var driver = driver(in: .recording)
        driver.send(.quit, at: now)
        let firstDrain = driver.lifecycle.generation
        driver.complete(at: now)
        driver.send(.start(acknowledged: true), at: now)
        driver.send(.saved(generation: driver.lifecycle.generation), at: now)
        driver.send(.sourcesLive(generation: driver.lifecycle.generation), at: now)
        driver.send(.finish, at: now)
        let finishing = driver.lifecycle
        XCTAssertEqual(driver.send(.drainTimedOut(generation: firstDrain), at: now), [])
        XCTAssertEqual(driver.lifecycle, finishing)
        driver.complete(at: now)
        XCTAssertEqual(driver.stretches, [.quit, .finished])
        XCTAssertEqual(driver.violations, [])
    }

    func testQuitFromEveryPhaseEndsWithNoSourceAndASavedRecord() {
        for titled in [false, true] {
            for phase in allPhases {
                var driver = driver(in: phase, titled: titled)
                driver.send(.quit, at: now)
                driver.complete(at: now)
                XCTAssertFalse(driver.sourcesOn, "\(phase)")
                XCTAssertFalse(driver.lifecycle.isOpen, "\(phase)")
                switch phase {
                case .idle: XCTAssertFalse(driver.record)
                case .discarding: XCTAssertTrue(driver.deleted, "\(phase)")
                case .preparing where !titled: XCTAssertTrue(driver.deleted, "\(phase)")
                default: XCTAssertTrue(driver.record && driver.savedFinished, "\(phase) \(titled)")
                }
                XCTAssertEqual(driver.violations, [], "\(phase)")
            }
        }
    }

    func testDiscardFromEveryPhaseEndsWithNoSourceAndNoRecord() {
        for phase in allPhases {
            var driver = driver(in: phase, titled: true)
            let effects = driver.send(.discard, at: now)
            if [.preparing, .recording, .pausing, .paused, .finishing].contains(phase) { XCTAssertEqual(effects.first, .stopSources, "\(phase)") }
            driver.complete(at: now)
            XCTAssertFalse(driver.sourcesOn, "\(phase)")
            switch phase {
            case .finished: XCTAssertTrue(driver.record)
            case .idle: XCTAssertFalse(driver.record)
            default: XCTAssertTrue(driver.deleted && driver.lifecycle.phase == .idle, "\(phase)")
            }
            XCTAssertEqual(driver.violations, [], "\(phase)")
        }
    }

    // MARK: Invariants

    func testEveryExitFromCaptureStopsSourcesFirstAndBumpsTheGeneration() {
        for phase in [Phase.preparing, .recording] {
            for event in stops(driver(in: phase).lifecycle.generation) {
                var driver = driver(in: phase)
                let before = driver.lifecycle.generation
                let effects = driver.send(event, at: now)
                guard driver.lifecycle.phase != phase else { continue }
                XCTAssertEqual(effects.first, .stopSources, "\(phase) \(event)")
                XCTAssertGreaterThan(driver.lifecycle.generation, before, "\(phase) \(event)")
            }
        }
    }

    func testStaleEventsAfterATransitionChangeNothing() {
        for phase in [Phase.preparing, .recording, .pausing, .finishing] {
            for event in stops(driver(in: phase).lifecycle.generation) {
                var driver = driver(in: phase)
                let old = driver.lifecycle.generation
                driver.send(event, at: now)
                guard driver.lifecycle.generation != old else { continue }
                let after = driver.lifecycle
                for stale in [Event.sourcesLive(generation: old), .startFailed(.microphoneStalled, generation: old), .health(.microphoneStalled, generation: old),
                              .health(.speechError, generation: old), .sourceLost(.microphoneLost, generation: old), .rollover(generation: old),
                              .drained(generation: old), .drainTimedOut(generation: old), .saved(generation: old), .saveFailed(generation: old)] {
                    XCTAssertEqual(driver.lifecycle.handle(stale, at: now), [], "\(phase) \(event) \(stale)")
                    XCTAssertEqual(driver.lifecycle, after, "\(phase) \(event) \(stale)")
                }
            }
        }
    }

    func testOnlyStartResumeOrARolloverEverTurnsSourcesOn() {
        // A fixed pseudo-random walk over every event, current and stale; the driver records any violation.
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int(seed >> 33) % bound }
        var began = 0
        for _ in 0..<300 {
            var driver = Driver(finished: next(4) == 0, titled: next(2) == 0)
            for _ in 0..<40 {
                let generation = driver.lifecycle.generation - next(2)
                let pool = stops(generation) + [.start(acknowledged: next(2) == 0), .resume(acknowledged: next(2) == 0), .sourcesLive(generation: generation),
                                                .health(.speechError, generation: generation), .drained(generation: generation),
                                                .drainTimedOut(generation: generation), .saved(generation: generation), .saveFailed(generation: generation)]
                var effects = driver.send(pool[next(pool.count)], at: now.addingTimeInterval(Double(next(2_000))))
                if let pending = driver.saving, next(2) == 0 {
                    effects += driver.send(next(5) == 0 ? .saveFailed(generation: pending) : .saved(generation: pending), at: now)
                }
                began += effects.filter { if case .beginStretch = $0 { return true }; return false }.count
                if driver.owed != nil, next(3) == 0 { driver.complete(at: now) }
            }
            XCTAssertEqual(driver.violations, [])
        }
        XCTAssertGreaterThan(began, 100)
    }
}
