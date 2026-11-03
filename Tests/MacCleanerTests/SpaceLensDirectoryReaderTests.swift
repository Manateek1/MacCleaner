import Foundation
import XCTest
@testable import MacCleaner

final class SpaceLensDirectoryReaderTests: XCTestCase {
    func testReadsDirectFilesSortedBySizeThenName() throws {
        let root = try temporaryFolder()
        try Data(repeating: 1, count: 8).write(to: root.appendingPathComponent("zeta.txt"))
        try Data(repeating: 2, count: 12).write(to: root.appendingPathComponent("large.txt"))
        try Data(repeating: 3, count: 8).write(to: root.appendingPathComponent("alpha.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: root.appendingPathComponent("nested/hidden-from-parent.txt"))

        let contents = try SpaceLensDirectoryReader.readFiles(in: root, within: root)

        XCTAssertEqual(contents.files.map(\.name), ["large.txt", "alpha.txt", "zeta.txt"])
        XCTAssertEqual(contents.files.map(\.size), [12, 8, 8])
        XCTAssertEqual(contents.entriesVisited, 4)
        XCTAssertFalse(contents.wasTruncated)
    }

    func testSkipsSymlinksAndProtectedNames() throws {
        let root = try temporaryFolder()
        let external = try temporaryFolder()
        try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("credentials.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: false)
        try Data("secret key".utf8).write(to: root.appendingPathComponent(".ssh/id_ed25519"))
        let externalFile = external.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.txt"), withDestinationURL: externalFile)

        let contents = try SpaceLensDirectoryReader.readFiles(in: root, within: root)

        XCTAssertEqual(contents.files.map(\.name), ["visible.txt"])
        XCTAssertEqual(contents.skippedItems, 3)
    }

    func testRejectsFolderOutsideTheScannedRoot() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()

        XCTAssertThrowsError(try SpaceLensDirectoryReader.readFiles(in: outside, within: root)) { error in
            XCTAssertEqual(error as? SpaceLensDirectoryError, .outsideScannedLocation)
        }
    }

    func testDoesNotFollowSymlinkedFolderComponents() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("private.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder"), withDestinationURL: outside)

        XCTAssertThrowsError(try SpaceLensDirectoryReader.readFiles(
            in: root.appendingPathComponent("linked-folder", isDirectory: true),
            within: root
        )) { error in
            XCTAssertEqual(error as? SpaceLensDirectoryError, .cannotReadFolder)
        }
    }

    func testEntryLimitReturnsClearlyTruncatedPartialList() throws {
        let root = try temporaryFolder()
        for index in 0..<5 {
            try Data("file \(index)".utf8).write(to: root.appendingPathComponent("file-\(index).txt"))
        }

        let contents = try SpaceLensDirectoryReader.readFiles(in: root, within: root, maximumEntries: 2)

        XCTAssertEqual(contents.entriesVisited, 2)
        XCTAssertLessThanOrEqual(contents.files.count, 2)
        XCTAssertTrue(contents.wasTruncated)
    }

    func testZeroEntryLimitReturnsEmptyTruncatedList() throws {
        let root = try temporaryFolder()
        try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))

        let contents = try SpaceLensDirectoryReader.readFiles(in: root, within: root, maximumEntries: 0)

        XCTAssertTrue(contents.files.isEmpty)
        XCTAssertEqual(contents.entriesVisited, 0)
        XCTAssertTrue(contents.wasTruncated)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleaner-SpaceLens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
