import Foundation
import XCTest
@testable import MacCleaner

private actor ScanStartSignal {
    private var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        hasStarted = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private struct WaitingScanService: ScanServicing {
    let signal: ScanStartSignal

    func scan(
        _ request: ScanRequest,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResult {
        await signal.markStarted()
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}

private final class ProbeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

@MainActor
final class DiskAccessProbeSchedulingTests: XCTestCase {
    func testBackgroundAccessProbeDoesNotBlockTheMainActor() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerAccessProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let suiteName = "MacCleanerTests.AccessProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let noticeStore = ScanAccessAcknowledgementStore(defaults: defaults)
        noticeStore.accept()
        let model = ScanViewModel(
            scanNoticeStore: noticeStore,
            scanExclusionStore: ScanExclusionStore(defaults: defaults),
            savedScanFolderStore: SavedScanFolderStore(defaults: defaults),
            scanResultStore: ScanResultStore(directoryURL: temporaryDirectory.appendingPathComponent("review", isDirectory: true)),
            fullDiskAccessProbe: {
                Thread.sleep(forTimeInterval: 0.25)
                return true
            }
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        model.refreshDiskAccessStatusInBackground()
        let schedulingDuration = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThan(schedulingDuration, 0.1)
        for _ in 0..<40 where !model.standardFoldersChecked {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.standardFoldersChecked)
        XCTAssertTrue(model.standardFoldersAccessible)
    }

    func testStartingDiskScanDoesNotWaitForProtectedFolderProbe() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerScanProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let suiteName = "MacCleanerTests.ScanProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let noticeStore = ScanAccessAcknowledgementStore(defaults: defaults)
        noticeStore.accept()
        let desktopBookmarkStore = ICloudDesktopBookmarkStore(defaults: defaults)
        let scanStarted = ScanStartSignal()
        let probeCalls = ProbeCallCounter()
        let model = ScanViewModel(
            scanNoticeStore: noticeStore,
            scanExclusionStore: ScanExclusionStore(defaults: defaults),
            savedScanFolderStore: SavedScanFolderStore(defaults: defaults),
            scanResultStore: ScanResultStore(directoryURL: temporaryDirectory.appendingPathComponent("review", isDirectory: true)),
            iCloudDesktopBookmarkStore: desktopBookmarkStore,
            fullDiskAccessProbe: {
                probeCalls.increment()
                Thread.sleep(forTimeInterval: 0.25)
                return true
            },
            scanner: WaitingScanService(signal: scanStarted)
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        model.scanDisk(for: .smart)
        let schedulingDuration = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThan(schedulingDuration, 0.1)
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(probeCalls.value, 0, "A full-disk scan should not compete with a separate protected-folder probe.")
        XCTAssertFalse(desktopBookmarkStore.hasAskedForAccess, "Starting a scan should not open a Desktop permission dialog.")
        await scanStarted.waitUntilStarted()
        model.cancelScan()
        for _ in 0..<40 where model.isScanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isScanning)
    }

    func testBorrowingDiskAccessDoesNotWaitForProtectedFolderProbe() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerBorrowProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let suiteName = "MacCleanerTests.BorrowProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let noticeStore = ScanAccessAcknowledgementStore(defaults: defaults)
        noticeStore.accept()
        let model = ScanViewModel(
            scanNoticeStore: noticeStore,
            scanExclusionStore: ScanExclusionStore(defaults: defaults),
            savedScanFolderStore: SavedScanFolderStore(defaults: defaults),
            scanResultStore: ScanResultStore(directoryURL: temporaryDirectory.appendingPathComponent("review", isDirectory: true)),
            fullDiskAccessProbe: {
                Thread.sleep(forTimeInterval: 0.25)
                return true
            }
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let access = model.borrowDiskAccess()
        let schedulingDuration = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThan(schedulingDuration, 0.1)
        XCTAssertEqual(access?.path, "/")
        for _ in 0..<40 where !model.standardFoldersChecked {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.standardFoldersChecked)
        XCTAssertTrue(model.standardFoldersAccessible)
    }
}
