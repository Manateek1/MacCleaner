import Foundation
import XCTest
@testable import MacCleaner

final class FullDiskAccessProbeTests: XCTestCase {
    func testRequiresAccessToExistingDocumentsAndDownloadsFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        XCTAssertTrue(FullDiskAccessProbe.hasAccess(homeDirectory: home, openDirectory: { path in
            path == documents.path || path == downloads.path
        }))
        XCTAssertFalse(FullDiskAccessProbe.hasAccess(homeDirectory: home, openDirectory: { path in
            path == documents.path
        }))
    }

    func testAllowsHomesWithoutAStandardFolderThatDoesNotExist() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents", isDirectory: true), withIntermediateDirectories: true)

        XCTAssertTrue(FullDiskAccessProbe.hasAccess(homeDirectory: home, openDirectory: { _ in true }))
    }
}
