import XCTest
@testable import MacCleaner

final class DiagnosticsExportTests: XCTestCase {
    func testExportContainsOnlyAllowlistedSettingsAndAggregateScanTotals() throws {
        let privateRoot = "/Users/tester/Library/PrivateProject"
        let privateFile = "/Users/tester/Documents/PrivateProject/payroll.xlsx"
        let item = ScanItem(
            path: privateFile,
            identity: FileIdentity(device: 1, inode: 2, size: 100, modifiedAt: 1_700_000_000, linkCount: 1),
            lastAccessedAt: nil,
            isCloudManaged: nil,
            categories: [.largeFile],
            reasons: [],
            safetyNote: "Review",
            confidence: 0.25,
            duplicateGroupID: nil,
            duplicateGroupCount: 0,
            suggestedKeepPath: nil,
            cacheReviewDetails: nil
        )
        let scan = ScanResult(
            kind: .smart,
            rootPath: privateRoot,
            filesVisited: 17,
            entriesVisited: 29,
            entryLimit: 1_000_000,
            bytesVisited: 456_789,
            skippedItems: 3,
            skippedLocations: ["\(privateRoot)/Unreadable"],
            cloudFilesNotLocallyAvailable: nil,
            cloudFilesLocallyAvailable: nil,
            cloudDesktopAccessUnavailable: nil,
            excludedLocations: ["\(privateRoot)/ExcludedFolder"],
            items: [item],
            finishedAt: Date(timeIntervalSince1970: 1_700_000_100),
            wasTruncated: false,
            space: nil,
            duplicateKeepPreference: .oldest
        )

        let report = MacCleanerDiagnosticsExportService.makeReport(
            appVersion: "0.3.33",
            appBuild: "36",
            macOSVersion: "26.6.2",
            processorArchitecture: "Apple silicon",
            scanNoticeAccepted: true,
            standardFoldersAccessible: true,
            minimumFileSizeMB: 500,
            olderFileThresholdDays: 180,
            lastScan: scan,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let data = try MacCleanerDiagnosticsExportService.encode(report)
        let encodedText = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacCleanerDiagnosticsReport.self, from: data)

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(report.lastScan?.filesChecked, 17)
        XCTAssertEqual(report.lastScan?.entriesChecked, 29)
        XCTAssertEqual(report.lastScan?.bytesChecked, 456_789)
        XCTAssertEqual(report.lastScan?.findingsCount, 1)
        XCTAssertEqual(report.lastScan?.excludedFolderCount, 1)
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("/Users/"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("tester"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("payroll.xlsx"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("PrivateProject"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("\(privateRoot)/ExcludedFolder"))
    }

    func testExportWithoutPreviousScanLeavesScanSummaryEmpty() throws {
        let report = MacCleanerDiagnosticsExportService.makeReport(
            appVersion: "0.3.33",
            appBuild: "36",
            macOSVersion: "26.6.2",
            processorArchitecture: "Apple silicon",
            scanNoticeAccepted: false,
            standardFoldersAccessible: false,
            minimumFileSizeMB: 0,
            olderFileThresholdDays: -1,
            lastScan: nil
        )

        XCTAssertNil(report.lastScan)
        XCTAssertEqual(report.minimumFileSizeMB, 1)
        XCTAssertEqual(report.olderFileThresholdDays, 1)
    }
}
