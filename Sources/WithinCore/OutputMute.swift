import Foundation

/// Opt-in "mute this Mac's sound while dictating". Pure decisions; the app applies them.
/// Other apps keep playing silently. A call (another app using a microphone) is never muted.
public enum OutputMutePolicy {
    /// Apple system services that keep audio sessions open are not treated as calls; FaceTime is.
    static func isCallLike(_ client: AudioClientSnapshot) -> Bool {
        client.runningInput && (!client.bundleID.hasPrefix("com.apple.") || client.bundleID == "com.apple.FaceTime")
    }

    public static func shouldMute(enabled: Bool, clients: [AudioClientSnapshot], selfBundleID: String, deviceAlreadyMuted: Bool) -> Bool {
        guard enabled, !deviceAlreadyMuted else { return false }
        let others = clients.filter { $0.bundleID != selfBundleID }
        guard !others.contains(where: isCallLike) else { return false }
        return others.contains { $0.runningOutput }
    }

    /// Unmute only a device Within muted that is still muted; if the user already unmuted it, do nothing.
    public static func shouldRestore(record: OutputMuteRecord?, deviceStillMuted: Bool?) -> Bool {
        record != nil && deviceStillMuted == true
    }

    /// Best-effort recovery after a crash or forced quit: only recent records, only if still muted.
    public static let recoveryWindow: TimeInterval = 10 * 60
    public static func shouldRecoverAtLaunch(record: OutputMuteRecord?, deviceStillMuted: Bool?, now: Date) -> Bool {
        guard let record, deviceStillMuted == true else { return false }
        let age = now.timeIntervalSince(record.mutedAt)
        return age >= 0 && age < recoveryWindow
    }
}

/// What Within changed: which output device it muted and when. Holds no audio or content.
public struct OutputMuteRecord: Codable, Equatable, Sendable {
    public let deviceUID: String
    public let mutedAt: Date
    public init(deviceUID: String, mutedAt: Date) { self.deviceUID = deviceUID; self.mutedAt = mutedAt }
}
