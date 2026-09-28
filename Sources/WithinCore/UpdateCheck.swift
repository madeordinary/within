import Foundation

/// A published build on GitHub Releases. Tags follow `v<version>-build<number>`, e.g. `v0.1.0-build12`.
public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let title: String
    public let notes: String
    public let pageURL: URL
    public let build: Int
    public let prerelease: Bool
    public init(tag: String, title: String, notes: String, pageURL: URL, build: Int, prerelease: Bool) {
        self.tag = tag; self.title = title; self.notes = notes; self.pageURL = pageURL; self.build = build; self.prerelease = prerelease
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(currentBuild: Int)
    case available(ReleaseInfo)
    case noReleases
    case unavailable
}

/// Update checks are explicit or opt-in. A check is one HTTPS GET to GitHub's public release
/// list for this repository; it sends no dictation, notes, history, identifiers, or usage data.
public enum UpdateCheck {
    public static let releasesURL = URL(string: "https://api.github.com/repos/madeordinary/within/releases?per_page=20")!
    static let maximumNotesLength = 2_000

    public static func build(fromTag tag: String) -> Int? {
        guard let range = tag.range(of: #"-build(\d+)$"#, options: .regularExpression) else { return nil }
        return Int(tag[range].dropFirst("-build".count))
    }

    /// Picks the highest published build. Drafts, unparseable tags and non-GitHub pages are
    /// ignored, and an older or equal build never counts as an update.
    public static func evaluate(statusCode: Int, data: Data, currentBuild: Int) -> UpdateCheckResult {
        guard statusCode == 200,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return .unavailable }
        let releases: [ReleaseInfo] = entries.compactMap { entry in
            guard entry["draft"] as? Bool != true,
                  let tag = entry["tag_name"] as? String, let build = build(fromTag: tag),
                  let page = (entry["html_url"] as? String).flatMap(URL.init(string:)),
                  page.scheme == "https", page.host?.lowercased() == "github.com" else { return nil }
            let notes = String((entry["body"] as? String ?? "").prefix(maximumNotesLength))
            return ReleaseInfo(tag: tag, title: entry["name"] as? String ?? tag, notes: notes, pageURL: page,
                               build: build, prerelease: entry["prerelease"] as? Bool ?? false)
        }
        guard let newest = releases.max(by: { $0.build < $1.build }) else { return .noReleases }
        return newest.build > currentBuild ? .available(newest) : .upToDate(currentBuild: currentBuild)
    }

    public static let weeklyInterval: TimeInterval = 7 * 86_400
    /// Automatic checks run only when chosen, at most once a week.
    public static func automaticCheckDue(enabled: Bool?, lastCheck: Date?, now: Date) -> Bool {
        guard enabled == true else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= weeklyInterval || now < lastCheck
    }
}
