import CoreAudio
import Foundation
import WithinCore

/// Public Core Audio access for the opt-in "mute while dictating" setting: the default
/// output device's mute switch and which apps are playing or recording. Reads no audio.
enum SystemOutput {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func uid(of device: AudioObjectID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String?
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// `nil` when the device has no settable output mute switch.
    static func isMuted(_ device: AudioObjectID) -> Bool? {
        var property = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &property) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &muted) == noErr ? muted != 0 : nil
    }

    static func canMute(_ device: AudioObjectID) -> Bool {
        var property = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &property) && AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
    }

    @discardableResult static func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var property = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Audio clients by bundle ID with running input/output flags; empty where unsupported.
    static func audioClients() -> [AudioClientSnapshot] {
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var bundleProperty = address(kAudioProcessPropertyBundleID)
            var bundle: CFString? = nil
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(object, &bundleProperty, 0, nil, &bundleSize, &bundle) == noErr, let id = bundle as String? else { return nil }
            func flag(_ selector: AudioObjectPropertySelector) -> Bool {
                var flagProperty = address(selector)
                var value: UInt32 = 0
                var valueSize = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(object, &flagProperty, 0, nil, &valueSize, &value) == noErr && value != 0
            }
            return AudioClientSnapshot(bundleID: id, runningInput: flag(kAudioProcessPropertyIsRunningInput), runningOutput: flag(kAudioProcessPropertyIsRunningOutput))
        }
    }
}
