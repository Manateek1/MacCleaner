import Foundation
import XCTest
@testable import MacCleaner

final class XcodeArchiveInventoryTests: XCTestCase {
    private var temporaryFolders: [URL] = []

    override func tearDownWithError() throws {
        for folder in temporaryFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        temporaryFolders.removeAll()
        try super.tearDownWithError()
    }

    func testFindsDirectAndDateGroupedArchivesAndOnlyReadsMetadata() throws {
        let root = try temporaryFolder()
        let grouped = root.appendingPathComponent("2026-10-30/Build 1.xcarchive", isDirectory: true)
        let direct = root.appendingPathComponent("Build 2.xcarchive", isDirectory: true)
        try FileManager.default.createDirectory(at: grouped, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: direct, withIntermediateDirectories: true)
        let groupedPayload = grouped.appendingPathComponent("Products/Applications/App.app/Contents/MacOS/App")
        try FileManager.default.createDirectory(at: groupedPayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA1, count: 41).write(to: groupedPayload)
        try Data(repeating: 0xB2, count: 13).write(to: direct.appendingPathComponent("Info.plist"))
        let unrelated = root.appendingPathComponent("notes.txt")
        try Data("leave me alone".utf8).write(to: unrelated)

        let result = XcodeArchiveInventoryService(archiveRootURL: root).scan()

        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.archives.map(\.name), ["Build 1", "Build 2"])
        XCTAssertEqual(result.archives.map(\.sizeBytes), [41, 13])
        XCTAssertEqual(result.archives.map(\.fileCount), [1, 1])
        XCTAssertTrue(result.archives.allSatisfy(\.isComplete))
        XCTAssertTrue(result.archives.allSatisfy { $0.removalPlan != nil })
        XCTAssertEqual(try Data(contentsOf: groupedPayload), Data(repeating: 0xA1, count: 41))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testDoesNotCountDataOutsideArchiveThroughSymbolicLink() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        let archive = root.appendingPathComponent("Build.xcarchive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let externalFile = outside.appendingPathComponent("large.bin")
        try Data(repeating: 0xC3, count: 4096).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: archive.appendingPathComponent("linked-data", isDirectory: true),
            withDestinationURL: outside
        )

        let result = XcodeArchiveInventoryService(archiveRootURL: root).scan()

        let item = try XCTUnwrap(result.archives.first)
        XCTAssertEqual(item.sizeBytes, 0)
        XCTAssertFalse(item.isComplete)
        XCTAssertGreaterThan(item.skippedEntries, 0)
        XCTAssertNil(item.removalPlan)
    }

    func testReportsMissingStandardFolderWithoutRequestingAccess() throws {
        let home = try temporaryFolder()

        let result = XcodeArchiveInventoryService(homeURL: home).scan()

        XCTAssertTrue(result.isAvailable)
        XCTAssertTrue(result.archives.isEmpty)
        XCTAssertTrue(result.message?.contains("No local Xcode Archives") == true)
    }

    func testMarksArchiveIncompleteWhenSafetyEntryLimitIsReached() throws {
        let root = try temporaryFolder()
        let archive = root.appendingPathComponent("2026-10-30/Build.xcarchive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: archive.appendingPathComponent("one.bin"))
        try Data("two".utf8).write(to: archive.appendingPathComponent("two.bin"))

        let result = XcodeArchiveInventoryService(archiveRootURL: root, maximumEntries: 3).scan()

        XCTAssertTrue(result.wasLimited)
        let item = try XCTUnwrap(result.archives.first)
        XCTAssertFalse(item.isComplete)
    }

    func testCancellationDoesNotClaimCompleteInventory() throws {
        let root = try temporaryFolder()
        _ = try makeArchive(in: root, name: "Build.xcarchive")

        let result = XcodeArchiveInventoryService(archiveRootURL: root).scan(isCancelled: { true })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.archives.isEmpty)
    }

    func testSymlinkedArchiveRootIsNotOpened() throws {
        let root = try temporaryFolder()
        let actual = try temporaryFolder()
        _ = try makeArchive(in: actual, name: "Build.xcarchive")
        let link = root.appendingPathComponent("Archives", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)

        let result = XcodeArchiveInventoryService(archiveRootURL: link).scan()

        XCTAssertFalse(result.isAvailable)
        XCTAssertTrue(result.archives.isEmpty)
        XCTAssertTrue(result.message?.contains("symbolic link") == true)
    }

    func testSymlinkedDateFolderIsNotTraversed() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        _ = try makeArchive(in: outside, name: "Hidden.xcarchive")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("2026-10-30", isDirectory: true),
            withDestinationURL: outside
        )

        let result = XcodeArchiveInventoryService(archiveRootURL: root).scan()

        XCTAssertTrue(result.archives.isEmpty)
        XCTAssertEqual(result.skippedLocations, 1)
        XCTAssertEqual(result.message, "No Xcode archives were found in the standard local Archives folder.")
    }

    func testMovesReviewedArchiveToTrashAfterRecheckingTheWholeBundle() throws {
        let home = try temporaryFolder()
        let archiveRoot = standardArchiveRoot(in: home)
        let archive = try makeArchive(in: archiveRoot, name: "Build.xcarchive")
        let secondArchive = try makeArchive(in: archiveRoot, name: "Build 2.xcarchive")
        let trash = home.appendingPathComponent("Test Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let scannedArchives = XcodeArchiveInventoryService(homeURL: home).scan().archives
        let scanned = try XCTUnwrap(scannedArchives.first { $0.name == "Build" })
        let scannedSecondArchive = try XCTUnwrap(scannedArchives.first { $0.name == "Build 2" })
        XCTAssertNotNil(scanned.removalPlan)
        XCTAssertNotNil(scannedSecondArchive.removalPlan)

        let service = XcodeArchiveRemovalService(homeURL: home) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let result = service.moveToTrash([scanned, scanned, scannedSecondArchive])

        XCTAssertEqual(result.movedPaths, [scanned.path, scannedSecondArchive.path].sorted())
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.bytesMoved, scanned.sizeBytes + scannedSecondArchive.sizeBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondArchive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Build.xcarchive").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Build 2.xcarchive").path))
    }

    func testCompleteArchiveAboveRemovalSnapshotLimitStaysViewOnly() throws {
        let home = try temporaryFolder()
        _ = try makeArchive(in: standardArchiveRoot(in: home), name: "Large.xcarchive")

        let record = try XCTUnwrap(
            XcodeArchiveInventoryService(homeURL: home, maximumRemovalSnapshotEntries: 1)
                .scan().archives.first { $0.name == "Large" }
        )

        XCTAssertTrue(record.isComplete)
        XCTAssertFalse(record.canMoveToTrash)
        XCTAssertNil(record.removalPlan)
    }

    func testChangedArchiveContentsAreLeftInPlace() throws {
        let home = try temporaryFolder()
        let archiveRoot = standardArchiveRoot(in: home)
        let archive = try makeArchive(in: archiveRoot, name: "Build.xcarchive")
        let item = try XCTUnwrap(XcodeArchiveInventoryService(homeURL: home).scan().archives.first)
        try Data(repeating: 7, count: 64).write(to: archive.appendingPathComponent("payload.bin"), options: .atomic)
        let moved = LockedPathList()

        let result = XcodeArchiveRemovalService(homeURL: home) { url in moved.append(url.path) }
            .moveToTrash([item])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(moved.paths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testArchiveThatBecomesLinkedAfterScanIsLeftInPlace() throws {
        let home = try temporaryFolder()
        let archive = try makeArchive(in: standardArchiveRoot(in: home), name: "Build.xcarchive")
        let item = try XCTUnwrap(XcodeArchiveInventoryService(homeURL: home).scan().archives.first)
        let payload = archive.appendingPathComponent("payload.bin")
        let externalFile = home.appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: externalFile)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: externalFile)
        let moved = LockedPathList()

        let result = XcodeArchiveRemovalService(homeURL: home) { url in moved.append(url.path) }
            .moveToTrash([item])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(moved.paths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try Data(contentsOf: externalFile), Data("outside".utf8))
    }

    func testArchivesWithHardLinkedFilesCannotBeSelectedForCleanup() throws {
        let home = try temporaryFolder()
        let archiveRoot = standardArchiveRoot(in: home)
        let archive = try makeArchive(in: archiveRoot, name: "Build.xcarchive")
        let externalCopy = home.appendingPathComponent("outside.bin")
        try FileManager.default.linkItem(at: archive.appendingPathComponent("payload.bin"), to: externalCopy)

        let result = XcodeArchiveInventoryService(homeURL: home).scan()

        XCTAssertTrue(result.archives.first?.isComplete == true)
        XCTAssertNil(result.archives.first?.removalPlan)
    }

    @discardableResult
    private func makeArchive(in root: URL, name: String) throws -> URL {
        let archive = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("test payload".utf8).write(to: archive.appendingPathComponent("payload.bin"))
        return archive
    }

    private func standardArchiveRoot(in home: URL) -> URL {
        home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryFolders.append(url)
        return url
    }
}

private final class LockedPathList: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ path: String) {
        lock.lock()
        storage.append(path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
