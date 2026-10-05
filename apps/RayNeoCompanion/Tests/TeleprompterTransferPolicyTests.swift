import XCTest
@testable import RayNeoCompanion

final class TeleprompterTransferPolicyTests: XCTestCase {
    func testRepeatedPrepareRequestStartsTheFileOnlyOnce() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertTrue(policy.fileRequestedBool)
        XCTAssertFalse(policy.fileSubmittedBool)
        XCTAssertEqual(policy.prepareReply(code: 1), .wait)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .wait)
        XCTAssertEqual(policy.prepareReply(code: 1), .wait)
        XCTAssertFalse(policy.businessCompleteBool)
        XCTAssertFalse(policy.fileCompleteBool)
    }

    func testBusinessCompletionBeforeFileRequestRejectsTheAttempt() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 7), .reject)
        XCTAssertFalse(policy.businessCompleteBool)
        XCTAssertEqual(policy.prepareReply(code: 1), .reject)
    }

    func testBusinessCompletionBeforeSuccessfulSubmissionRejectsTheAttempt() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertEqual(policy.prepareReply(code: 7), .reject)
        XCTAssertFalse(policy.businessCompleteBool)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .reject)
        XCTAssertEqual(policy.fileCompleted(success: true), .reject)
    }

    func testSDKCompletionWaitsForBusinessCompletion() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .wait)
        XCTAssertEqual(policy.fileCompleted(success: true), .wait)
        XCTAssertTrue(policy.fileCompleteBool)
        XCTAssertFalse(policy.businessCompleteBool)
        XCTAssertEqual(policy.prepareReply(code: 7), .ready)
        XCTAssertTrue(policy.businessCompleteBool)
    }

    func testBusinessCompletionWaitsForSDKCompletion() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .wait)
        XCTAssertEqual(policy.prepareReply(code: 7), .wait)
        XCTAssertTrue(policy.businessCompleteBool)
        XCTAssertFalse(policy.fileCompleteBool)
        XCTAssertEqual(policy.fileCompleted(success: true), .ready)
    }

    func testSynchronousSDKCompletionCannotBecomeReadyBeforeSendFileReturns() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertEqual(policy.fileCompleted(success: true), .wait)
        XCTAssertTrue(policy.fileCompleteBool)
        XCTAssertFalse(policy.fileSubmittedBool)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .wait)
        XCTAssertEqual(policy.prepareReply(code: 7), .ready)
    }

    func testDuplicateCompletionsAreIdempotentAndPrepareNeverStartsAgain() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .wait)
        XCTAssertEqual(policy.prepareReply(code: 7), .wait)
        XCTAssertEqual(policy.fileCompleted(success: true), .ready)
        XCTAssertEqual(policy.prepareReply(code: 7), .ready)
        XCTAssertEqual(policy.fileCompleted(success: true), .ready)
        XCTAssertEqual(policy.prepareReply(code: 1), .wait)
        XCTAssertTrue(policy.fileSubmittedBool)
        XCTAssertTrue(policy.businessCompleteBool)
        XCTAssertTrue(policy.fileCompleteBool)
    }

    func testFailedSDKCompletionCannotBeRevivedByBusinessCompletion() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .wait)
        XCTAssertEqual(policy.fileCompleted(success: false), .reject)
        XCTAssertFalse(policy.fileCompleteBool)
        XCTAssertEqual(policy.prepareReply(code: 7), .reject)
        XCTAssertEqual(policy.fileCompleted(success: true), .reject)
    }

    func testFileCompletionWithoutRequestRejects() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.fileCompleted(success: true), .reject)
        XCTAssertFalse(policy.fileCompleteBool)
        XCTAssertEqual(policy.prepareReply(code: 1), .reject)
    }

    func testSubmissionWithoutRequestRejects() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .reject)
        XCTAssertFalse(policy.fileSubmittedBool)
        XCTAssertEqual(policy.prepareReply(code: 1), .reject)
    }

    func testUnexpectedPrepareCodesReject() {
        for code in [-1, 0, 2, 3, 4, 8, 99] {
            var policy = TeleprompterTransferPolicy()
            XCTAssertEqual(policy.prepareReply(code: code), .reject, "code: \(code)")
            XCTAssertEqual(policy.prepareReply(code: 1), .reject)
        }
    }

    func testCancelCannotBeRevivedByDelayedCallbacks() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertFalse(policy.isTerminal)
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        policy.cancel()
        XCTAssertTrue(policy.isTerminal)
        XCTAssertEqual(policy.fileSubmissionSucceeded(), .reject)
        XCTAssertEqual(policy.fileCompleted(success: true), .reject)
        XCTAssertEqual(policy.prepareReply(code: 7), .reject)
        XCTAssertEqual(policy.prepareReply(code: 1), .reject)
    }

    func testNewAttemptDoesNotInheritReadinessOrFailure() {
        var policy = TeleprompterTransferPolicy()
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
        XCTAssertEqual(policy.fileCompleted(success: false), .reject)
        policy = TeleprompterTransferPolicy()
        XCTAssertFalse(policy.fileRequestedBool)
        XCTAssertFalse(policy.fileSubmittedBool)
        XCTAssertFalse(policy.businessCompleteBool)
        XCTAssertFalse(policy.fileCompleteBool)
        XCTAssertEqual(policy.prepareReply(code: 1), .startFile)
    }
}
