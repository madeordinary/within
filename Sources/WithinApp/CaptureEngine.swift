import AVFoundation
import AudioToolbox
import CoreAudio
import WithinCore

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String
    let objectID: AudioDeviceID
    let name: String
}

@MainActor
final class CaptureEngine {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    var onConfigurationChanged: (() -> Void)?
    private(set) var ring: AudioRing?
    private(set) var sampleRate: Double = 0

    func start(deviceUID: String) throws -> AudioRing {
        guard engine == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw CaptureFailure.permission }
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            let input = engine.inputNode
            if !deviceUID.isEmpty {
                guard let selected = Self.devices().first(where: { $0.id == deviceUID }), let unit = input.audioUnit else { throw CaptureFailure.device }
                var device = selected.objectID
                guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw CaptureFailure.device }
            }
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate >= 8000, format.sampleRate <= 192000,
                  format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw CaptureFailure.format }
            sampleRate = format.sampleRate
            let ring = AudioRing(capacity: Int(sampleRate * 20), sampleLimit: UInt64(sampleRate * 300))
            self.ring = ring
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                // The real-time callback only copies channel zero into a fixed C ring.
                // No actors, file I/O, heap work, logs, or queued Task per callback.
                if let channel = buffer.floatChannelData?[0] { _ = ring.push(channel, count: Int(buffer.frameLength)) }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.onConfigurationChanged?()
                }
            }
            return ring
        } catch { stop(); throw error }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        ring?.close()
        engine = nil
        ring = nil
    }

    static func devices() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var result: Unmanaged<CFString>?
                var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &result) == noErr else { return nil }
                return result?.takeRetainedValue() as String?
            }
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            return MicrophoneDevice(id: uid, objectID: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum CaptureFailure: Error { case permission, device, format, protectedInput, targetChanged }
