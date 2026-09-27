import Foundation

/// Per-mode capture bounds. Dictation keeps its short-session limits exactly;
/// longer modes record as a sequence of bounded segments instead of loosening them.
public struct CaptureLimits: Equatable, Sendable {
    /// Total audio accepted by one capture ring before it closes itself.
    public let totalSeconds: Double
    /// Unprocessed audio the ring can hold while speech processing catches up.
    public let backlogSeconds: Double

    public init(totalSeconds: Double, backlogSeconds: Double) {
        self.totalSeconds = totalSeconds; self.backlogSeconds = backlogSeconds
    }

    public static let dictation = CaptureLimits(totalSeconds: 300, backlogSeconds: 20)
    /// One note recording. A faster-than-real-time 180-minute fixture soak (Sep 27, M5 Pro)
    /// stayed near 90–95 MB after model load; longer thoughts continue with another Record.
    public static let note = CaptureLimits(totalSeconds: 3 * 3600, backlogSeconds: 20)

    public func ringCapacity(sampleRate: Double) -> Int { Int(sampleRate * backlogSeconds) }
    public func sampleLimit(sampleRate: Double) -> UInt64 { UInt64(sampleRate * totalSeconds) }
}
