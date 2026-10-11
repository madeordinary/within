import CoreAudio
import Foundation
import WithinCore

/// Plain Core Audio property reads shared by the tap and the developer probes.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
    static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
        var property = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
    static func object(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var property = address(selector)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr, value != kAudioObjectUnknown else { return nil }
        return value
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var property = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }
    /// Channels in each input stream of a device.
    static func inputStreamChannels(_ device: AudioObjectID) -> [Int]? {
        var property = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw) == noErr else { return nil }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }
}

/// Captures one app's audio output digitally with a Core Audio process tap (macOS 14.2+),
/// downmixed to mono into a bounded ring. Nothing is written to disk.
///
/// Real meetings must use `.unmuted` so the user still hears the call. Muting is for silent
/// fixtures only, and `.muted` never delivered audio in the Sep 27 spike: use `.mutedWhenTapped`.
///
/// The output-device choice, the input-stream check, the aggregate rate and the listeners are
/// UNVERIFIED until the owner's live probe; nothing here has run against a real call.
@available(macOS 14.2, *)
final class AppAudioTap {
    enum Failure: Error { case noProcess, noOutputDevice, tap(OSStatus), aggregate(OSStatus), inputStreams(Int), ioProc(OSStatus), listener(OSStatus), start(OSStatus) }
    /// Which output device clocks the aggregate. Which is right is UNVERIFIED: the alert device (used since
    /// Sep 27) or the default output device. The live probe records both.
    enum OutputClock: String { case systemOutput, defaultOutput }
    /// A tapped process went away, the output device or the aggregate's rate changed (`lost`), or a new
    /// process of the same app appeared (`changed`). The tap is never rebuilt or widened silently.
    enum Change { case lost, changed }
    /// What the aggregate looked like when it started, for the live probe.
    struct Configuration {
        let clock: OutputClock
        let systemOutputUID: String?
        let defaultOutputUID: String?
        /// Nil when the stream configuration couldn't be read.
        let inputStreamChannels: [Int]?
        let tapRate: Double
        let aggregateRate: Double?
    }
    /// Probe-only counters, written on the IO thread and read after `stop()`.
    final class CallbackCounts {
        fileprivate let values = UnsafeMutablePointer<Int>.allocate(capacity: 7)
        init() { values.initialize(repeating: 0, count: 7); values[5] = .max }
        deinit { values.deallocate() }
        var callbacks: Int { values[0] }
        /// No buffer carried any bytes.
        var callbacksWithoutFrames: Int { values[1] }
        /// Frames arrived, all exactly zero.
        var digitallySilentCallbacks: Int { values[2] }
        var maxBuffers: Int { values[3] }
        var maxChannels: Int { values[4] }
        var minChannels: Int { values[5] == .max ? 0 : values[5] }
        var frames: Int { values[6] }
    }

    private(set) var ring: AudioRing?
    private(set) var sampleRate: Double = 48_000
    private(set) var configuration: Configuration?
    /// Called on the main queue with the generation `start` was given; ignored after `stop()`.
    var onChange: ((Change, Int) -> Void)?
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapped: [AudioObjectID] = []
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "com.madeordinary.Within.tap-listeners")
    /// Changes on every start and stop, so a listener report queued before `stop()` is dropped.
    private var token = 0
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)

    deinit { stop(); mono.deallocate() }

    /// Core Audio process objects for every audio client whose bundle ID starts with any prefix,
    /// so helper processes that play received call audio are included.
    static func processObjects(bundlePrefixes: [String]) -> [AudioObjectID] { matching(processList(), bundlePrefixes: bundlePrefixes) }

    static func processList() -> [AudioObjectID] { CoreAudioProperty.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) }

    static func matching(_ objects: [AudioObjectID], bundlePrefixes: [String]) -> [AudioObjectID] {
        objects.filter { object in
            guard let bundle = bundleID(of: object) else { return false }
            return bundlePrefixes.contains { bundle.hasPrefix($0) }
        }
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func bundleID(of object: AudioObjectID) -> String? { CoreAudioProperty.string(object, kAudioProcessPropertyBundleID) }

    static func outputUID(_ selector: AudioObjectPropertySelector) -> String? {
        CoreAudioProperty.object(AudioObjectID(kAudioObjectSystemObject), selector).flatMap { CoreAudioProperty.string($0, kAudioDevicePropertyDeviceUID) }
    }

    /// `matching` names the app's bundle prefixes, so a new process of that app pauses the meeting; `present` is
    /// the process list `processes` was chosen from, the baseline for what is new. The product refuses unless the
    /// aggregate has exactly one input stream it could read (a headset's microphone would mix into Others); the
    /// live probe passes `refuseExtraInputStreams: false` to record the layout instead.
    func start(processes: [AudioObjectID], mute: CATapMuteBehavior, limits: CaptureLimits, generation: Int = 0, matching prefixes: [String] = [],
               present: [AudioObjectID]? = nil, clock: OutputClock = .systemOutput, refuseExtraInputStreams: Bool = true,
               counts: CallbackCounts? = nil) throws -> AudioRing {
        guard !processes.isEmpty else { throw Failure.noProcess }
        let baseline = Set(present ?? Self.processList())
        stop()
        let systemUID = Self.outputUID(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let defaultUID = Self.outputUID(kAudioHardwarePropertyDefaultOutputDevice)
        guard let uid = clock == .systemOutput ? systemUID : defaultUID, !uid.isEmpty,
              let output = CoreAudioProperty.object(AudioObjectID(kAudioObjectSystemObject),
                  clock == .systemOutput ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        else { throw Failure.noOutputDevice }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = mute
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure.tap(status) }
        tapped = processes

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Within meeting audio", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else { stop(); throw Failure.aggregate(status) }

        var format = AudioStreamBasicDescription()
        var formatAddress = CoreAudioProperty.address(kAudioTapPropertyFormat)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format)
        let tapRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        // The IOProc runs on the aggregate's clock, so its nominal rate labels the ring.
        let aggregateRate = CoreAudioProperty.float64(aggregate, kAudioDevicePropertyNominalSampleRate).flatMap { $0 > 0 ? $0 : nil }
        sampleRate = aggregateRate ?? tapRate
        let streams = CoreAudioProperty.inputStreamChannels(aggregate)
        configuration = Configuration(clock: clock, systemOutputUID: systemUID, defaultOutputUID: defaultUID,
                                      inputStreamChannels: streams, tapRate: tapRate, aggregateRate: aggregateRate)
        // An unreadable or empty configuration is refused too: the check must pass, not merely not fail.
        if refuseExtraInputStreams, streams?.count != 1 { stop(); throw Failure.inputStreams(streams?.count ?? -1) }

        let ring = AudioRing(capacity: limits.ringCapacity(sampleRate: sampleRate), sampleLimit: limits.sampleLimit(sampleRate: sampleRate))
        let mono = self.mono
        let counters = counts?.values
        let oneStreamOnly = refuseExtraInputStreams
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, _, _ in
            // Real-time path: downmix into a preallocated buffer and copy into the fixed ring.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The product never mixes a second input stream into Others, even one that appears after the check.
            if oneStreamOnly, list.count != 1 { return }
            var bytes = 0, nonzero = false
            for buffer in list {
                bytes += Int(buffer.mDataByteSize)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frames = min(16_384, Int(buffer.mDataByteSize) / (4 * channels))
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += data[frame * channels + channel] }
                    mono[frame] = sum / Float(channels)
                }
                _ = ring.push(mono, count: frames)
                if let counters {
                    if !nonzero { nonzero = (0..<frames).contains { mono[$0] != 0 } }
                    counters[4] = max(counters[4], channels); counters[5] = min(counters[5], channels); counters[6] += frames
                }
            }
            if let counters {
                counters[0] += 1; counters[3] = max(counters[3], list.count)
                if bytes == 0 { counters[1] += 1 } else if !nonzero { counters[2] += 1 }
            }
        }
        guard status == noErr, procID != nil else { stop(); throw Failure.ioProc(status) }
        do { try listen(output: output, prefixes: prefixes, generation: generation, baseline: baseline) } catch { stop(); throw error }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { stop(); throw Failure.start(status) }
        self.ring = ring
        return ring
    }

    /// Whether any process already in the tap is using a microphone: the call-end signal. Reads only those
    /// process objects, never the system's audio clients.
    func isAnyTappedProcessRunningInput() -> Bool {
        tapped.contains { (CoreAudioProperty.uint32($0, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 }
    }

    func stop() {
        token += 1
        // Listeners go first, so none fires for a tap or aggregate being destroyed.
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, listenerQueue, listener.block)
        }
        listeners = []
        if let procID, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        procID = nil
        ring?.close(); ring = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
        tapped = []
    }

    /// Every listener registers or the start fails: a missing one would hide a lost output or a new process.
    private func listen(output: AudioObjectID, prefixes: [String], generation: Int, baseline: Set<AudioObjectID>) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let token = self.token
        let tapped = Set(self.tapped)
        var known = baseline
        let report: (Change) -> Void = { [weak self] change in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == token else { return }
                self.onChange?(change, generation)
            }
        }
        // Runs on the serial listener queue, so `known` needs no lock. Only new objects have their bundle ID read,
        // and none at all without prefixes to match.
        let compare = {
            let current = Set(CoreAudioProperty.objects(system, kAudioHardwarePropertyProcessObjectList))
            defer { known = current }
            if !tapped.isSubset(of: current) { report(.lost); return }
            guard !prefixes.isEmpty else { return }
            let appeared = current.subtracting(known).contains { object in
                guard let bundle = Self.bundleID(of: object) else { return false }
                return prefixes.contains { bundle.hasPrefix($0) }
            }
            if appeared { report(.changed) }
        }
        try add(system, kAudioHardwarePropertyDefaultOutputDevice) { _, _ in report(.lost) }
        try add(system, kAudioHardwarePropertyDefaultSystemOutputDevice) { _, _ in report(.lost) }
        try add(output, kAudioDevicePropertyDeviceIsAlive) { _, _ in report(.lost) }
        try add(aggregate, kAudioDevicePropertyNominalSampleRate) { _, _ in report(.lost) }
        try add(system, kAudioHardwarePropertyProcessObjectList) { _, _ in compare() }
        // A process that appeared while the tap was being built changed the list before anything listened.
        listenerQueue.async(execute: compare)
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ block: @escaping AudioObjectPropertyListenerBlock) throws {
        var address = CoreAudioProperty.address(selector)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block)
        guard status == noErr else { throw Failure.listener(status) }
        listeners.append((object, address, block))
    }
}
