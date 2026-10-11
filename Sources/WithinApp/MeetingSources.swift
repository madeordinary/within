import CoreAudio
import Foundation
import WithinCore

/// One capture seam for a meeting, so the developer fixture drives the real controller. A source starts once
/// per stretch into a fresh ring and stops before any await when the stretch ends.
@MainActor protocol MeetingAudioSource: AnyObject {
    var source: MeetingSource { get }
    var sampleRate: Double { get }
    func start(limits: CaptureLimits, generation: Int) throws -> AudioRing
    /// Stops the hardware, closes the ring and removes listeners. Idempotent.
    func stop()
    /// A configuration, device or process change, tagged with the generation `start` was given.
    var onLost: ((MeetingStretchEnd, _ generation: Int) -> Void)? { get set }
}

/// Starts of the sources that reach audio hardware. The developer fixture reports these, and says
/// "No microphone was opened." only when no microphone source ever started.
@MainActor enum MeetingSourceAudit {
    static var microphoneStarts = 0
    static var appAudioStarts = 0
}

/// You: the shared capture engine with meeting limits. AppModel keeps the engine's one configuration handler
/// and routes it to `MeetingController.microphoneChanged()` while a meeting captures, so this source never
/// replaces it and never calls `onLost` itself. Not exercised by the fixture; UNVERIFIED until a live run.
@MainActor final class MicrophoneSource: MeetingAudioSource {
    let source = MeetingSource.you
    var onLost: ((MeetingStretchEnd, Int) -> Void)?
    private let capture: CaptureEngine
    private let deviceUID: () -> String
    private var running = false

    init(capture: CaptureEngine, deviceUID: @escaping () -> String) { self.capture = capture; self.deviceUID = deviceUID }

    var sampleRate: Double { capture.sampleRate }

    func start(limits: CaptureLimits, generation: Int) throws -> AudioRing {
        MeetingSourceAudit.microphoneStarts += 1
        // A failed start already stops the engine without keeping it for reuse.
        let ring = try capture.start(deviceUID: deviceUID(), limits: limits)
        running = true
        return ring
    }

    /// Only stops the engine this source started, so it never stops a dictation. The engine is never kept for
    /// reuse: this stop can't tell a Pause from an error, and the next start builds a fresh one cheaply.
    func stop() {
        guard running else { return }
        running = false
        capture.stop(reusingStoppedEngine: false)
    }
}

/// Others: the chosen app's sound through a process tap of every matching process present at the start.
/// Each start re-taps the current set; a process that leaves or appears pauses the meeting instead.
/// Not exercised by the fixture's default path; UNVERIFIED until the owner's live probe.
@available(macOS 14.2, *)
@MainActor final class AppAudioSource: MeetingAudioSource {
    let source = MeetingSource.others
    var onLost: ((MeetingStretchEnd, Int) -> Void)?
    private let tap = AppAudioTap()
    private let processes: ([AudioObjectID]) -> [AudioObjectID]
    private let prefixes: [String]
    private let mute: CATapMuteBehavior

    /// A real meeting: unmuted, so the user still hears the call.
    convenience init(app: MeetingApp) {
        self.init(processes: { AppAudioTap.matching($0, bundlePrefixes: app.bundlePrefixes) }, prefixes: app.bundlePrefixes, mute: .unmuted)
    }

    /// `processes` picks the objects to tap from the system's process list. The developer fixture taps only its
    /// own `afplay` process, muted while tapped.
    init(processes: @escaping ([AudioObjectID]) -> [AudioObjectID], prefixes: [String] = [], mute: CATapMuteBehavior) {
        self.processes = processes; self.prefixes = prefixes; self.mute = mute
    }

    var sampleRate: Double { tap.sampleRate }

    func start(limits: CaptureLimits, generation: Int) throws -> AudioRing {
        MeetingSourceAudit.appAudioStarts += 1
        tap.onChange = { [weak self] change, generation in
            self?.onLost?(change == .changed ? .computerAudioChanged : .computerAudioLost, generation)
        }
        // One read chooses the tapped set and is the baseline new processes are compared with.
        let present = AppAudioTap.processList()
        return try tap.start(processes: processes(present), mute: mute, limits: limits, generation: generation, matching: prefixes, present: present)
    }

    func stop() { tap.stop() }

    func isAnyTappedProcessRunningInput() -> Bool { tap.isAnyTappedProcessRunningInput() }
}

/// Developer fixture: plays a prepared synthetic track into the ring at real time and reaches no audio
/// hardware. Each start continues where the last stretch stopped, and audio a full ring refused is played
/// again by the next stretch. Silence arrives as zero frames, like a microphone; with `deliversSilence`
/// off, silent blocks send nothing, like a tap that may stay quiet while the app is silent (UNVERIFIED).
@MainActor final class FixtureSource: MeetingAudioSource {
    let source: MeetingSource
    let sampleRate: Double
    var onLost: ((MeetingStretchEnd, Int) -> Void)?
    /// Replaces the limits of the next start only, so a run can force one overflow or one rollover.
    var limitsOverride: CaptureLimits?
    private(set) var starts = 0
    private let track: [Float]
    private let deliversSilence: Bool
    private let position = FixturePosition()
    private var feeder: Task<Void, Never>?
    private var ring: AudioRing?

    init(source: MeetingSource, track: [Float], sampleRate: Double, deliversSilence: Bool = true) {
        self.source = source; self.track = track; self.sampleRate = sampleRate; self.deliversSilence = deliversSilence
    }

    /// Seconds of the track already delivered.
    var seconds: Double { Double(position.samples) / sampleRate }

    func start(limits: CaptureLimits, generation: Int) throws -> AudioRing {
        stop()
        starts += 1
        let limits = limitsOverride ?? limits
        limitsOverride = nil
        let ring = AudioRing(capacity: limits.ringCapacity(sampleRate: sampleRate), sampleLimit: limits.sampleLimit(sampleRate: sampleRate))
        self.ring = ring
        let track = track, position = position, rate = sampleRate, deliversSilence = deliversSilence
        feeder = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let started = clock.now
            let block = Int(rate / 10)
            var elapsed = 0
            var chunk = [Float](repeating: 0, count: block)
            while !Task.isCancelled {
                let from = position.samples
                for index in 0..<block { chunk[index] = from + index < track.count ? track[from + index] : 0 }
                if deliversSilence || chunk.contains(where: { $0 != 0 }) {
                    let before = ring.samplesCaptured
                    let status = chunk.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: block) }
                    position.advance(Int(ring.samplesCaptured - before))
                    if status != 0 { return }
                } else { position.advance(block) }
                elapsed += block
                try? await clock.sleep(until: started.advanced(by: .seconds(Double(elapsed) / rate)))
            }
        }
        return ring
    }

    func stop() {
        feeder?.cancel(); feeder = nil
        ring?.close(); ring = nil
    }
}

/// The fixture's playback position, shared with its feeding task.
final class FixturePosition: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var samples: Int { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ count: Int) { lock.lock(); value += count; lock.unlock() }
}
