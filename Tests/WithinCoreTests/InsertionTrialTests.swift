import XCTest
@testable import WithinCore

final class InsertionTrialTests: XCTestCase {
    func testSuccessfulWriteReleasesPendingText() {
        var trial = InsertionTrial()
        XCTAssertTrue(trial.begin(text: "Synthetic sample"))
        XCTAssertTrue(trial.authorize(TargetEvidence()))
        trial.completeWrite(confirmed: true)
        XCTAssertEqual(trial.phase, .inserted)
        XCTAssertNil(trial.pendingText)
    }

    func testEverySafetyBoundaryPreventsWriteAndPreservesWords() {
        let cases: [(TargetEvidence, RecoveryReason)] = [
            (.init(permissionGranted: false), .permissionRequired),
            (.init(targetAlive: false), .targetUnavailable),
            (.init(sameApplication: false), .focusChanged),
            (.init(sameWindow: false), .focusChanged),
            (.init(sameElement: false), .focusChanged),
            (.init(focusChanged: true), .focusChanged),
            (.init(secure: true), .secureField),
            (.init(secure: nil), .unknownSafety),
            (.init(canReplaceSelection: false), .unsupported)
        ]
        for (evidence, reason) in cases {
            var trial = InsertionTrial()
            trial.begin(text: "Keep these words")
            XCTAssertFalse(trial.authorize(evidence), "\(reason)")
            XCTAssertEqual(trial.phase, .recovery(reason))
            XCTAssertEqual(trial.pendingText, "Keep these words")
        }
    }

    func testSecondActivationCannotReplacePendingRecovery() {
        var trial = InsertionTrial()
        trial.begin(text: "First")
        XCTAssertFalse(trial.begin(text: "During preparation"))
        trial.authorize(.init(sameElement: false))
        XCTAssertFalse(trial.begin(text: "Second"))
        XCTAssertEqual(trial.pendingText, "First")
    }

    func testReturnRequiresUserActionAndFreshMatchingTarget() {
        var trial = InsertionTrial()
        trial.begin(text: "First")
        trial.authorize(.init(sameElement: false))
        XCTAssertFalse(trial.authorize(.init()))
        XCTAssertFalse(trial.authorize(.init(sameWindow: false), explicitReturn: true))
        XCTAssertTrue(trial.authorize(.init(), explicitReturn: true))
    }

    func testUncertainWriteCannotBeRetriedEvenExplicitly() {
        var trial = InsertionTrial()
        trial.begin(text: "Possibly inserted")
        trial.authorize(.init())
        trial.completeWrite(confirmed: false)
        XCTAssertEqual(trial.phase, .recovery(.uncertainWrite))
        XCTAssertFalse(trial.authorize(.init(), explicitReturn: true))
        XCTAssertEqual(trial.pendingText, "Possibly inserted")
    }

    func testSecureFieldCannotBeOverriddenByReturn() {
        var trial = InsertionTrial()
        trial.begin(text: "Private")
        trial.authorize(.init(secure: true))
        XCTAssertFalse(trial.authorize(.init(), explicitReturn: true))
    }

    func testDiscardAndEmptyInput() {
        var trial = InsertionTrial()
        XCTAssertFalse(trial.begin(text: " \n "))
        XCTAssertEqual(trial.phase, .ready)
        trial.begin(text: "Sample")
        trial.discard()
        XCTAssertNil(trial.pendingText)
        XCTAssertFalse(trial.authorize(.init()))
        XCTAssertTrue(trial.begin(text: "Next"))
    }

    func testDuplicateCompletionDoesNotResurrectText() {
        var trial = InsertionTrial()
        trial.begin(text: "Sample")
        trial.authorize(.init())
        trial.completeWrite(confirmed: true)
        trial.completeWrite(confirmed: false)
        XCTAssertEqual(trial.phase, .inserted)
        XCTAssertNil(trial.pendingText)
    }
}
