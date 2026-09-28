import XCTest
@testable import WithinCore

final class NetworkBoundaryTests: XCTestCase {
    func testExpectedModelHosts() {
        for url in ["https://huggingface.co/a", "https://cdn-lfs.huggingface.co/a", "https://cas-bridge.xethub.hf.co/a"] {
            XCTAssertTrue(NetworkBoundary.permitsModelDownload(URL(string: url)!))
        }
    }
    func testRedirectBoundaryRejectsLookalikesCredentialsAndInsecureTransport() {
        for url in ["http://huggingface.co/a", "https://huggingface.co.evil.test/a", "https://evil-hf.co/a", "https://user:password@huggingface.co/a", "file:///tmp/model", "https://huggingface.co:444/a", "https://example.com/a"] {
            XCTAssertFalse(NetworkBoundary.permitsModelDownload(URL(string: url)!))
        }
    }
    func testUpdateCheckReachesOnlyThisRepositorysReleases() {
        XCTAssertTrue(NetworkBoundary.permitsUpdateCheck(UpdateCheck.releasesURL))
        for url in ["http://api.github.com/repos/madeordinary/within/releases", "https://api.github.com.evil.test/repos/madeordinary/within/releases",
                    "https://api.github.com/repos/someone/else/releases", "https://github.com/madeordinary/within/releases",
                    "https://user:pass@api.github.com/repos/madeordinary/within/releases", "https://api.github.com:444/repos/madeordinary/within/releases"] {
            XCTAssertFalse(NetworkBoundary.permitsUpdateCheck(URL(string: url)!))
        }
        XCTAssertFalse(NetworkBoundary.permitsModelDownload(UpdateCheck.releasesURL))
    }
}
