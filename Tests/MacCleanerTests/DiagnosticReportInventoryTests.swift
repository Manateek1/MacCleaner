import Foundation
import XCTest
@testable import MacCleaner

private final class DiagnosticReportTrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ path: String) {
        lock.lock()
        stored.append(path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class DiagnosticReportInventoryTests: XCTestCase {
    private var temporaryFolders: [URL] = []
    private let scanDate = Date()

    override func tearDownWithError() throws {
        for folder in temporaryFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        temporaryFolders.removeAll()
        try super.tearDownWithError()
    }

    func testListsOnlyRecognizedReportsOlderThanSelectedAge() throws {
        let root = try temporaryFolder()
        let oldLarge = try makeReport(in: root, name: "App-older.ips", bytes: 80, ageDays: 200)
        let oldSmall = try makeReport(in: root, name: "App-older.crash", bytes: 12, ageDays: 120)
        _ = try makeReport(in: root, name: "App-recent.ips", bytes: 21, ageDays: 20)
        try Data(repeating: 0xD0, count: 32).write(to: root.appendingPathComponent("not-a-report.log"))

        let result = DiagnosticReportInventoryService(reportRootURL: root).scan(olderThanDays: 90, now: scanDate)

        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.reports.map(\.name), ["App-older.ips", "App-older.crash"])
        XCTAssertEqual(result.reports.map(\.sizeBytes), [80, 12])
        XCTAssertEqual(result.recentReportsKept, 1)
        XCTAssertTrue(result.reports.allSatisfy(\.canMoveToTrash))
        XCTAssertEqual(try Data(contentsOf: oldLarge), Data(repeating: 0xA5, count: 80))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSmall.path))
    }

    func testSkipsSymbolicLinkReportsAndDoesNotCountExternalData() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        let secret = try makeReport(in: outside, name: "external.ips", bytes: 4096, ageDays: 300)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.ips"),
            withDestinationURL: secret
        )

        let result = DiagnosticReportInventoryService(reportRootURL: root).scan(now: scanDate)

        XCTAssertTrue(result.reports.isEmpty)
        XCTAssertGreaterThan(result.skippedLocations, 0)
        XCTAssertEqual(try Data(contentsOf: secret).count, 4096)
    }

    func testSafetyLimitLabelsThePartialReportInventory() throws {
        let root = try temporaryFolder()
        _ = try makeReport(in: root, name: "first.ips", bytes: 10, ageDays: 120)
        _ = try makeReport(in: root, name: "second.crash", bytes: 12, ageDays: 130)

        let result = DiagnosticReportInventoryService(reportRootURL: root, maximumEntries: 1).scan(now: scanDate)

        XCTAssertTrue(result.wasLimited)
        XCTAssertLessThan(result.reports.count, 2)
    }

    func testCancellationDoesNotClaimACompleteInventory() throws {
        let root = try temporaryFolder()
        _ = try makeReport(in: root, name: "older.ips", bytes: 10, ageDays: 120)

        let result = DiagnosticReportInventoryService(reportRootURL: root).scan(now: scanDate, isCancelled: { true })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.reports.isEmpty)
    }

    func testMissingReportFolderIsReportedWithoutRequestingAccess() throws {
        let home = try temporaryFolder()

        let result = DiagnosticReportInventoryService(homeURL: home).scan(now: scanDate)

        XCTAssertTrue(result.isAvailable)
        XCTAssertTrue(result.reports.isEmpty)
        XCTAssertTrue(result.message?.contains("No local DiagnosticReports") == true)
    }

    func testMovesOnlyReviewedUnchangedReportThroughInjectedTrashOperation() throws {
        let root = try temporaryFolder()
        let reportURL = try makeReport(in: root, name: "older.ips", bytes: 28, ageDays: 120)
        let recorder = DiagnosticReportTrashRecorder()
        let service = DiagnosticReportInventoryService(reportRootURL: root) { url in recorder.append(url.path) }
        let report = try XCTUnwrap(service.scan(now: scanDate).reports.first)

        let bytesMoved = try service.moveToTrash(report, olderThanDays: 90, now: scanDate)

        XCTAssertEqual(bytesMoved, 28)
        XCTAssertEqual(recorder.paths, [reportURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path), "The injected Trash operation records the request without changing fixture data.")
    }

    func testChangedReportIsNotMovedToTrash() throws {
        let root = try temporaryFolder()
        let reportURL = try makeReport(in: root, name: "older.ips", bytes: 28, ageDays: 120)
        let recorder = DiagnosticReportTrashRecorder()
        let service = DiagnosticReportInventoryService(reportRootURL: root) { url in recorder.append(url.path) }
        let report = try XCTUnwrap(service.scan(now: scanDate).reports.first)
        try FileHandle(forWritingTo: reportURL).write(contentsOf: Data("changed".utf8))

        XCTAssertThrowsError(try service.moveToTrash(report, olderThanDays: 90, now: scanDate)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed after it was reviewed"))
        }
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testReportThatNoLongerMeetsAgeCutoffStaysInPlace() throws {
        let root = try temporaryFolder()
        _ = try makeReport(in: root, name: "older.ips", bytes: 28, ageDays: 60)
        let recorder = DiagnosticReportTrashRecorder()
        let service = DiagnosticReportInventoryService(reportRootURL: root) { url in recorder.append(url.path) }
        let report = try XCTUnwrap(service.scan(olderThanDays: 30, now: scanDate).reports.first)

        XCTAssertThrowsError(try service.moveToTrash(report, olderThanDays: 180, now: scanDate)) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer than the selected age cutoff"))
        }
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testHardLinkedReportIsViewOnly() throws {
        let root = try temporaryFolder()
        let reportURL = try makeReport(in: root, name: "older.ips", bytes: 28, ageDays: 120)
        let secondLink = root.appendingPathComponent("second-link.ips")
        try FileManager.default.linkItem(at: reportURL, to: secondLink)
        let service = DiagnosticReportInventoryService(reportRootURL: root)
        let report = try XCTUnwrap(service.scan(now: scanDate).reports.first)

        XCTAssertFalse(report.canMoveToTrash)
        XCTAssertTrue(report.statusMessage?.contains("Hard-linked") == true)
        XCTAssertThrowsError(try service.moveToTrash(report, olderThanDays: 90, now: scanDate))
    }

    private func makeReport(in root: URL, name: String, bytes: Int, ageDays: Int) throws -> URL {
        let report = root.appendingPathComponent(name)
        try Data(repeating: 0xA5, count: bytes).write(to: report)
        let modifiedAt = scanDate.addingTimeInterval(-Double(ageDays) * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: report.path)
        return report
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryFolders.append(url)
        return url
    }
}
