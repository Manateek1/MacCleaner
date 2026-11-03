import Foundation
import XCTest
@testable import MacCleaner

final class XcodeDeviceSupportRemovalServiceTests: XCTestCase {
    private var temporaryFolders: [URL] = []

    override func tearDownWithError() throws {
        for folder in temporaryFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        temporaryFolders.removeAll()
        try super.tearDownWithError()
    }

    func testMovesOnlyReviewedCompleteFolderToTrashAfterWholeTreeRecheck() throws {
        let home = try temporaryFolder()
        let support = try makeSupportFolder(in: standardDeviceSupportRoot(in: home), name: "iPhone 17,1 26.0")
        let trash = home.appendingPathComponent("Test Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let scan = XcodeDeviceSupportInventoryService(homeURL: home).scan()
        let folder = try XCTUnwrap(scan.folders.first)
        XCTAssertTrue(folder.canMoveToTrash)

        let service = XcodeDeviceSupportRemovalService(homeURL: home, isXcodeRunning: { false }) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let result = service.moveToTrash([folder, folder])

        XCTAssertEqual(result.movedPaths, [folder.path])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.bytesMoved, folder.sizeBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent(support.lastPathComponent).path))
    }

    func testLeavesFolderInPlaceWhenContentsChangeAfterScan() throws {
        let home = try temporaryFolder()
        let support = try makeSupportFolder(in: standardDeviceSupportRoot(in: home), name: "iPhone 17,1 26.0")
        let payload = support.appendingPathComponent("Symbols/symbols.bin")
        let folder = try XCTUnwrap(XcodeDeviceSupportInventoryService(homeURL: home).scan().folders.first)
        try Data(repeating: 0x77, count: 256).write(to: payload)
        let service = XcodeDeviceSupportRemovalService(homeURL: home, isXcodeRunning: { false }) { url in
            try FileManager.default.removeItem(at: url)
        }

        let result = service.moveToTrash([folder])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testLeavesFolderInPlaceIfXcodeIsRunningWhenTrashActionStarts() throws {
        let home = try temporaryFolder()
        let support = try makeSupportFolder(in: standardDeviceSupportRoot(in: home), name: "iPhone 17,1 26.0")
        let folder = try XCTUnwrap(XcodeDeviceSupportInventoryService(homeURL: home).scan().folders.first)
        let service = XcodeDeviceSupportRemovalService(homeURL: home, isXcodeRunning: { true }) { url in
            try FileManager.default.removeItem(at: url)
        }

        let result = service.moveToTrash([folder])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.contains("Quit Xcode"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
    }

    func testHardLinkedSupportFilesAreViewOnly() throws {
        let home = try temporaryFolder()
        let root = try standardDeviceSupportRoot(in: home)
        let support = try makeSupportFolder(in: root, name: "iPhone 17,1 26.0")
        let payload = support.appendingPathComponent("Symbols/symbols.bin")
        let sharedCopy = home.appendingPathComponent("shared-symbols.bin")
        try FileManager.default.linkItem(at: payload, to: sharedCopy)
        let folder = try XCTUnwrap(XcodeDeviceSupportInventoryService(homeURL: home).scan().folders.first)

        XCTAssertTrue(folder.isComplete)
        XCTAssertFalse(folder.canMoveToTrash)
        let service = XcodeDeviceSupportRemovalService(homeURL: home, isXcodeRunning: { false }) { url in
            try FileManager.default.removeItem(at: url)
        }
        let result = service.moveToTrash([folder])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedCopy.path))
    }

    func testLeavesFolderInPlaceWhenSymlinkAppearsAfterScan() throws {
        let home = try temporaryFolder()
        let root = try standardDeviceSupportRoot(in: home)
        let support = try makeSupportFolder(in: root, name: "iPhone 17,1 26.0")
        let outside = try temporaryFolder()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("private.bin"))
        let folder = try XCTUnwrap(XcodeDeviceSupportInventoryService(homeURL: home).scan().folders.first)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("external", isDirectory: true),
            withDestinationURL: outside
        )
        let service = XcodeDeviceSupportRemovalService(homeURL: home, isXcodeRunning: { false }) { url in
            try FileManager.default.removeItem(at: url)
        }

        let result = service.moveToTrash([folder])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("private.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
    }

    func testViewOnlyFolderCannotBeMovedEvenWithInjectedTrashOperation() throws {
        let home = try temporaryFolder()
        let support = try makeSupportFolder(in: standardDeviceSupportRoot(in: home), name: "iPhone 17,1 26.0")
        let folder = try XCTUnwrap(
            XcodeDeviceSupportInventoryService(homeURL: home, maximumEntries: 1).scan().folders.first
        )
        XCTAssertFalse(folder.canMoveToTrash)
        let service = XcodeDeviceSupportRemovalService(homeURL: home, isXcodeRunning: { false }) { url in
            try FileManager.default.removeItem(at: url)
        }

        let result = service.moveToTrash([folder])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
    }

    func testFolderOutsideStandardDeviceSupportLocationCannotBeMoved() throws {
        let home = try temporaryFolder()
        let customRoot = home.appendingPathComponent("custom-device-data", isDirectory: true)
        let support = try makeSupportFolder(in: customRoot, name: "iPhone 17,1 26.0")
        let folder = try XCTUnwrap(XcodeDeviceSupportInventoryService(rootURL: customRoot).scan().folders.first)
        XCTAssertTrue(folder.canMoveToTrash)
        let service = XcodeDeviceSupportRemovalService(homeURL: home, isXcodeRunning: { false }) { url in
            try FileManager.default.removeItem(at: url)
        }

        let result = service.moveToTrash([folder])

        XCTAssertTrue(result.movedPaths.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
    }

    private func makeSupportFolder(in root: URL, name: String) throws -> URL {
        let support = root.appendingPathComponent(name, isDirectory: true)
        let symbols = support.appendingPathComponent("Symbols", isDirectory: true)
        try FileManager.default.createDirectory(at: symbols, withIntermediateDirectories: true)
        try Data("device support".utf8).write(to: symbols.appendingPathComponent("symbols.bin"))
        return support
    }

    private func standardDeviceSupportRoot(in home: URL) throws -> URL {
        let root = home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryFolders.append(url)
        return url
    }
}
