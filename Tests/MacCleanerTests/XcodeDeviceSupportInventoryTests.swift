import Foundation
import XCTest
@testable import MacCleaner

final class XcodeDeviceSupportInventoryTests: XCTestCase {
    private var temporaryFolders: [URL] = []

    override func tearDownWithError() throws {
        for folder in temporaryFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        temporaryFolders.removeAll()
        try super.tearDownWithError()
    }

    func testListsDeviceSupportFoldersBySizeWithoutChangingFiles() throws {
        let root = try temporaryFolder()
        let newest = root.appendingPathComponent("iPhone 17,1 26.0", isDirectory: true)
        let older = root.appendingPathComponent("iPhone 15,2 18.0", isDirectory: true)
        try FileManager.default.createDirectory(at: newest.appendingPathComponent("Symbols", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let firstPayload = newest.appendingPathComponent("Symbols/device.dylib")
        let secondPayload = older.appendingPathComponent("Symbols.dylib")
        try Data(repeating: 0x31, count: 64).write(to: firstPayload)
        try Data(repeating: 0x32, count: 12).write(to: secondPayload)

        let result = XcodeDeviceSupportInventoryService(rootURL: root).scan()

        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.folders.map(\.name), ["iPhone 17,1 26.0", "iPhone 15,2 18.0"])
        XCTAssertEqual(result.folders.map(\.sizeBytes), [64, 12])
        XCTAssertEqual(result.folders.map(\.fileCount), [1, 1])
        XCTAssertTrue(result.folders.allSatisfy(\.isComplete))
        XCTAssertEqual(try Data(contentsOf: firstPayload), Data(repeating: 0x31, count: 64))
    }

    func testDoesNotCountFilesOutsideDeviceSupportThroughSymbolicLink() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        let support = root.appendingPathComponent("iPhone 17,1", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let externalFile = outside.appendingPathComponent("outside.bin")
        try Data(repeating: 0x41, count: 2048).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("external", isDirectory: true),
            withDestinationURL: outside
        )

        let result = XcodeDeviceSupportInventoryService(rootURL: root).scan()

        let item = try XCTUnwrap(result.folders.first)
        XCTAssertEqual(item.sizeBytes, 0)
        XCTAssertFalse(item.isComplete)
        XCTAssertGreaterThan(item.skippedEntries, 0)
    }

    func testSkipsSymbolicLinkAtDeviceSupportRoot() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        _ = try makeSupportFolder(in: outside, name: "External device")
        let linkedSupport = root.appendingPathComponent("iPhone 17,1", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedSupport, withDestinationURL: outside)

        let result = XcodeDeviceSupportInventoryService(rootURL: root).scan()

        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertEqual(result.skippedLocations, 1)
    }

    func testSafetyLimitMarksSupportFolderIncomplete() throws {
        let root = try temporaryFolder()
        let support = root.appendingPathComponent("iPhone 17,1", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: support.appendingPathComponent("one.bin"))
        try Data("two".utf8).write(to: support.appendingPathComponent("two.bin"))

        let result = XcodeDeviceSupportInventoryService(rootURL: root, maximumEntries: 2).scan()

        XCTAssertTrue(result.wasLimited)
        XCTAssertFalse(try XCTUnwrap(result.folders.first).isComplete)
    }

    func testCancellationDoesNotClaimCompleteInventory() throws {
        let root = try temporaryFolder()
        _ = try makeSupportFolder(in: root, name: "iPhone 17,1")

        let result = XcodeDeviceSupportInventoryService(rootURL: root).scan(isCancelled: { true })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.folders.isEmpty)
    }

    func testMissingDeviceSupportFolderIsReportedWithoutPrompting() throws {
        let home = try temporaryFolder()

        let result = XcodeDeviceSupportInventoryService(homeURL: home).scan()

        XCTAssertTrue(result.isAvailable)
        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertTrue(result.message?.contains("No local Xcode Device Support") == true)
    }

    func testSymbolicLinkDeviceSupportRootIsNotOpened() throws {
        let root = try temporaryFolder()
        let actual = try temporaryFolder()
        _ = try makeSupportFolder(in: actual, name: "iPhone 17,1")
        let link = root.appendingPathComponent("DeviceSupport", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)

        let result = XcodeDeviceSupportInventoryService(rootURL: link).scan()

        XCTAssertFalse(result.isAvailable)
        XCTAssertTrue(result.folders.isEmpty)
        XCTAssertTrue(result.message?.contains("symbolic link") == true)
    }

    @discardableResult
    private func makeSupportFolder(in root: URL, name: String) throws -> URL {
        let support = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("device support".utf8).write(to: support.appendingPathComponent("symbols.bin"))
        return support
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryFolders.append(url)
        return url
    }
}
