import XCTest
@testable import MacCleaner

final class LocalDiskHealthServiceTests: XCTestCase {
    func testVerifiedStartupDiskStatusIsExplainedWithoutPromisingNoFutureFailure() throws {
        let report = LocalDiskHealthService.parse(try plist(status: "Verified"))

        XCTAssertEqual(report.state, .verified)
        XCTAssertTrue(report.state.explanation.localizedCaseInsensitiveContains("cannot predict"))
    }

    func testFailingStartupDiskStatusRecommendsBackupAndDiskUtility() throws {
        let report = LocalDiskHealthService.parse(try plist(status: "Failing"))

        XCTAssertEqual(report.state, .attention)
        XCTAssertTrue(report.state.explanation.localizedCaseInsensitiveContains("back up"))
        XCTAssertTrue(report.state.explanation.localizedCaseInsensitiveContains("Disk Utility"))
    }

    func testMissingAndUnrecognizedStatusesAreNotReported() throws {
        let missing = try PropertyListSerialization.data(
            fromPropertyList: ["VolumeName": "Macintosh HD"],
            format: .xml,
            options: 0
        )
        let unsupported = try plist(status: "Not Supported")

        XCTAssertEqual(LocalDiskHealthService.parse(nil).state, .unavailable)
        XCTAssertEqual(LocalDiskHealthService.parse(missing).state, .unavailable)
        XCTAssertEqual(LocalDiskHealthService.parse(unsupported).state, .unavailable)
    }

    func testSystemProbeReturnsOneStartupDiskReportWithoutAssumingItsState() async {
        let report = await LocalDiskHealthService().report()

        XCTAssertFalse(report.state.title.isEmpty)
        XCTAssertFalse(report.state.explanation.isEmpty)
    }

    private func plist(status: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["SMARTStatus": status],
            format: .xml,
            options: 0
        )
    }
}
