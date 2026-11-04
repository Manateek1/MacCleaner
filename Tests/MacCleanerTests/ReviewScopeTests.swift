import XCTest
@testable import MacCleaner

final class ReviewScopeTests: XCTestCase {
    func testSpecializedToolsExcludeUnrelatedSmartScanFindings() {
        XCTAssertFalse(ScanKind.duplicates.includesInReview(categories: [.largeFile]))
        XCTAssertFalse(ScanKind.largeAndOld.includesInReview(categories: [.exactDuplicate]))
        XCTAssertFalse(ScanKind.junk.includesInReview(categories: [.aiCacheCandidate]))
        XCTAssertFalse(ScanKind.aiClutter.includesInReview(categories: [.cacheCandidate]))
    }

    func testMatchingAndMixedFindingsRemainInTheirTools() {
        XCTAssertTrue(ScanKind.smart.includesInReview(categories: [.largeFile, .exactDuplicate]))
        XCTAssertTrue(ScanKind.largeAndOld.includesInReview(categories: [.oldFile]))
        XCTAssertTrue(ScanKind.duplicates.includesInReview(categories: [.largeFile, .exactDuplicate]))
        XCTAssertTrue(ScanKind.junk.includesInReview(categories: [.oldFile, .cacheCandidate]))
        XCTAssertTrue(ScanKind.aiClutter.includesInReview(categories: [.aiCacheCandidate]))
    }
}
