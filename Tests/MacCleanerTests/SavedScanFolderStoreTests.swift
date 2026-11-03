import Foundation
import XCTest
@testable import MacCleaner

final class SavedScanFolderStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "MacCleanerSavedFoldersTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testAddSortsAndPersistsBookmarksAndRemoveOnlyRemovesShortcut() throws {
        let first = root.appendingPathComponent("Folder A", isDirectory: true)
        let second = root.appendingPathComponent("Folder B", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let store = makeStore()

        _ = try store.add(second)
        _ = try store.add(first)
        let folders = try store.add(first)

        XCTAssertEqual(folders.map(\.path), [first.path, second.path])
        XCTAssertEqual(try store.resolve(first.path)?.url.standardizedFileURL, first.standardizedFileURL)
        XCTAssertEqual(makeStore().folders, folders)

        let remaining = store.remove(second.path)

        XCTAssertEqual(remaining, [SavedScanFolder(path: first.path)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testRejectsDiskRootAndNonDirectoryLocations() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.add(URL(fileURLWithPath: "/", isDirectory: true))) {
            XCTAssertEqual($0 as? SavedScanFolderError, .diskRoot)
        }
        let file = root.appendingPathComponent("note.txt")
        try Data("still here".utf8).write(to: file)
        XCTAssertThrowsError(try store.add(file)) {
            XCTAssertEqual($0 as? SavedScanFolderError, .notDirectory)
        }
        XCTAssertTrue(store.folders.isEmpty)
    }

    func testStaleOrMovedBookmarkCanBeRefreshedAfterAccessStarts() throws {
        let oldFolder = root.appendingPathComponent("Old Name", isDirectory: true)
        let newFolder = root.appendingPathComponent("New Name", isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let store = makeStore(resolve: { _ in
            SavedScanFolderResolution(url: newFolder, isStale: true)
        })
        _ = try store.add(oldFolder)

        let resolution = try XCTUnwrap(store.resolve(oldFolder.path))

        XCTAssertEqual(resolution.url, newFolder.standardizedFileURL)
        XCTAssertTrue(resolution.isStale)
        XCTAssertEqual(try store.refresh(oldFolder.path, with: newFolder), [SavedScanFolder(path: newFolder.path)])
    }

    private func makeStore(
        resolve: @escaping SavedScanFolderStore.BookmarkResolver = { data in
            guard let path = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "SavedScanFolderStoreTests", code: 1)
            }
            return SavedScanFolderResolution(url: URL(fileURLWithPath: path, isDirectory: true), isStale: false)
        }
    ) -> SavedScanFolderStore {
        SavedScanFolderStore(
            defaults: defaults,
            key: "SavedFolders",
            createBookmark: { Data($0.standardizedFileURL.path.utf8) },
            resolveBookmark: resolve
        )
    }
}
