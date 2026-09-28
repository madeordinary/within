import Foundation
import WithinCore

/// One HTTPS GET to GitHub's public release list, only when the user asks or has chosen weekly
/// checks. Ephemeral session: no cookies, cache or credentials. The request carries no
/// dictation, notes, history, identifiers or usage data; GitHub sees the IP address and the
/// system's default user agent. Nothing is downloaded or installed automatically.
enum UpdateChecker {
    static let maximumResponseBytes = 2 * 1_048_576

    static func check(currentBuild: Int) async -> UpdateCheckResult {
        let url = UpdateCheck.releasesURL
        guard NetworkBoundary.permitsUpdateCheck(url) else { return .unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: RedirectBoundary(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, let final = http.url, NetworkBoundary.permitsUpdateCheck(final),
                  data.count <= maximumResponseBytes else { return .unavailable }
            return UpdateCheck.evaluate(statusCode: http.statusCode, data: data, currentBuild: currentBuild)
        } catch {
            return .unavailable
        }
    }
}

private final class RedirectBoundary: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, NetworkBoundary.permitsUpdateCheck(url) else { return nil }
        return request
    }
}
