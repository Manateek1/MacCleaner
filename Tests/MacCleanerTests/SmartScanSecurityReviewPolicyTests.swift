import XCTest
@testable import MacCleaner

final class SmartScanSecurityReviewPolicyTests: XCTestCase {
    func testFullMacSmartScanIncludesAppSecurityReview() {
        XCTAssertTrue(
            SmartScanSecurityReviewPolicy.shouldRunAppSecurity(
                kind: .smart,
                root: URL(fileURLWithPath: "/", isDirectory: true)
            )
        )
    }

    func testSpecificFolderSmartScanDoesNotRunMacWideAppSecurityReview() {
        XCTAssertFalse(
            SmartScanSecurityReviewPolicy.shouldRunAppSecurity(
                kind: .smart,
                root: URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)
            )
        )
    }

    func testFileCategoryScansDoNotRunAppSecurityReview() {
        for kind in [ScanKind.largeAndOld, .duplicates, .junk, .aiClutter] {
            XCTAssertFalse(
                SmartScanSecurityReviewPolicy.shouldRunAppSecurity(
                    kind: kind,
                    root: URL(fileURLWithPath: "/", isDirectory: true)
                ),
                "\(kind.title) should remain focused on its own file review."
            )
        }
    }
}
