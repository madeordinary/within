import AVFoundation
import CoreAudio
import Darwin
import Foundation
import WithinCore

/// Developer-only: drives the real `MeetingController` headlessly with synthetic fixture audio and a temporary
/// meeting store under the output folder. You and Others are `FixtureSource`s, so no microphone, tap or
/// permission is involved; with `tap` (run and savefail only), Others is instead a muted tap of the fixture's own
/// `afplay` process. `integrity` checks a paused meeting's model copy against a failed integrity check, using a
/// clone of the model folder under the output folder. The report holds counts, reasons, timings and
/// phrase-match booleans, never transcript text.
@MainActor func meetingSessionFixture() async {
    let args = CommandLine.arguments
    let phases = ["run", "crash", "recover", "savefail", "integrity"]
    let extras = args.dropFirst(6)
    let phase = extras.first { phases.contains($0) } ?? "run"
    guard args.count >= 6, args.count <= 8, let seconds = Double(args[4]), extras.allSatisfy({ $0 == "tap" || phases.contains($0) }),
          !extras.contains("tap") || phase == "run" || phase == "savefail" else {
        print("Usage: Within --meeting-session-fixture model-directory fixture-audio seconds output-directory [tap] [run|crash|recover|savefail|integrity]")
        print("tap works with run and savefail only."); exit(2)
    }
    let fixture = MeetingSessionFixture(modelDirectory: URL(fileURLWithPath: args[2]), audio: URL(fileURLWithPath: args[3]), seconds: seconds,
                                        output: URL(fileURLWithPath: args[5], isDirectory: true), tap: extras.contains("tap"), phase: phase)
    exit(await fixture.run())
}

@MainActor private final class MeetingSessionFixture {
    let modelDirectory: URL, audio: URL, output: URL
    let seconds: Double
    let tap: Bool
    let phase: String
    let store: MeetingStore
    var report: [String: Any]
    private let started = ContinuousClock.now
    private var cleanups: [() -> Void] = []

    init(modelDirectory: URL, audio: URL, seconds: Double, output: URL, tap: Bool, phase: String) {
        self.modelDirectory = modelDirectory; self.audio = audio; self.seconds = seconds; self.output = output
        self.tap = tap; self.phase = phase
        store = MeetingStore(meetingsIn: output)
        report = ["fixtureOnly": true, "phase": phase, "othersVia": tap ? "muted tap of the fixture's afplay process" : "fixture ring (no audio hardware)",
                  "youVia": "fixture ring (no microphone)"]
    }

    var reportURL: URL { output.appendingPathComponent("meeting-session-\(phase)\(tap ? "-tap" : "").json") }

    func run() async -> Int32 {
        URLProtocol.registerClass(OfflineProbe.self)
        var passed = false
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            switch phase {
            case "recover": passed = try await recover()
            case "crash": passed = try await crash()
            case "savefail": passed = try await saveFailure()
            case "integrity": passed = try await integrity()
            default: passed = try await capture()
            }
        } catch {
            report["error"] = "\(type(of: error))"
        }
        cleanups.reversed().forEach { $0() }
        return finish(passed)
    }

    private func finish(_ passed: Bool) -> Int32 {
        report["passed"] = passed
        report["interceptedNetworkRequests"] = OfflineProbe.requestCount
        report["microphoneSourceStarts"] = MeetingSourceAudit.microphoneStarts
        report["appAudioSourceStarts"] = MeetingSourceAudit.appAudioStarts
        report["wallSeconds"] = elapsed()
        do { try writeReport(report, to: reportURL) } catch { print("Meeting session fixture could not write its report."); return 1 }
        let noMicrophone = MeetingSourceAudit.microphoneStarts == 0
        print("Meeting session fixture (\(phase)\(tap ? ", tap" : "")) \(passed ? "passed" : "failed"). Report: \(reportURL.lastPathComponent).\(noMicrophone ? " No microphone was opened." : "")")
        return passed && OfflineProbe.requestCount == 0 ? 0 : 1
    }

    private func elapsed() -> Double {
        let value = started.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = elapsed() + timeout
        while !condition() {
            guard elapsed() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    // MARK: Session

    /// Builds the controller over a fixture host and two fixture sources (or the afplay tap for Others).
    private func session() throws -> Session {
        let script = try FixtureScript(audio)
        // As at launch, the staging sweep runs before this process writes; a stale staging file is planted to show it.
        try store.prepareDirectory()
        let stale = store.directory.appendingPathComponent(".\(UUID().uuidString)-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: stale.path, contents: Data("{".utf8), attributes: [.posixPermissions: 0o600])
        _ = store.loadAll()
        report["stagingSweptBeforeFirstWrite"] = !FileManager.default.fileExists(atPath: stale.path)
        let speech = LocalSpeech()
        let host = FixtureHost(speech: speech, directory: modelDirectory, manifest: try loadManifest())
        let you = FixtureSource(source: .you, track: script.track(.you), sampleRate: script.rate)
        var others: MeetingAudioSource = FixtureSource(source: .others, track: script.track(.others), sampleRate: script.rate,
                                                       deliversSilence: script.othersDeliversSilence)
        if tap {
            guard #available(macOS 14.2, *) else { throw FixtureError.unsupported }
            others = try tappedPlayer(script)
        }
        let sources: [MeetingAudioSource] = [you, others]
        let controller = MeetingController(speech: speech, host: host, store: store, sources: { app in app == nil ? [you] : sources })
        report["sourceTypes"] = sources.map { String(describing: type(of: $0)) }
        report["othersDeliversSilence"] = script.othersDeliversSilence
        return Session(script: script, speech: speech, host: host, you: you, others: others, controller: controller)
    }

    /// Others through a muted tap of `afplay` playing the Others track. Fixture only; asks for System Audio Recording.
    @available(macOS 14.2, *)
    private func tappedPlayer(_ script: FixtureScript) throws -> MeetingAudioSource {
        // Two seconds of leading silence let the muted tap attach before any sound starts.
        let track = [Float](repeating: 0, count: Int(script.rate * 2)) + script.track(.others)
        let file = output.appendingPathComponent("synthetic-others-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: script.rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(track.count)) else { throw FixtureError.audio }
        buffer.frameLength = AVAudioFrameCount(track.count)
        track.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: track.count) }
        try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        let source = TappedPlayerSource(file: file)
        cleanups.append { source.stop(); try? FileManager.default.removeItem(at: file) }
        return source
    }

    private let app = MeetingApp(name: "Synthetic app", bundlePrefixes: [])

    // MARK: run

    /// Start, lock at 20 s of script, resume with acknowledgment, a forced overflow, resume, a forced rollover,
    /// then Finish at `seconds` of script, reload and verify. With `tap`: one stretch only.
    private func capture() async throws -> Bool {
        guard tap || seconds >= 90 else { throw FixtureError.tooShort }
        let session = try session()
        let monitor = DiskMonitor(store: store, session: session, fixture: self)
        monitor.start()
        var checks: [String: Bool] = [:]
        checks["stagingSweptBeforeFirstWrite"] = report["stagingSweptBeforeFirstWrite"] as? Bool ?? false
        let controller = session.controller
        checks["started"] = controller.start(app: app, acknowledged: true)
        checks["live"] = await waitUntil(90) { controller.phase == .recording }
        var survivors: [[MeetingSegment]] = []
        func pausedAndKept(_ timeout: Double, stretches: Int) async -> Bool {
            let paused = await waitUntil(timeout) { controller.phase == .paused && controller.meeting?.stretches.count == stretches }
            survivors.append(controller.meeting?.segments ?? [])
            let idle = await waitUntil(30) { session.host.idle }
            return paused && idle
        }
        if tap {
            try? await Task.sleep(for: .seconds(seconds))
        } else {
            checks["lockedAt20s"] = await waitUntil(60) { session.youSeconds >= 20 }
            controller.boundary(.lockOrSleep)
            checks["pausedForLock"] = await pausedAndKept(60, stretches: 1)
            checks["resumeAfterLockNeedsAcknowledgment"] = !controller.resume(acknowledged: false) && controller.refusal == MeetingController.acknowledgmentMessage
            session.overrideLimits(CaptureLimits(totalSeconds: CaptureLimits.meeting.totalSeconds, backlogSeconds: 0.05))
            checks["resumedWithAcknowledgment"] = controller.resume(acknowledged: true)
            checks["pausedForOverflow"] = await pausedAndKept(60, stretches: 2)
            let rolloverAudio = 26.0
            session.overrideLimits(CaptureLimits(totalSeconds: rolloverAudio, backlogSeconds: 20))
            checks["resumedWithoutAcknowledgment"] = controller.resume(acknowledged: false)
            checks["rolledOver"] = await waitUntil(rolloverAudio + 90) { controller.meeting?.stretches.count == 4 && controller.phase == .recording }
            checks["rolloverNoticeKeptAfterRestart"] = controller.notice == MeetingController.rolloverNotice
            report["rolloverAudioSeconds"] = rolloverAudio
            checks["reachedFinishPoint"] = await waitUntil(seconds + 60) { session.youSeconds >= self.seconds }
        }
        let finished = await controller.finish()
        checks["finishSaved"] = finished
        checks["noticeClearedByFinish"] = controller.notice == nil
        monitor.stop()
        await monitor.poll()
        guard let meeting = controller.meeting else { report["checks"] = checks; return false }
        let expected: [MeetingStretchEnd] = tap ? [.finished] : [.lockOrSleep, .processingFellBehind, .durationLimit, .finished]
        checks["stretchEnds"] = meeting.stretches.map(\.ended) == expected
        checks["textSurvivedEachPause"] = survivors.allSatisfy { kept in
            kept.allSatisfy { old in meeting.segments.contains { $0.id == old.id && $0.source == old.source && $0.text.hasPrefix(old.text) } }
        }
        if meeting.stretches.count == 4 {
            report["rolloverGapSeconds"] = meeting.stretches[3].start - (meeting.stretches[2].end ?? meeting.stretches[2].start)
        }
        let reloaded = store.loadAll()
        checks["reloadedEqualsMemory"] = reloaded.documents.first { $0.id == meeting.id } == meeting && reloaded.unreadable == 0
        checks["sessionReleased"] = session.host.idle
        checks["dedicatedCopyReleasedAfterFinish"] = !(await session.speech.dedicatedModelsResident)
        report["dedicatedCopyLoads"] = await session.speech.dedicatedModelLoads
        report["speechUnloads"] = session.host.unloads
        record(meeting, session: session, monitor: monitor, into: &checks)
        if !tap {
            // A second meeting, discarded while recording after a checkpoint: its file goes, and nothing brings it back.
            checks["discardStarted"] = controller.start(app: app, acknowledged: true)
            let discarded = controller.meeting?.id
            checks["discardLive"] = await waitUntil(60) { controller.phase == .recording }
            try? await Task.sleep(for: MeetingController.checkpointDeadline + .seconds(1))
            checks["discardFileWrittenFirst"] = exists(discarded)
            await controller.discard()
            checks["discardDeletedFile"] = controller.meeting == nil && controller.phase == .idle && !exists(discarded) && session.host.idle
            checks["dedicatedCopyReleasedAfterDiscard"] = !(await session.speech.dedicatedModelsResident)
            try? await Task.sleep(for: MeetingController.checkpointDeadline + .seconds(2))
            checks["discardNotResurrected"] = !exists(discarded)
            // A third, quit while recording: saved, with its stretch ended by the quit.
            checks["quitStarted"] = controller.start(app: app, acknowledged: true)
            checks["quitLive"] = await waitUntil(60) { controller.phase == .recording }
            try? await Task.sleep(for: .seconds(2))
            // A quit's first step stops both sources before anything awaits, as the app's quit and logout use it.
            controller.stopForQuit()
            checks["quitStoppedSourcesAtOnce"] = controller.phase == .finishing && session.host.draining
                && controller.sourceStates.values.allSatisfy { $0 == .off } && controller.levels.isEmpty
            checks["quitSaved"] = await controller.quit()
            let quitID = controller.meeting?.id
            checks["quitStretchEnded"] = controller.meeting?.stretches.map(\.ended) == [.quit]
                && store.loadAll().documents.first { $0.id == quitID } == controller.meeting && session.host.idle
            // The shutdown fallback, last because it leaves this controller as an exiting app would: a new meeting
            // still preparing leaves no file, and a recording one is on disk finished before the call returns.
            let spare = LocalSpeech()
            // The controller holds its host weakly, as AppModel's owner holds it.
            let spareHost = FixtureHost(speech: spare, directory: modelDirectory, manifest: try loadManifest())
            let preparing = MeetingController(speech: spare, host: spareHost, store: store, sources: { _ in [] })
            checks["shutdownWhilePreparingStarted"] = preparing.start(app: nil, acknowledged: true) && preparing.phase == .preparing
            let unsaved = preparing.meeting?.id
            checks["shutdownWhilePreparingDeletes"] = unsaved != nil && preparing.emergencyStop() && !exists(unsaved)
            try? await Task.sleep(for: .seconds(1))
            checks["shutdownWhilePreparingStaysDeleted"] = unsaved != nil && !exists(unsaved) && spareHost.claims == 0
            checks["shutdownStarted"] = controller.start(app: app, acknowledged: true)
            let stopped = controller.meeting?.id
            checks["shutdownLive"] = await waitUntil(60) { controller.phase == .recording }
            try? await Task.sleep(for: .seconds(2))
            checks["shutdownSavedFinished"] = controller.emergencyStop() && onDisk(stopped)?.state == .finished
                && onDisk(stopped)?.stretches.map(\.ended) == [.quitBeforeDrain] && onDisk(stopped) == controller.meeting
        }
        report["checks"] = checks
        return checks.values.allSatisfy { $0 }
    }

    private func exists(_ id: UUID?) -> Bool {
        id.map { FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("\($0.uuidString).json").path) } ?? false
    }

    // MARK: crash

    /// Start, wait for two checkpoints with words and a quiet period longer than the checkpoint deadline,
    /// write the report, then stop this process with SIGKILL (no crash report).
    private func crash() async throws -> Bool {
        let session = try session()
        let monitor = DiskMonitor(store: store, session: session, fixture: self)
        monitor.start()
        let controller = session.controller
        var checks: [String: Bool] = [:]
        checks["started"] = controller.start(app: app, acknowledged: true)
        checks["live"] = await waitUntil(90) { controller.phase == .recording }
        let deadline = 5.0
        checks["twoCheckpointsThenQuiet"] = await waitUntil(seconds) {
            monitor.wordedVersions >= 2 && monitor.lastChangeAge > deadline + 1 && monitor.diskMatchesMemory
        }
        await monitor.poll()
        monitor.stop()
        guard let meeting = controller.meeting else { report["checks"] = checks; return false }
        report["meetingID"] = meeting.id.uuidString
        report["checkpointsWritten"] = controller.checkpointsWritten
        report["wordedVersionsOnDisk"] = monitor.wordedVersions
        report["quietSecondsBeforeKill"] = monitor.lastChangeAge
        report["segmentsOnDisk"] = monitor.latest?.segments.count ?? 0
        report["keywordsOnDisk"] = session.script.keywords(in: monitor.latest)
        report["checkpointDelaySeconds"] = monitor.checkpointDelays()
        checks["stillCapturing"] = controller.phase == .recording
        report["checks"] = checks
        report["passed"] = checks.values.allSatisfy { $0 }
        report["interceptedNetworkRequests"] = OfflineProbe.requestCount
        report["microphoneSourceStarts"] = MeetingSourceAudit.microphoneStarts
        try writeReport(report, to: reportURL)
        print("Meeting session fixture (crash): report written; stopping with SIGKILL.\(MeetingSourceAudit.microphoneStarts == 0 ? " No microphone was opened." : "")")
        fflush(stdout)
        kill(getpid(), SIGKILL)
        return false
    }

    // MARK: recover

    /// A new process: load the store (the staging sweep runs first), convert open meetings as at launch, then show
    /// the recovered meeting through a real controller with fixture sources and check that nothing starts.
    private func recover() async throws -> Bool {
        var checks: [String: Bool] = [:]
        let crashReport = (try? Data(contentsOf: output.appendingPathComponent("meeting-session-crash.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let before = store.loadAll()
        let open = before.documents.filter { $0.state == .open }
        report["openMeetingsFound"] = open.count
        let result = MeetingRecovery.recover(before.documents)
        for meeting in result.recovered { try store.save(meeting) }
        for id in result.deleted { try store.delete(id) }
        let after = store.loadAll()
        checks["crashedMeetingFound"] = open.contains { $0.id.uuidString == crashReport["meetingID"] as? String }
        checks["everyOpenMeetingFinished"] = after.documents.allSatisfy { $0.state == .finished }
        for original in open {
            guard let recovered = after.documents.first(where: { $0.id == original.id }) else { continue }
            let last = original.stretches.last
            let lastWords = original.segments.filter { $0.offset >= (last?.start ?? 0) }.map(\.offset).max()
            let expectedEnd = last.map { max($0.lastCheckpoint, $0.start, lastWords ?? $0.start) }
            checks["closedWithUnexpectedExit"] = recovered.stretches.last?.ended == .unexpectedExit
            checks["closedAtLastCheckpoint"] = recovered.stretches.last?.end == expectedEnd
            checks["earlierStretchesUntouched"] = Array(recovered.stretches.dropLast()) == Array(original.stretches.dropLast())
            checks["wordsKept"] = recovered.segments == original.segments
            report["recoveredSegments"] = recovered.segments.count
            report["recoveredStretchEnds"] = recovered.stretches.map { $0.ended?.rawValue ?? "open" }
            report["lastCheckpointBeforeRecovery"] = last?.lastCheckpoint ?? -1
            if let crashed = crashReport["segmentsOnDisk"] as? Int { checks["segmentsMatchCrashCheckpoint"] = crashed == recovered.segments.count }
            if let keywords = crashReport["keywordsOnDisk"] as? [String: String], let script = try? FixtureScript(audio) {
                checks["keywordsMatchCrashCheckpoint"] = script.keywords(in: recovered) == keywords
            }
        }
        // Shown as the app would show it: read-only for capture, and its file left as recovery wrote it.
        var started = MeetingSourceAudit.microphoneStarts + MeetingSourceAudit.appAudioStarts
        if let recovered = after.documents.first(where: { $0.id.uuidString == crashReport["meetingID"] as? String }) {
            let file = store.directory.appendingPathComponent("\(recovered.id.uuidString).json")
            let bytes = try Data(contentsOf: file)
            let script = try FixtureScript(audio)
            let speech = LocalSpeech()
            let host = FixtureHost(speech: speech, directory: modelDirectory, manifest: try loadManifest())
            let you = FixtureSource(source: .you, track: script.track(.you), sampleRate: script.rate)
            let others = FixtureSource(source: .others, track: script.track(.others), sampleRate: script.rate)
            let controller = MeetingController(speech: speech, host: host, store: store, sources: { _ in [you, others] })
            checks["recoveredShown"] = controller.show(recovered) && controller.meeting == recovered
            try? await Task.sleep(for: MeetingController.checkpointDeadline + .seconds(1))
            checks["recoveredStaysFinished"] = controller.phase == .finished && !controller.isOpen && !controller.isCapturing
                && (try? Data(contentsOf: file)) == bytes
            started += you.starts + others.starts + host.claims
        }
        checks["noSourceStarted"] = started == 0
        checks["noStagingLeft"] = stagingFiles() == 0
        report["deletedEmptyMeetings"] = result.deleted.count
        report["checks"] = checks
        return !checks.isEmpty && checks.values.allSatisfy { $0 }
    }

    // MARK: savefail

    /// The store folder is made read-only (the user-immutable flag: a plain chmod is undone by the next save,
    /// which resets the folder to 0700) once a checkpoint holds words. Checks the Not saved state, that capture
    /// continues, and that Finish reports failure; then clears the flag and checks Try again.
    private func saveFailure() async throws -> Bool {
        let session = try session()
        let monitor = DiskMonitor(store: store, session: session, fixture: self)
        monitor.start()
        let controller = session.controller
        var checks: [String: Bool] = [:]
        checks["started"] = controller.start(app: app, acknowledged: true)
        checks["live"] = await waitUntil(90) { controller.phase == .recording }
        checks["wordsCheckpointed"] = await waitUntil(seconds) { monitor.wordedVersions >= 1 }
        let folder = store.directory
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: folder.path)
        cleanups.append { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.path) }
        let failuresBefore = controller.checkpointFailures
        checks["notSavedShown"] = await waitUntil(seconds) { controller.notSaved }
        checks["failureCounted"] = controller.checkpointFailures > failuresBefore
        checks["notSavedAnnounced"] = session.host.announcedNotSaved
        let wordsAtFailure = controller.meeting?.segments.count ?? 0
        let positionAtFailure = session.youSeconds
        checks["captureContinues"] = await waitUntil(seconds) {
            controller.phase == .recording && (controller.meeting?.segments.count ?? 0) > wordsAtFailure && session.youSeconds > positionAtFailure + 5
        }
        let finished = await controller.finish()
        checks["finishRefusesSuccess"] = !finished && controller.notSaved && controller.phase == .finished
        await monitor.poll()
        checks["diskKeepsLastGoodCheckpoint"] = monitor.latest?.state == .open && (monitor.latest?.segments.count ?? 0) < (controller.meeting?.segments.count ?? 0)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.path)
        checks["tryAgainSaves"] = await controller.tryAgain() && !controller.notSaved
        monitor.stop()
        await monitor.poll()
        checks["diskNowFinished"] = monitor.latest == controller.meeting && monitor.latest?.state == .finished
        // A delete the folder refuses: the meeting stays shown, and its later edits still save.
        let kept = controller.meeting?.id
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: folder.path)
        checks["deleteRefusedKeepsMeeting"] = !(await controller.delete()) && controller.meeting?.id == kept && exists(kept)
            && controller.refusal == MeetingController.notDeletedMessage
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.path)
        let notes = "synthetic notes after a refused delete"
        controller.setNotes(notes)
        checks["editSavedAfterRefusedDelete"] = await waitUntil(10) { self.onDisk(kept)?.notes == notes }
        // A discard the folder refuses keeps the record until Try again removes it; nothing replaces it meanwhile.
        checks["discardStarted"] = controller.start(app: app, acknowledged: true)
        let discarded = controller.meeting?.id
        checks["discardLive"] = await waitUntil(60) { controller.phase == .recording } && exists(discarded)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: folder.path)
        checks["discardRefusedKeepsRecord"] = !(await controller.discard()) && controller.deletionPending && controller.phase == .idle
            && controller.meeting?.id == discarded && exists(discarded) && session.host.idle
        checks["noStartWhileDeletionPending"] = !controller.start(app: app, acknowledged: true) && controller.meeting?.id == discarded
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.path)
        checks["tryAgainDeletes"] = await controller.tryAgain() && controller.meeting == nil && !controller.deletionPending && !exists(discarded)
        checks["dedicatedCopyReleasedAfterDiscard"] = !(await session.speech.dedicatedModelsResident)
        report["checkpointFailures"] = controller.checkpointFailures
        report["checks"] = checks
        return checks.values.allSatisfy { $0 }
    }

    private func onDisk(_ id: UUID?) -> Meeting? {
        id.flatMap { try? Data(contentsOf: store.directory.appendingPathComponent("\($0.uuidString).json")) }
            .flatMap { try? JSONDecoder().decode(Meeting.self, from: $0) }
    }

    // MARK: integrity

    /// A paused meeting keeps its dedicated model copy until the periodic integrity check fails. The models load
    /// from a clone of the model folder under the output folder; both sessions begin and end as a stretch's do, one
    /// file of the clone is changed, and the check runs. The real model folder is only read.
    private func integrity() async throws -> Bool {
        var checks: [String: Bool] = [:]
        let manifest = try loadManifest()
        let clone = output.appendingPathComponent("model-clone-\(UUID().uuidString)", isDirectory: true)
        cleanups.append { try? FileManager.default.removeItem(at: clone) }
        try FileManager.default.copyItem(at: modelDirectory, to: clone)
        let speech = LocalSpeech()
        let failures = FixtureCounter()
        await speech.setIntegrityFailureHandler { failures.increment() }
        try await speech.prepare(directory: clone, manifest: manifest)
        try await speech.beginStream(MeetingSource.you.rawValue)
        try await speech.beginStream(MeetingSource.others.rawValue, dedicatedModels: true)
        await speech.cancelStreams()
        checks["copyKeptWhilePaused"] = await speech.dedicatedModelsResident
        await speech.reverifyForFixture()
        checks["intactCloneKeepsCopy"] = await speech.dedicatedModelsResident && failures.value == 0
        guard let artifact = manifest.files.min(by: { $0.size < $1.size }) else { throw FixtureError.script }
        let target = clone.appendingPathComponent(artifact.path), original = modelDirectory.appendingPathComponent(artifact.path)
        // Only the clone's own copy of the file is changed, never one that shares its inode with the real folder.
        guard target.standardizedFileURL.path.hasPrefix(output.standardizedFileURL.path + "/"), inode(target) != nil, inode(target) != inode(original) else {
            throw FixtureError.script
        }
        let handle = try FileHandle(forUpdating: target)
        let first = try handle.read(upToCount: 1)?.first ?? 0
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([first ^ 0xFF]))
        try handle.close()
        await speech.reverifyForFixture()
        checks["integrityFailureHandled"] = failures.value == 1
        checks["noCopyAfterIntegrityFailure"] = !(await speech.dedicatedModelsResident)
        checks["realModelFolderStillVerifies"] = (try? ModelIntegrity.verify(manifest, at: modelDirectory)) != nil
        await speech.unload()
        report["checks"] = checks
        return checks.values.allSatisfy { $0 }
    }

    private func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    // MARK: Report

    private func record(_ meeting: Meeting, session: Session, monitor: DiskMonitor, into checks: inout [String: Bool]) {
        report["stretches"] = meeting.stretches.map { stretch -> [String: Any] in
            let end = stretch.end ?? stretch.lastCheckpoint
            let inside = meeting.segments.filter { $0.offset >= stretch.start && $0.offset <= end }
            return ["ended": stretch.ended?.rawValue ?? "open", "sources": stretch.sources.map(\.rawValue), "start": stretch.start, "end": end,
                    "youWords": inside.filter { $0.source == .you }.reduce(0) { $0 + $1.text.split(separator: " ").count },
                    "othersWords": inside.filter { $0.source == .others }.reduce(0) { $0 + $1.text.split(separator: " ").count }]
        }
        report["segments"] = meeting.segments.count
        report["segmentSources"] = meeting.segments.map(\.source.rawValue).joined(separator: ",")
        report["youWords"] = meeting.segments.filter { $0.source == .you }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        report["othersWords"] = meeting.segments.filter { $0.source == .others }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        checks["segmentOffsetsAscending"] = zip(meeting.segments, meeting.segments.dropFirst()).allSatisfy { $0.offset <= $1.offset }
        checks["stretchesInOrder"] = zip(meeting.stretches, meeting.stretches.dropFirst()).allSatisfy { ($0.end ?? $0.start) <= $1.start }
        checks["segmentsInsideStretches"] = meeting.segments.allSatisfy { segment in
            meeting.stretches.contains { segment.offset >= $0.start && segment.offset <= ($0.end ?? .infinity) }
        }
        checks["noFixesOnOthers"] = !meeting.segments.contains { $0.source == .others && $0.original != nil }
        let phrases = session.script.phraseReport(meeting)
        report["turns"] = phrases.turns
        if !phrases.turns.isEmpty {
            checks["everyKeywordUnderItsSource"] = phrases.allFound
            checks["noKeywordUnderTheOtherSource"] = phrases.crossTalk == 0
            checks["segmentsInSpeakingOrder"] = phrases.inOrder
        }
        let delays = monitor.checkpointDelays()
        report["checkpointDelaySeconds"] = delays
        // A scripted turn whose last word never reached a checkpoint fails, rather than dropping out of the timing.
        checks["everyTurnEndCheckpointed"] = delays.count == session.script.turns.filter { $0.lastWord != nil }.count
        if let longest = delays.values.max() {
            report["longestQuietToCheckpointSeconds"] = longest
            checks["lastSentenceCheckpointedWithin30s"] = longest <= 30
        }
        report["footprintMBEvery5s"] = monitor.footprints
        report["checkpointsWritten"] = session.controller.checkpointsWritten
        let file = store.directory.appendingPathComponent("\(meeting.id.uuidString).json")
        let fileMode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
        let folderMode = (try? FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int) ?? -1
        report["fileMode"] = String(fileMode, radix: 8); report["folderMode"] = String(folderMode, radix: 8)
        checks["ownerOnly"] = fileMode == 0o600 && folderMode == 0o700
        checks["excludedFromBackup"] = (try? store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
        report["stagingLeftovers"] = stagingFiles()
        checks["noStagingLeft"] = stagingFiles() == 0
    }

    private func stagingFiles() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).filter { $0.hasPrefix(".") && $0.hasSuffix(".tmp") }.count
    }

    fileprivate var now: Double { elapsed() }
}

private enum FixtureError: Error { case script, audio, unsupported, tooShort }

/// Others in `tap` mode: `afplay` plays the prepared file only while its muted tap exists. Each start launches the
/// player and taps it during the file's leading silence; each stop ends the player before the tap. UNVERIFIED:
/// the tap variant has not been run.
@available(macOS 14.2, *)
@MainActor private final class TappedPlayerSource: MeetingAudioSource {
    let source = MeetingSource.others
    var onLost: ((MeetingStretchEnd, Int) -> Void)? {
        get { tap.onLost }
        set { tap.onLost = newValue }
    }
    private let file: URL
    private let player = FixturePlayer()
    private let tap: AppAudioSource

    init(file: URL) {
        self.file = file
        let player = player
        tap = AppAudioSource(processes: { _ in player.object.map { [$0] } ?? [] }, mute: .mutedWhenTapped)
    }

    var sampleRate: Double { tap.sampleRate }

    func start(limits: CaptureLimits, generation: Int) throws -> AudioRing {
        stop()
        try player.launch(file)
        do { return try tap.start(limits: limits, generation: generation) } catch { stop(); throw error }
    }

    func stop() {
        player.end()
        tap.stop()
    }
}

/// The fixture's `afplay` child and its Core Audio process object.
@available(macOS 14.2, *)
@MainActor private final class FixturePlayer {
    private var process: Process?
    private(set) var object: AudioObjectID?

    func launch(_ file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); process.arguments = [file.path]
        try process.run()
        self.process = process
        // The file starts with two seconds of silence, so waiting here for the process object plays nothing audible.
        for _ in 0..<60 {
            object = AppAudioTap.processObject(pid: process.processIdentifier)
            if object != nil { return }
            usleep(25_000)
        }
    }

    /// Killed outright and given a moment to go, so it is silent before its tap is removed.
    func end() {
        guard let process else { return }
        self.process = nil; object = nil
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        usleep(100_000)
    }
}

/// Counts calls from a `@Sendable` handler.
private final class FixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@MainActor private struct Session {
    let script: FixtureScript
    let speech: LocalSpeech
    let host: FixtureHost
    let you: FixtureSource
    let others: MeetingAudioSource
    let controller: MeetingController
    var youSeconds: Double { you.seconds }
    var othersSeconds: Double { (others as? FixtureSource)?.seconds ?? you.seconds }
    func overrideLimits(_ limits: CaptureLimits) {
        you.limitsOverride = limits
        (others as? FixtureSource)?.limitsOverride = limits
    }
}

/// A minimal host over its own session state. It refuses while a session runs or speech unloads, mirrors
/// AppModel's deferred unload, and applies no personal dictionary: fixtures report raw words.
@MainActor private final class FixtureHost: MeetingHost {
    let speech: LocalSpeech
    let directory: URL
    let modelManifest: ModelManifest
    private var session = SessionState()
    private var unloadAfterSession = false, unloading = false
    private(set) var claims = 0, unloads = 0
    private(set) var announcedNotSaved = false

    init(speech: LocalSpeech, directory: URL, manifest: ModelManifest) { self.speech = speech; self.directory = directory; modelManifest = manifest }

    var microphoneUID: String { "" }
    var microphoneAuthorized: Bool { true }
    var dictionaryMatcher: DictionaryMatcher { .empty }
    var idle: Bool { session.phase == .ready && !unloading }
    /// The session was told its stretch is draining.
    var draining: Bool { session.phase == .transcribing }
    func modelDirectory() async -> URL { directory }
    func meetingStartRefusal() -> String? { idle ? nil : "Local speech is busy. Try again when it's ready." }
    func claimCapture() -> UUID? {
        guard !unloading, let id = session.begin() else { return nil }
        claims += 1
        return id
    }
    func captureRecording(_ id: UUID) -> Bool { session.recording(id) }
    func captureDraining(_ id: UUID) { _ = session.stopped(id) }
    func releaseCapture(_ id: UUID) async {
        session.finish(id)
        if unloadAfterSession { unloadAfterSession = false; await unload() }
    }
    func requestUnload() {
        guard session.phase == .ready else { unloadAfterSession = true; return }
        unloading = true
        Task { await unload() }
    }
    private func unload() async {
        unloading = true; unloads += 1
        await speech.unload()
        unloading = false
    }
    func announce(_ text: String) { if text == MeetingController.notSavedMessage { announcedNotSaved = true } }
    func playCue(start: Bool) {}
}

/// Polls the meeting file as it is on disk, so checkpoint timing is measured from what a crash would keep.
@MainActor private final class DiskMonitor {
    let store: MeetingStore
    let session: Session
    unowned let fixture: MeetingSessionFixture
    private(set) var latest: Meeting?
    private(set) var wordedVersions = 0
    private(set) var footprints: [Double] = []
    private var lastData: Data?
    private var lastSegments: [MeetingSegment] = []
    private var lastChange = 0.0
    private var firstOnDisk: [Int: Double] = [:]
    private var quietAt: [Int: Double] = [:]
    private var task: Task<Void, Never>?

    init(store: MeetingStore, session: Session, fixture: MeetingSessionFixture) { self.store = store; self.session = session; self.fixture = fixture }

    func start() {
        task = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                if tick % 20 == 0 { self.footprints.append(physicalFootprintMB()) }
                tick += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// Seconds since the in-memory transcript last changed.
    var lastChangeAge: Double { fixture.now - lastChange }
    var diskMatchesMemory: Bool { latest?.segments == session.controller.meeting?.segments }

    func poll() async {
        let now = fixture.now
        if session.controller.meeting?.segments != lastSegments { lastSegments = session.controller.meeting?.segments ?? []; lastChange = now }
        for (index, turn) in session.script.turns.enumerated() where quietAt[index] == nil {
            let position = turn.source == .you ? session.youSeconds : session.othersSeconds
            if position >= turn.end { quietAt[index] = now }
        }
        guard let id = session.controller.meeting?.id,
              let data = try? Data(contentsOf: store.directory.appendingPathComponent("\(id.uuidString).json")), data != lastData,
              let meeting = try? JSONDecoder().decode(Meeting.self, from: data) else { return }
        if meeting.segments != latest?.segments, !meeting.segments.isEmpty { wordedVersions += 1 }
        lastData = data; latest = meeting
        for (index, turn) in session.script.turns.enumerated() where firstOnDisk[index] == nil {
            if session.script.ended(turn, in: meeting) { firstOnDisk[index] = now }
        }
    }

    /// For each turn whose last word reached disk: seconds from its speaker going quiet to the first checkpoint holding that word.
    func checkpointDelays() -> [String: Double] {
        var delays: [String: Double] = [:]
        for (index, onDisk) in firstOnDisk {
            guard let quiet = quietAt[index] else { continue }
            delays["turn\(index + 1)-\(session.script.turns[index].source.rawValue)"] = (onDisk - quiet).rounded(toPlaces: 1)
        }
        return delays
    }
}

/// Turn-taking synthetic audio: each turn is one source's known phrase at a script time, with silence
/// between. A JSON script lists the turns; a single audio file becomes two turns without phrase checks.
private struct FixtureScript {
    struct Turn {
        let source: MeetingSource
        let start: Double
        let samples: [Float]
        let keyword: String?
        let phrase: String?
        let end: Double
        /// The word that shows the turn's last sentence reached a checkpoint: the phrase's last, else the keyword.
        var lastWord: String? { phrase.flatMap { FixtureScript.words($0).last } ?? keyword }
    }
    let rate: Double
    let turns: [Turn]
    let length: Double
    let othersDeliversSilence: Bool

    init(_ url: URL) throws {
        guard url.pathExtension == "json" else {
            let (samples, rate) = try loadFixture(url.path)
            let half = samples.count / 2
            let first = Turn(source: .you, start: 1, samples: Array(samples[..<half]), keyword: nil, phrase: nil, end: 1 + Double(half) / rate)
            let secondStart = first.end + 20
            let second = Turn(source: .others, start: secondStart, samples: Array(samples[half...]), keyword: nil, phrase: nil,
                              end: secondStart + Double(samples.count - half) / rate)
            self.rate = rate; turns = [first, second]; length = second.end + 35; othersDeliversSilence = true
            return
        }
        struct Entry: Decodable { let source: String; let start: Double; let audio: String; let keyword: String?; let phrase: String? }
        struct File: Decodable { let turns: [Entry]; let length: Double; let othersDeliversSilence: Bool? }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        var rate: Double?
        var turns: [Turn] = []
        for entry in file.turns {
            guard let source = MeetingSource(rawValue: entry.source) else { throw FixtureError.script }
            let (samples, sampleRate) = try loadFixture(url.deletingLastPathComponent().appendingPathComponent(entry.audio).path)
            guard rate == nil || rate == sampleRate else { throw FixtureError.script }
            rate = sampleRate
            turns.append(Turn(source: source, start: entry.start, samples: samples, keyword: entry.keyword?.lowercased(), phrase: entry.phrase,
                              end: entry.start + Double(samples.count) / sampleRate))
        }
        guard let rate, !turns.isEmpty else { throw FixtureError.script }
        self.rate = rate; self.turns = turns.sorted { $0.start < $1.start }
        length = max(file.length, turns.map(\.end).max() ?? 0); othersDeliversSilence = file.othersDeliversSilence ?? true
    }

    func track(_ source: MeetingSource) -> [Float] {
        var track = [Float](repeating: 0, count: Int(length * rate))
        for turn in turns where turn.source == source {
            let start = Int(turn.start * rate)
            for (index, sample) in turn.samples.enumerated() where start + index < track.count { track[start + index] = sample }
        }
        return track
    }

    static func words(_ text: String) -> [String] {
        String(text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }).split(separator: " ").map(String.init)
    }

    /// Whether the turn's last word is in the meeting under its source.
    func ended(_ turn: Turn, in meeting: Meeting) -> Bool {
        guard let word = turn.lastWord else { return false }
        return meeting.segments.contains { $0.source == turn.source && Self.words($0.text).contains(word) }
    }

    /// Which source each keyword was found under; never the words around it.
    func keywords(in meeting: Meeting?) -> [String: String] {
        var found: [String: String] = [:]
        for (index, turn) in turns.enumerated() {
            guard let keyword = turn.keyword, let meeting else { continue }
            let sources = Set(meeting.segments.filter { Self.words($0.text).contains(keyword) }.map(\.source.rawValue))
            if !sources.isEmpty { found["turn\(index + 1)"] = sources.sorted().joined(separator: "+") }
        }
        return found
    }

    func phraseReport(_ meeting: Meeting) -> (turns: [[String: Any]], allFound: Bool, crossTalk: Int, inOrder: Bool) {
        var rows: [[String: Any]] = [], allFound = true, crossTalk = 0
        var order: [Int] = []
        for segment in meeting.segments {
            let words = Self.words(segment.text)
            let hits = turns.indices.compactMap { index -> (position: Int, turn: Int)? in
                guard let keyword = turns[index].keyword, turns[index].source == segment.source,
                      let position = words.firstIndex(of: keyword) else { return nil }
                return (position, index)
            }
            order += hits.sorted { $0.position < $1.position }.map(\.turn)
        }
        for (index, turn) in turns.enumerated() {
            guard let keyword = turn.keyword else { continue }
            let own = meeting.segments.filter { $0.source == turn.source }.flatMap { Self.words($0.text) }
            let other = meeting.segments.filter { $0.source != turn.source }.flatMap { Self.words($0.text) }
            let phraseWords = turn.phrase.map(Self.words) ?? []
            let phraseFound = !phraseWords.isEmpty && own.count >= phraseWords.count
                && (0...(own.count - phraseWords.count)).contains { Array(own[$0..<$0 + phraseWords.count]) == phraseWords }
            let keywordFound = own.contains(keyword)
            if !keywordFound { allFound = false }
            if other.contains(keyword) { crossTalk += 1 }
            rows.append(["turn": index + 1, "source": turn.source.rawValue, "start": turn.start, "end": turn.end.rounded(toPlaces: 2),
                         "keywordFound": keywordFound, "phraseFound": phraseFound, "keywordUnderOtherSource": other.contains(keyword)])
        }
        var seen = Set<Int>()
        let firsts = order.filter { seen.insert($0).inserted }
        return (rows, allFound, crossTalk, firsts == firsts.sorted() && firsts.count == order.count)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
