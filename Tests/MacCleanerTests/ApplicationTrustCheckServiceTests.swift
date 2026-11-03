import Security
import XCTest
@testable import MacCleaner

final class ApplicationTrustCheckServiceTests: XCTestCase {
    func testCancellationStopsBeforeInspectingTheApplication() {
        let result = ApplicationTrustCheckService().check(
            appURL: URL(fileURLWithPath: "/not-a-real-app.app"),
            isCancelled: { true }
        )

        XCTAssertEqual(result.status, .cancelled)
    }

    func testOnlyAppBundlesCanBeChecked() {
        let result = ApplicationTrustCheckService().check(
            appURL: URL(fileURLWithPath: "/System/Applications/Calculator")
        )

        XCTAssertEqual(result.status, .couldNotVerify)
    }

    func testPassingCodeCheckReportsOnlyThatMacOSValidationPassed() {
        let result = ApplicationTrustCheckService.classify(validityStatus: errSecSuccess, hasStapledTicket: true)

        XCTAssertEqual(result.status, .validated)
        XCTAssertEqual(result.hasStapledNotarizationTicket, true)
        XCTAssertTrue(result.explanation.contains("does not determine whether its behavior is safe"))
    }

    func testRevokedNotarizationIsDistinctFromOtherValidationFailures() {
        let result = ApplicationTrustCheckService.classify(
            validityStatus: errSecCSRevokedNotarization,
            hasStapledTicket: false
        )

        XCTAssertEqual(result.status, .notarizationRevoked)
        XCTAssertEqual(result.hasStapledNotarizationTicket, false)
        XCTAssertTrue(result.explanation.contains("was revoked"))
    }

    func testUnsignedAppIsNotDescribedAsMalware() {
        let result = ApplicationTrustCheckService.classify(validityStatus: errSecCSUnsigned, hasStapledTicket: false)

        XCTAssertEqual(result.status, .unsigned)
        XCTAssertTrue(result.explanation.contains("does not mean the app is harmful"))
    }

    func testUnknownValidationFailureRemainsInconclusive() {
        let result = ApplicationTrustCheckService.classify(validityStatus: errSecCSBadResource, hasStapledTicket: false)

        XCTAssertEqual(result.status, .couldNotVerify)
        XCTAssertTrue(result.explanation.contains("could not complete"))
    }

    func testOnlineValidationUsesAllArchitectureAndNestedCodeFlags() {
        let flags = ApplicationTrustCheckService.networkValidationFlags.rawValue

        XCTAssertNotEqual(flags & kSecCSCheckAllArchitectures, 0)
        XCTAssertNotEqual(flags & kSecCSStrictValidate, 0)
        XCTAssertNotEqual(flags & kSecCSCheckNestedCode, 0)
        XCTAssertNotEqual(flags & kSecCSAllowNetworkAccess, 0)
    }
}
