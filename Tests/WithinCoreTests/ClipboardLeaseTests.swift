import XCTest
@testable import WithinCore
final class ClipboardLeaseTests: XCTestCase {
    func testNewUserCopyMustNeverBeReplacedByRestoration() {
        let lease = ClipboardLease(ownedChangeCount: 44)
        XCTAssertTrue(lease.mayRestore(currentChangeCount: 44))
        XCTAssertFalse(lease.mayRestore(currentChangeCount: 45))
        XCTAssertFalse(lease.mayRestore(currentChangeCount: 100))
    }
}
