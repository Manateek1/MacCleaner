import XCTest
@testable import MacCleaner

final class FindingFileTypeTests: XCTestCase {
    func testFileTypeKeyIgnoresExtensionCaseAndLabelsMissingExtension() {
        let uppercase = item(path: "/scan/Report.PDF", inode: 1)
        let lowercase = item(path: "/scan/notes.pdf", inode: 2)
        let extensionless = item(path: "/scan/README", inode: 3)

        XCTAssertEqual(uppercase.fileTypeKey, lowercase.fileTypeKey)
        XCTAssertEqual(uppercase.fileTypeTitle, "PDF files")
        XCTAssertEqual(extensionless.fileTypeKey, "")
        XCTAssertEqual(extensionless.fileTypeTitle, "Files without an extension")
    }

    func testFindingLocationUsesFolderBoundariesAndGroupsOtherLocations() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(
            FindingLocation.classify("/Users/example/Desktop/Trip/photo.jpg", homeDirectory: home),
            .desktop
        )
        XCTAssertEqual(
            FindingLocation.classify("/Users/example/Documents/Work/notes.pdf", homeDirectory: home),
            .documents
        )
        XCTAssertEqual(
            FindingLocation.classify("/Users/example/Downloads/archive.zip", homeDirectory: home),
            .downloads
        )
        XCTAssertEqual(
            FindingLocation.classify("/Users/example/Pictures/Family/photo.jpg", homeDirectory: home),
            .pictures
        )
        XCTAssertEqual(
            FindingLocation.classify("/Users/example/Downloads-old/archive.zip", homeDirectory: home),
            .other
        )
        XCTAssertEqual(
            FindingLocation.classify("/Volumes/Backup/Installer.dmg", homeDirectory: home),
            .other
        )
        XCTAssertFalse(FindingLocation.desktop.contains("/Users/example/Documents/file.txt", homeDirectory: home))
        XCTAssertTrue(FindingLocation.other.contains("/Users/example/Movies/video.mov", homeDirectory: home))
    }

    private func item(path: String, inode: UInt64) -> ScanItem {
        ScanItem(
            path: path,
            identity: FileIdentity(device: 1, inode: inode, size: 1, modifiedAt: 1_700_000_000, linkCount: 1),
            lastAccessedAt: nil,
            isCloudManaged: nil,
            categories: [.largeFile],
            reasons: [],
            safetyNote: "Review the file",
            confidence: 1,
            duplicateGroupID: nil,
            duplicateGroupCount: 0,
            suggestedKeepPath: nil,
            cacheReviewDetails: nil
        )
    }
}
