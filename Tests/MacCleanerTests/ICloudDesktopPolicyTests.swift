import Foundation
import Darwin
import XCTest
@testable import MacCleaner

final class ICloudDesktopPolicyTests: XCTestCase {
    func testLocalAvailabilityAllowsOnlyAlreadyPresentCloudItems() {
        XCTAssertTrue(ICloudDesktopPolicy.isLocallyAvailable(
            isUbiquitous: false,
            downloadStatus: nil,
            isDownloading: nil
        ))
        XCTAssertTrue(ICloudDesktopPolicy.isLocallyAvailable(
            isUbiquitous: true,
            downloadStatus: .current,
            isDownloading: false
        ))
        XCTAssertTrue(ICloudDesktopPolicy.isLocallyAvailable(
            isUbiquitous: true,
            downloadStatus: .downloaded,
            isDownloading: false
        ))
        XCTAssertFalse(ICloudDesktopPolicy.isLocallyAvailable(
            isUbiquitous: true,
            downloadStatus: .notDownloaded,
            isDownloading: false
        ))
        XCTAssertFalse(ICloudDesktopPolicy.isLocallyAvailable(
            isUbiquitous: true,
            downloadStatus: .current,
            isDownloading: true
        ))
        XCTAssertFalse(ICloudDesktopPolicy.isLocallyAvailable(
            isUbiquitous: true,
            downloadStatus: nil,
            isDownloading: false
        ))
        XCTAssertFalse(ICloudDesktopPolicy.isLocallyAvailable(
            isUbiquitous: nil,
            downloadStatus: .current,
            isDownloading: false
        ))
    }

    func testPreviewRequiresACurrentLocalCopyForICloudItems() {
        XCTAssertTrue(ICloudDesktopPolicy.isCurrentLocalCopy(
            isUbiquitous: false,
            downloadStatus: nil,
            isDownloading: nil
        ))
        XCTAssertTrue(ICloudDesktopPolicy.isCurrentLocalCopy(
            isUbiquitous: true,
            downloadStatus: .current,
            isDownloading: false
        ))
        XCTAssertFalse(ICloudDesktopPolicy.isCurrentLocalCopy(
            isUbiquitous: true,
            downloadStatus: .downloaded,
            isDownloading: false
        ))
        XCTAssertFalse(ICloudDesktopPolicy.isCurrentLocalCopy(
            isUbiquitous: true,
            downloadStatus: .current,
            isDownloading: true
        ))
        XCTAssertFalse(ICloudDesktopPolicy.isCurrentLocalCopy(
            isUbiquitous: nil,
            downloadStatus: .current,
            isDownloading: false
        ))
    }

    func testDesktopContainmentDoesNotMatchSiblingPaths() {
        let desktop = URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true)

        XCTAssertTrue(ICloudDesktopPolicy.contains(
            URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true),
            inside: desktop
        ))
        XCTAssertTrue(ICloudDesktopPolicy.contains(
            URL(fileURLWithPath: "/Users/example/Desktop/Folder/photo.jpg"),
            inside: desktop
        ))
        XCTAssertFalse(ICloudDesktopPolicy.contains(
            URL(fileURLWithPath: "/Users/example/Desktop Archive/photo.jpg"),
            inside: desktop
        ))
        XCTAssertFalse(ICloudDesktopPolicy.contains(
            URL(fileURLWithPath: "/Users/example/Documents/report.pdf"),
            inside: desktop
        ))
    }

    func testOrdinaryDesktopIsNotTreatedAsICloudDesktop() throws {
        let accountHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleaner-iCloudPolicy-\(UUID().uuidString)", isDirectory: true)
        let desktop = accountHome.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: accountHome) }

        XCTAssertNil(ICloudDesktopPolicy.iCloudDesktopRoot(accountHome: accountHome))
    }

    func testCloudManagedItemsCannotBeMovedToTrash() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleaner-iCloudTrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("local-cloud-copy.bin")
        try Data("keep this file".utf8).write(to: file)

        var info = stat()
        XCTAssertEqual(file.path.withCString { lstat($0, &info) }, 0)
        let item = ScanItem(
            path: file.path,
            identity: FileIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                size: Int64(info.st_size),
                modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
                linkCount: UInt32(info.st_nlink)
            ),
            lastAccessedAt: nil,
            isCloudManaged: true,
            categories: [.largeFile],
            reasons: [],
            safetyNote: "Review only",
            confidence: 0.25,
            duplicateGroupID: nil,
            duplicateGroupCount: 0,
            suggestedKeepPath: nil,
            cacheReviewDetails: nil
        )

        let result = TrashService().moveToTrash([item], allCandidates: [item], inside: folder)

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.localizedCaseInsensitiveContains("view-only"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCloudManagedFilesDoNotCountAsSpaceAvailableForReview() {
        let localItem = scanItem(path: "/Users/example/Downloads/local.bin", size: 100, isCloudManaged: false)
        let cloudItem = scanItem(path: "/Users/example/Desktop/cloud.bin", size: 500, isCloudManaged: true)
        let result = ScanResult(
            kind: .smart,
            rootPath: "/",
            filesVisited: 2,
            entriesVisited: 2,
            entryLimit: 100,
            bytesVisited: 600,
            skippedItems: 0,
            skippedLocations: [],
            cloudFilesNotLocallyAvailable: 4,
            cloudFilesLocallyAvailable: 1,
            cloudDesktopAccessUnavailable: true,
            excludedLocations: [],
            items: [localItem, cloudItem],
            finishedAt: .now,
            wasTruncated: false,
            space: nil,
            duplicateKeepPreference: .oldest
        )

        XCTAssertEqual(result.potentialBytesToReview, 100)
        XCTAssertEqual(result.removingItems(at: []).cloudFilesNotLocallyAvailable, 4)
        XCTAssertEqual(result.removingItems(at: []).cloudFilesLocallyAvailable, 1)
        XCTAssertEqual(result.removingItems(at: []).cloudDesktopAccessUnavailable, true)
    }

    func testDesktopBookmarkIsSavedAndResolvedWithoutPromptingAgain() throws {
        let suiteName = "MacCleaner-ICloudDesktopBookmark-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bookmarkStore = ICloudDesktopBookmarkStore(
            defaults: defaults,
            createBookmark: { Data($0.path.utf8) },
            resolveBookmark: { data in
                ICloudDesktopBookmarkResolution(
                    url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true),
                    isStale: false
                )
            }
        )
        let desktop = URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true)

        XCTAssertFalse(bookmarkStore.hasBookmark)
        XCTAssertFalse(bookmarkStore.hasAskedForAccess)

        bookmarkStore.markAccessRequested()
        try bookmarkStore.save(desktop)

        XCTAssertTrue(bookmarkStore.hasAskedForAccess)
        XCTAssertTrue(bookmarkStore.hasBookmark)
        XCTAssertEqual(try bookmarkStore.resolve()?.path, desktop.path)
    }

    func testForgettingDesktopAccessAllowsTheOneTimeRequestAgain() throws {
        let suiteName = "MacCleaner-ICloudDesktopForget-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bookmarkStore = ICloudDesktopBookmarkStore(
            defaults: defaults,
            createBookmark: { Data($0.path.utf8) },
            resolveBookmark: { data in
                ICloudDesktopBookmarkResolution(
                    url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true),
                    isStale: false
                )
            }
        )
        bookmarkStore.markAccessRequested()
        try bookmarkStore.save(URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true))

        bookmarkStore.remove()

        XCTAssertFalse(bookmarkStore.hasAskedForAccess)
        XCTAssertFalse(bookmarkStore.hasBookmark)
        XCTAssertNil(try bookmarkStore.resolve())
    }

    func testStaleDesktopBookmarkIsRefreshedAfterResolution() throws {
        let suiteName = "MacCleaner-ICloudDesktopStale-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var createdPaths: [String] = []

        let bookmarkStore = ICloudDesktopBookmarkStore(
            defaults: defaults,
            createBookmark: { url in
                createdPaths.append(url.path)
                return Data(url.path.utf8)
            },
            resolveBookmark: { data in
                ICloudDesktopBookmarkResolution(
                    url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true),
                    isStale: true
                )
            }
        )
        let desktop = URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true)
        try bookmarkStore.save(desktop)

        XCTAssertEqual(try bookmarkStore.resolve()?.path, desktop.path)
        XCTAssertEqual(createdPaths, [desktop.path, desktop.path])
    }

    private func scanItem(path: String, size: Int64, isCloudManaged: Bool) -> ScanItem {
        ScanItem(
            path: path,
            identity: FileIdentity(device: 1, inode: 1, size: size, modifiedAt: 1_700_000_000, linkCount: 1),
            lastAccessedAt: nil,
            isCloudManaged: isCloudManaged,
            categories: [.largeFile],
            reasons: [],
            safetyNote: "Review only",
            confidence: 0.25,
            duplicateGroupID: nil,
            duplicateGroupCount: 0,
            suggestedKeepPath: nil,
            cacheReviewDetails: nil
        )
    }
}
