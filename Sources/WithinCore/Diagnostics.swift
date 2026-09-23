import Foundation

/// Closed schema: callers supply categories, never exception descriptions,
/// device names, paths, destination identities, audio, or transcript text.
public struct DiagnosticsReport: Encodable {
    public let schema = 1
    public let appVersion: String
    public let macOSVersion: String
    public let architecture: String
    public let microphonePermission: String
    public let accessibilityPermission: Bool
    public let shortcutRegistered: Bool
    public let microphoneSelection: String
    public let modelInstalled: Bool
    public let modelRevision: String
    public let modelVerificationPolicy = "Full pinned SHA-256 before every session"
    public let lastModelCheck: String
    public let lastErrorCode: String
    public let automaticUpdateChecks = false
    public let telemetry = false

    public init(appVersion: String, macOSVersion: String, architecture: String, microphonePermission: String,
                accessibilityPermission: Bool, shortcutRegistered: Bool, microphoneSelection: String,
                modelInstalled: Bool, modelRevision: String, lastModelCheck: String, lastErrorCode: String) {
        self.appVersion = appVersion; self.macOSVersion = macOSVersion; self.architecture = architecture
        self.microphonePermission = microphonePermission; self.accessibilityPermission = accessibilityPermission
        self.shortcutRegistered = shortcutRegistered; self.microphoneSelection = microphoneSelection
        self.modelInstalled = modelInstalled; self.modelRevision = modelRevision
        self.lastModelCheck = lastModelCheck; self.lastErrorCode = lastErrorCode
    }
    public func preview() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "Diagnostics unavailable" }
        return text
    }
}
