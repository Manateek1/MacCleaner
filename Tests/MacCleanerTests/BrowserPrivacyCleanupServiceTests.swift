import Foundation
import XCTest
@testable import MacCleaner

final class BrowserPrivacyCleanupServiceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerBrowserPrivacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    func testFindsOnlySupportedBrowserCacheFoldersAndLeavesProfileDataAlone() throws {
        let safari = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        let firefox = home.appendingPathComponent("Library/Caches/Firefox/Profiles/abc.default-release/cache2", isDirectory: true)
        let chromeWebCache = home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache", isDirectory: true)
        let chromeCodeCache = home.appendingPathComponent("Library/Caches/Google/Chrome/Profile 1/Code Cache", isDirectory: true)
        let chromeStorage = home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Storage/ext", isDirectory: true)
        let profileData = home.appendingPathComponent("Library/Application Support/Firefox/Profiles/abc.default-release", isDirectory: true)
        let chromeProfileData = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        try makeFile(at: safari.appendingPathComponent("resource.cache"), contents: "safari cache")
        try makeFile(at: firefox.appendingPathComponent("entry.cache"), contents: "firefox cache")
        try makeFile(at: chromeWebCache.appendingPathComponent("Cache_Data/entry.cache"), contents: "chrome web cache")
        try makeFile(at: chromeCodeCache.appendingPathComponent("js/entry.cache"), contents: "chrome code cache")
        try makeFile(at: chromeStorage.appendingPathComponent("extension.db"), contents: "extension storage")
        try makeFile(at: profileData.appendingPathComponent("places.sqlite"), contents: "history and bookmarks")
        try makeFile(at: profileData.appendingPathComponent("cookies.sqlite"), contents: "site sign-ins")
        try makeFile(at: profileData.appendingPathComponent("logins.json"), contents: "saved passwords")
        try makeFile(at: chromeProfileData.appendingPathComponent("History"), contents: "browsing history")
        try makeFile(at: chromeProfileData.appendingPathComponent("Cookies"), contents: "site sign-ins")
        try makeFile(at: chromeProfileData.appendingPathComponent("Login Data"), contents: "saved passwords")

        let inventory = BrowserPrivacyCleanupService(homeURL: home).scan()

        let actualPaths = Set(inventory.candidates.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        let expectedPaths = Set([safari, firefox, chromeWebCache, chromeCodeCache].map { $0.resolvingSymlinksInPath().path })
        XCTAssertEqual(actualPaths, expectedPaths)
        XCTAssertTrue(inventory.candidates.allSatisfy(\.canMoveToTrash))
        XCTAssertFalse(inventory.candidates.contains { candidate in
            ["places.sqlite", "cookies.sqlite", "logins.json", "key4.db"].contains(candidate.name)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: chromeStorage.appendingPathComponent("extension.db").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chromeProfileData.appendingPathComponent("History").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chromeProfileData.appendingPathComponent("Cookies").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chromeProfileData.appendingPathComponent("Login Data").path))
    }

    func testRunningChromeCacheCannotBeSelectedForCleanup() throws {
        let chromeCache = home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache", isDirectory: true)
        try makeFile(at: chromeCache.appendingPathComponent("Cache_Data/entry.cache"), contents: "cache")

        let inventory = BrowserPrivacyCleanupService(homeURL: home).scan(
            runningBundleIdentifiers: [LocalBrowser.chrome.bundleIdentifier]
        )

        let candidate = try XCTUnwrap(inventory.candidates.first)
        XCTAssertEqual(candidate.browser, .chrome)
        XCTAssertFalse(candidate.canMoveToTrash)
        XCTAssertTrue(candidate.statusMessage?.contains("Quit Chrome") == true)
    }

    func testChromeThatStartsAfterReviewCannotHaveItsCacheMoved() throws {
        let chromeCache = home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache", isDirectory: true)
        try makeFile(at: chromeCache.appendingPathComponent("Cache_Data/entry.cache"), contents: "cache")
        let capture = TrashCapture()
        let service = BrowserPrivacyCleanupService(homeURL: home, trashOperation: { capture.append($0) })
        let candidate = try XCTUnwrap(service.scan().candidates.first { $0.browser == .chrome })
        XCTAssertTrue(candidate.canMoveToTrash)

        XCTAssertThrowsError(try service.moveToTrash(
            candidate,
            runningBundleIdentifiers: [LocalBrowser.chrome.bundleIdentifier]
        )) { error in
            XCTAssertEqual(error as? BrowserPrivacyCleanupError, .browserRunning)
        }
        XCTAssertTrue(capture.paths.isEmpty)
    }

    func testChromeCleanupMovesOnlyReviewedCacheAndLeavesHistoryAndCookies() throws {
        let chromeCache = home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache", isDirectory: true)
        let profileData = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        try makeFile(at: chromeCache.appendingPathComponent("Cache_Data/entry.cache"), contents: "temporary")
        try makeFile(at: profileData.appendingPathComponent("History"), contents: "browsing history")
        try makeFile(at: profileData.appendingPathComponent("Cookies"), contents: "site sign-ins")
        try makeFile(at: profileData.appendingPathComponent("Login Data"), contents: "saved passwords")
        let capture = TrashCapture()
        let service = BrowserPrivacyCleanupService(homeURL: home, trashOperation: { capture.append($0) })
        let candidate = try XCTUnwrap(service.scan().candidates.first { $0.browser == .chrome })

        _ = try service.moveToTrash(candidate, runningBundleIdentifiers: [])

        XCTAssertEqual(capture.paths, [chromeCache])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileData.appendingPathComponent("History").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileData.appendingPathComponent("Cookies").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileData.appendingPathComponent("Login Data").path))
    }

    func testRunningBrowserCacheCannotBeSelectedForCleanup() throws {
        let safari = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        try makeFile(at: safari.appendingPathComponent("resource.cache"), contents: "cache")

        let inventory = BrowserPrivacyCleanupService(homeURL: home).scan(
            runningBundleIdentifiers: [LocalBrowser.safari.bundleIdentifier]
        )

        let candidate = try XCTUnwrap(inventory.candidates.first)
        XCTAssertEqual(candidate.browser, .safari)
        XCTAssertFalse(candidate.canMoveToTrash)
        XCTAssertTrue(candidate.statusMessage?.contains("Quit Safari") == true)
    }

    func testSymlinkedCacheIsSkippedWithoutFollowingItsTarget() throws {
        let outside = home.appendingPathComponent("Outside", isDirectory: true)
        let symlink = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        try makeFile(at: outside.appendingPathComponent("private.txt"), contents: "not browser cache")
        try FileManager.default.createDirectory(
            at: symlink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let inventory = BrowserPrivacyCleanupService(homeURL: home).scan()

        XCTAssertTrue(inventory.candidates.isEmpty)
        XCTAssertGreaterThan(inventory.skippedLocations, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("private.txt").path))
    }

    func testIncompleteCacheRemainsUnavailableForTrash() throws {
        let safari = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        try makeFile(at: safari.appendingPathComponent("resource.cache"), contents: "cache")
        let service = BrowserPrivacyCleanupService(homeURL: home, maximumEntriesPerCache: 1)

        let candidate = try XCTUnwrap(service.scan().candidates.first)

        XCTAssertFalse(candidate.canMoveToTrash)
        XCTAssertThrowsError(try service.moveToTrash(candidate, runningBundleIdentifiers: [])) { error in
            XCTAssertEqual(error as? BrowserPrivacyCleanupError, .incomplete)
        }
    }

    func testChangedCacheIsNotMovedAfterReview() throws {
        let safari = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        try makeFile(at: safari.appendingPathComponent("resource.cache"), contents: "before")
        let service = BrowserPrivacyCleanupService(homeURL: home)
        let candidate = try XCTUnwrap(service.scan().candidates.first)
        try makeFile(at: safari.appendingPathComponent("new.cache"), contents: "after review")

        XCTAssertThrowsError(try service.moveToTrash(candidate, runningBundleIdentifiers: [])) { error in
            XCTAssertEqual(error as? BrowserPrivacyCleanupError, .changedSinceReview)
        }
    }

    func testFirefoxProfileCacheCanBeMovedWithoutTouchingProfileData() throws {
        let cache = home.appendingPathComponent(
            "Library/Caches/Firefox/Profiles/abc.default-release/cache2",
            isDirectory: true
        )
        let profile = home.appendingPathComponent(
            "Library/Application Support/Firefox/Profiles/abc.default-release",
            isDirectory: true
        )
        try makeFile(at: cache.appendingPathComponent("entry.cache"), contents: "temporary")
        try makeFile(at: profile.appendingPathComponent("places.sqlite"), contents: "bookmarks and history")
        try makeFile(at: profile.appendingPathComponent("cookies.sqlite"), contents: "site sign-ins")
        let capture = TrashCapture()
        let service = BrowserPrivacyCleanupService(homeURL: home, trashOperation: { capture.append($0) })
        let candidate = try XCTUnwrap(service.scan().candidates.first { $0.browser == .firefox })

        _ = try service.moveToTrash(candidate, runningBundleIdentifiers: [])

        XCTAssertEqual(capture.paths.count, 1)
        XCTAssertEqual(capture.paths[0].lastPathComponent, "cache2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.appendingPathComponent("places.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.appendingPathComponent("cookies.sqlite").path))
    }

    func testConfirmedCacheMoveTargetsOnlyTheReviewedFolder() throws {
        let safari = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        try makeFile(at: safari.appendingPathComponent("resource.cache"), contents: "cache")
        let capture = TrashCapture()
        let service = BrowserPrivacyCleanupService(homeURL: home, trashOperation: { capture.append($0) })
        let candidate = try XCTUnwrap(service.scan().candidates.first)

        let moved = try service.moveToTrash(candidate, runningBundleIdentifiers: [])

        XCTAssertEqual(moved.path, safari.path)
        XCTAssertEqual(capture.paths, [safari])
        XCTAssertEqual(moved.sizeBytes, Int64("cache".utf8.count))
    }

    func testCancellationDiscardsPartialCleanupCandidates() throws {
        let safari = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        try makeFile(at: safari.appendingPathComponent("resource.cache"), contents: "cache")

        let inventory = BrowserPrivacyCleanupService(homeURL: home).scan(isCancelled: { true })

        XCTAssertTrue(inventory.wasCancelled)
        XCTAssertTrue(inventory.candidates.isEmpty)
    }

    private func makeFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}

private final class TrashCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var movedPaths: [URL] = []

    var paths: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return movedPaths
    }

    func append(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        movedPaths.append(url)
    }
}
