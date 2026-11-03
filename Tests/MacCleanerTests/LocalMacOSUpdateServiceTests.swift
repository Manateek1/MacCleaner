import XCTest
@testable import MacCleaner

final class LocalMacOSUpdateServiceTests: XCTestCase {
    func testRecognizesAppleNoUpdatesMessages() {
        XCTAssertEqual(
            LocalMacOSUpdateService.parse(.completed(output: Self.data("No new software available."), status: 0)).state,
            .upToDate
        )
        XCTAssertEqual(
            LocalMacOSUpdateService.parse(.completed(output: Self.data("No updates are available."), status: 0)).state,
            .upToDate
        )
    }

    func testParsesAvailableUpdateTitleAndVersion() {
        let output = """
        Software Update found the following new or updated software:
          * Label: macOS Example 15.4-24E214
               Title: macOS Example 15.4, Version: 15.4, Size: 1503220KiB, Recommended: YES
        """

        XCTAssertEqual(
            LocalMacOSUpdateService.parse(.completed(output: Self.data(output), status: 0)).state,
            .updatesAvailable([LocalMacOSUpdateItem(title: "macOS Example 15.4", version: "15.4")])
        )
    }

    func testFallsBackToReadableUpdateLabelWhenTitleIsMissing() {
        let output = "* Label: Safari Security Update-1.0\n"

        XCTAssertEqual(
            LocalMacOSUpdateService.parse(.completed(output: Self.data(output), status: 0)).state,
            .updatesAvailable([LocalMacOSUpdateItem(title: "Safari Security Update-1.0", version: nil)])
        )
    }

    func testUnknownOutputAndFailedCommandStayNotReported() {
        XCTAssertEqual(
            LocalMacOSUpdateService.parse(.completed(output: Self.data("Software Update Tool"), status: 0)).state,
            .notReported
        )
        XCTAssertEqual(
            LocalMacOSUpdateService.parse(.completed(output: Self.data("No new software available."), status: 1)).state,
            .notReported
        )
        XCTAssertEqual(LocalMacOSUpdateService.parse(.failed).state, .notReported)
    }

    func testTimedOutCheckIsReportedClearly() {
        XCTAssertEqual(LocalMacOSUpdateService.parse(.timedOut).state, .timedOut)
    }

    func testInjectedProbeKeepsTestsOffline() async {
        let fixedDate = Date(timeIntervalSince1970: 100)
        let service = LocalMacOSUpdateService {
            .completed(output: Self.data("No new software available."), status: 0)
        }

        let report = await service.report(checkedAt: fixedDate)

        XCTAssertEqual(report.state, .upToDate)
        XCTAssertEqual(report.checkedAt, fixedDate)
    }

    private static func data(_ text: String) -> Data { Data(text.utf8) }
}
