import Foundation

/// Installed only by the developer fixture command, never by the GUI.
final class OfflineProbe: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var attempts = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempts += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
