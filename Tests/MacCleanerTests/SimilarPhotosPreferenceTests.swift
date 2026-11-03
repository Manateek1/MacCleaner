import XCTest
@testable import MacCleaner

final class SimilarPhotosPreferenceTests: XCTestCase {
    func testToleranceIsClampedAndNonFiniteValuesUseTheDefault() {
        XCTAssertEqual(SimilarPhotosPreference.normalizedTolerance(-1), 0)
        XCTAssertEqual(SimilarPhotosPreference.normalizedTolerance(12.8), 12)
        XCTAssertEqual(SimilarPhotosPreference.normalizedTolerance(7.6), 8)
        XCTAssertEqual(SimilarPhotosPreference.normalizedTolerance(.nan), 6)
        XCTAssertEqual(SimilarPhotosPreference.normalizedTolerance(.infinity), 6)
    }

    func testToleranceLabelsExplainTheMatchRange() {
        XCTAssertEqual(SimilarPhotosPreference.label(for: 0), "Strict")
        XCTAssertEqual(SimilarPhotosPreference.label(for: 6), "Balanced")
        XCTAssertEqual(SimilarPhotosPreference.label(for: 9), "More matches")
    }
}
