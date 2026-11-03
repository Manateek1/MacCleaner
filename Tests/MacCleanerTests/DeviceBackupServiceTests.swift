import Foundation
import XCTest
@testable import MacCleaner

private final class DeviceBackupTrashRecorder: @unchecked Sendable {
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

final class DeviceBackupServiceTests: XCTestCase {
    func testInventoryShowsOnlyMetadataForRecognizedAndIncompleteFolders() throws {
        let root = try temporaryFolder()
        let complete = root.appendingPathComponent("a1b2c3", isDirectory: true)
        let incomplete = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: complete.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("metadata placeholder".utf8).write(to: complete.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x1, count: 128).write(to: complete.appendingPathComponent("Manifest.db"))
        try Data(repeating: 0x2, count: 512).write(to: complete.appendingPathComponent("nested/device-data.bin"))
        try Data(repeating: 0x3, count: 7).write(to: incomplete.appendingPathComponent("random.bin"))

        let result = DeviceBackupService(backupRootURL: root).scan()

        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.backups.count, 2)
        let recognized = try XCTUnwrap(result.backups.first { $0.name == "a1b2c3" })
        XCTAssertEqual(recognized.sizeBytes, Int64("metadata placeholder".utf8.count + 128 + 512))
        XCTAssertEqual(recognized.fileCount, 3)
        XCTAssertTrue(recognized.isRecognizedBackup)
        XCTAssertTrue(recognized.canMoveToTrash)
        XCTAssertNil(recognized.statusMessage)
        let unrecognized = try XCTUnwrap(result.backups.first { $0.name == "unrelated" })
        XCTAssertFalse(unrecognized.isRecognizedBackup)
        XCTAssertFalse(unrecognized.canMoveToTrash)
        XCTAssertNotNil(unrecognized.statusMessage)
    }

    func testDoesNotFollowSymlinkAndMakesBackupViewOnly() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("".utf8).write(to: backup.appendingPathComponent("Info.plist"))
        try Data("".utf8).write(to: backup.appendingPathComponent("Manifest.db"))
        let secret = outside.appendingPathComponent("secret.bin")
        try Data(repeating: 0x7, count: 4096).write(to: secret)
        try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("linked-data"), withDestinationURL: outside)

        let result = DeviceBackupService(backupRootURL: root).scan()
        let item = try XCTUnwrap(result.backups.first)

        XCTAssertEqual(item.sizeBytes, 0)
        XCTAssertFalse(item.canMoveToTrash)
        XCTAssertTrue(item.statusMessage?.contains("could not be checked") == true)
    }

    func testSafetyLimitMakesBackupViewOnly() throws {
        let root = try temporaryFolder()
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("".utf8).write(to: backup.appendingPathComponent("Info.plist"))
        try Data("".utf8).write(to: backup.appendingPathComponent("Manifest.db"))
        try Data("one".utf8).write(to: backup.appendingPathComponent("one.bin"))
        try Data("two".utf8).write(to: backup.appendingPathComponent("two.bin"))

        let result = DeviceBackupService(backupRootURL: root, maximumEntriesPerBackup: 2).scan()
        let item = try XCTUnwrap(result.backups.first)

        XCTAssertTrue(result.wasLimited)
        XCTAssertFalse(item.canMoveToTrash)
        XCTAssertTrue(item.statusMessage?.contains("safely verify") == true)
    }

    func testSafetyLimitCountsSymlinkEntries() throws {
        let root = try temporaryFolder()
        let backup = try makeRecognizedBackup(in: root, name: "device-backup")
        let target = try temporaryFolder().appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: target)
        for index in 0..<5 {
            try FileManager.default.createSymbolicLink(
                at: backup.appendingPathComponent("link-\(index)"),
                withDestinationURL: target
            )
        }

        let result = DeviceBackupService(backupRootURL: root, maximumEntriesPerBackup: 3).scan()
        let item = try XCTUnwrap(result.backups.first)

        XCTAssertTrue(result.wasLimited)
        XCTAssertFalse(item.canMoveToTrash)
    }

    func testTotalEntryLimitDoesNotOfferPartialBackupsForCleanup() throws {
        let root = try temporaryFolder()
        _ = try makeRecognizedBackup(in: root, name: "backup-one")
        _ = try makeRecognizedBackup(in: root, name: "backup-two")

        let result = DeviceBackupService(
            backupRootURL: root,
            maximumEntriesPerBackup: 100,
            maximumTotalEntries: 5
        ).scan()

        XCTAssertTrue(result.wasLimited)
        XCTAssertEqual(result.backups.count, 2)
        XCTAssertEqual(result.backups.filter(\.canMoveToTrash).count, 1)
        XCTAssertEqual(result.backups.filter { !$0.canMoveToTrash }.count, 1)
    }

    func testMovesOnlyReviewedUnchangedBackupThroughInjectedTrashOperation() throws {
        let root = try temporaryFolder()
        let backup = try makeRecognizedBackup(in: root, name: "device-backup")
        let recorder = DeviceBackupTrashRecorder()
        let service = DeviceBackupService(backupRootURL: root) { url in recorder.append(url.path) }
        let item = try XCTUnwrap(service.scan().backups.first)

        let result = try service.moveToTrash(item)

        XCTAssertEqual(result.path, backup.path)
        XCTAssertEqual(result.sizeBytes, item.sizeBytes)
        XCTAssertEqual(recorder.paths, [backup.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "The test operation records the request without changing fixture data.")
    }

    func testChangedBackupIsNotMovedToTrash() throws {
        let root = try temporaryFolder()
        let backup = try makeRecognizedBackup(in: root, name: "device-backup")
        let recorder = DeviceBackupTrashRecorder()
        let service = DeviceBackupService(backupRootURL: root) { url in recorder.append(url.path) }
        let item = try XCTUnwrap(service.scan().backups.first)
        try Data(repeating: 0x9, count: 64).write(to: backup.appendingPathComponent("payload.bin"))

        XCTAssertThrowsError(try service.moveToTrash(item)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed after it was reviewed"))
        }
        XCTAssertTrue(recorder.paths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testBackupFromDifferentRootCannotBeMoved() throws {
        let firstRoot = try temporaryFolder()
        let secondRoot = try temporaryFolder()
        _ = try makeRecognizedBackup(in: firstRoot, name: "device-backup")
        let sourceService = DeviceBackupService(backupRootURL: firstRoot)
        let item = try XCTUnwrap(sourceService.scan().backups.first)
        let recorder = DeviceBackupTrashRecorder()
        let destinationService = DeviceBackupService(backupRootURL: secondRoot) { url in recorder.append(url.path) }

        XCTAssertThrowsError(try destinationService.moveToTrash(item)) { error in
            XCTAssertTrue(error.localizedDescription.contains("standard iPhone or iPad backup folder"))
        }
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testMissingBackupFolderIsReportedWithoutPrompting() throws {
        let root = try temporaryFolder().appendingPathComponent("missing", isDirectory: true)

        let result = DeviceBackupService(backupRootURL: root).scan()

        XCTAssertTrue(result.isAvailable)
        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertTrue(result.message?.contains("No local device-backup folder") == true)
    }

    func testCancelledInventoryPublishesNoPartialCleanupCandidates() throws {
        let root = try temporaryFolder()
        _ = try makeRecognizedBackup(in: root, name: "device-backup")

        let result = DeviceBackupService(backupRootURL: root).scan(isCancelled: { true })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.backups.isEmpty)
        XCTAssertTrue(result.message?.contains("Scan cancelled") == true)
    }

    private func makeRecognizedBackup(in root: URL, name: String) throws -> URL {
        let backup = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("info".utf8).write(to: backup.appendingPathComponent("Info.plist"))
        try Data("manifest".utf8).write(to: backup.appendingPathComponent("Manifest.db"))
        try Data(repeating: 0x4, count: 32).write(to: backup.appendingPathComponent("payload.bin"))
        return backup
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
