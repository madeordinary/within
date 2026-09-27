import CoreAudio
import Foundation
import WithinCore

/// Captures one app's audio output digitally with a Core Audio process tap (macOS 14.2+),
/// downmixed to mono into a bounded ring. Nothing is written to disk.
///
/// Real meetings must use `.unmuted` so the user still hears the call. Muting is for silent
/// fixtures only, and `.muted` never delivered audio in the Sep 27 spike: use `.mutedWhenTapped`.
@available(macOS 14.2, *)
final class AppAudioTap {
    enum Failure: Error { case noProcess, tap(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus) }
    private(set) var ring: AudioRing?
    private(set) var sampleRate: Double = 48_000
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)

    deinit { stop(); mono.deallocate() }

    /// Core Audio process objects for every audio client whose bundle ID starts with any prefix,
    /// so helper processes that play received call audio are included.
    static func processObjects(bundlePrefixes: [String]) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
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

    static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }

    func start(processes: [AudioObjectID], mute: CATapMuteBehavior, limits: CaptureLimits) throws -> AudioRing {
        guard !processes.isEmpty else { throw Failure.noProcess }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = mute
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure.tap(status) }

        var output = AudioObjectID(kAudioObjectUnknown)
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &outputSize, &output)
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var outputUID: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        _ = AudioObjectGetPropertyData(output, &uidAddress, 0, nil, &uidSize, &outputUID)
        let uid = (outputUID as String?) ?? ""
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Within meeting audio", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else { stop(); throw Failure.aggregate(status) }

        var format = AudioStreamBasicDescription()
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format)
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let ring = AudioRing(capacity: limits.ringCapacity(sampleRate: sampleRate), sampleLimit: limits.sampleLimit(sampleRate: sampleRate))
        let mono = self.mono
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, _, _ in
            // Real-time path: downmix into a preallocated buffer and copy into the fixed ring.
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frames = min(16_384, Int(buffer.mDataByteSize) / (4 * channels))
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += data[frame * channels + channel] }
                    mono[frame] = sum / Float(channels)
                }
                _ = ring.push(mono, count: frames)
            }
        }
        guard status == noErr, let procID else { stop(); throw Failure.ioProc(status) }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { stop(); throw Failure.start(status) }
        self.ring = ring
        return ring
    }

    func stop() {
        if let procID, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        procID = nil
        ring?.close(); ring = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
    }
}
