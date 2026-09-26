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
    private var stoppedEngine: AVAudioEngine?
    private var stoppedDeviceUID: String?
    private var activeDeviceUID = ""
    private var captureID: UUID?
    private var mayReuseEngine = false
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    var onConfigurationChanged: (() -> Void)?
    private(set) var ring: AudioRing?
    private(set) var sampleRate: Double = 0
    private(set) var lastConfigurationChange: AudioConfigurationObservation?

    func resetDiagnostics() { lastConfigurationChange = nil }

    func start(deviceUID: String, didReach: (RecordingStartupStage) -> Void = { _ in }) throws -> AudioRing {
        guard engine == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw CaptureFailure.permission }
        // Retain only an already-stopped object for the exact explicitly selected input.
        // The system-default route is rebuilt so an idle default-device change is honored.
        let engine: AVAudioEngine
        if !deviceUID.isEmpty, stoppedDeviceUID == deviceUID, let stoppedEngine, !stoppedEngine.isRunning {
            engine = stoppedEngine
        } else { engine = AVAudioEngine() }
        preventReuse()
        self.engine = engine
        let id = UUID(); captureID = id; activeDeviceUID = deviceUID
        didReach(.audioEngineCreated)
        do {
            let input = engine.inputNode
            guard let unit = input.audioUnit else { throw CaptureFailure.device }
            didReach(.audioInputReady)
            if !deviceUID.isEmpty {
                guard let selected = Self.devices().first(where: { $0.id == deviceUID }) else { throw CaptureFailure.device }
                // Reapplying the current device is unnecessary and may reconfigure the I/O unit.
                if Self.currentDevice(unit) != selected.objectID {
                    var device = selected.objectID
                    guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw CaptureFailure.device }
                }
                guard Self.currentDevice(unit) == selected.objectID else { throw CaptureFailure.device }
            }
            guard let initialDevice = Self.currentDevice(unit), Self.deviceIsAvailable(initialDevice) else { throw CaptureFailure.device }
            didReach(.audioDeviceSelected)
            let inputFormat = input.inputFormat(forBus: 0)
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
            didReach(.audioTapInstalled)
            engine.prepare()
            didReach(.audioEnginePrepared)
            try engine.start()
            mayReuseEngine = true
            didReach(.audioEngineStarted)
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
                // Return from AVFAudio's notification before querying or tearing down its engine.
                Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine, self.engine === engine, self.captureID == id else { return }
                    let input = engine.inputNode
                    let device = input.audioUnit.flatMap { Self.currentDevice($0) }
                    let observation = AudioConfigurationObservation(
                        engineRunning: engine.isRunning,
                        deviceUnchanged: device == initialDevice,
                        deviceAvailable: device.map { Self.deviceIsAvailable($0) } ?? false,
                        inputFormatUnchanged: input.inputFormat(forBus: 0).isEqual(inputFormat),
                        tapFormatUnchanged: input.outputFormat(forBus: 0).isEqual(format))
                    self.lastConfigurationChange = observation
                    // A queued notification alone does not establish that the active input changed.
                    // Never restart a stopped engine or switch devices within an active dictation.
                    if observation.requiresStop { self.preventReuse(); self.onConfigurationChanged?() }
                }
            }
            return ring
        } catch { stop(reusingStoppedEngine: false); throw error }
    }

    private static func currentDevice(_ unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                   0, &device, &size) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func deviceIsAvailable(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    func preventReuse() {
        stoppedEngine = nil; stoppedDeviceUID = nil; mayReuseEngine = false
    }

    func stop(reusingStoppedEngine: Bool = true) {
        captureID = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        ring?.close()
        if let engine {
            if reusingStoppedEngine, mayReuseEngine, !engine.isRunning, !activeDeviceUID.isEmpty {
                stoppedEngine = engine; stoppedDeviceUID = activeDeviceUID
            } else { preventReuse() }
        } else if !reusingStoppedEngine { preventReuse() }
        engine = nil
        ring = nil
        activeDeviceUID = ""; mayReuseEngine = false
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
