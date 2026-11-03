import Darwin
import Dispatch
import Foundation
import XCTest
@testable import MacCleaner

private final class ScanProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ScanProgress] = []

    func append(_ progress: ScanProgress) {
        lock.lock()
        stored.append(progress)
        lock.unlock()
    }

    var values: [ScanProgress] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class QoSClassObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: qos_class_t?

    func captureCurrentThread() {
        var qosClass = QOS_CLASS_UNSPECIFIED
        var relativePriority: Int32 = 0
        guard pthread_get_qos_class_np(pthread_self(), &qosClass, &relativePriority) == 0 else { return }
        lock.lock()
        stored = qosClass
        lock.unlock()
    }

    var value: qos_class_t? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class FileScannerTests: XCTestCase {
    func testDirectoryOpenerPreservesCallingQualityOfService() {
        var expectedQoS = QOS_CLASS_UNSPECIFIED
        var relativePriority: Int32 = 0
        XCTAssertEqual(pthread_get_qos_class_np(pthread_self(), &expectedQoS, &relativePriority), 0)

        let observedQoS = QoSClassObservation()
        let opener = TimedDirectoryOpener { _ in
            observedQoS.captureCurrentThread()
            errno = EACCES
            return -1
        }

        guard case .failed(let errorCode) = opener.open("quality-of-service", timeout: 1) else {
            return XCTFail("The test opener should report its intentional open failure")
        }
        XCTAssertEqual(observedQoS.value, expectedQoS)
        XCTAssertEqual(errorCode, EACCES)
    }

    func testDirectoryOpenerTimesOutWithoutGrowingBlockedWorkerPool() {
        let lateOpenFinished = DispatchSemaphore(value: 0)
        let opener = TimedDirectoryOpener(maxConcurrentOpens: 1) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            lateOpenFinished.signal()
            return -1
        }

        guard case .timedOut = opener.open("slow-folder", timeout: 0.001) else {
            return XCTFail("A slow directory open should time out")
        }
        guard case .busy = opener.open("another-folder", timeout: 0.001) else {
            return XCTFail("A timed out open should keep its worker slot until it returns")
        }
        XCTAssertEqual(lateOpenFinished.wait(timeout: .now() + 1), .success)
    }

    func testSlowICloudDirectoryDoesNotConsumeLocalDirectoryOpenCapacity() {
        let releaseCloudOpen = DispatchSemaphore(value: 0)
        let openers = ScanDirectoryOpeners(
            local: TimedDirectoryOpener(maxConcurrentOpens: 1) { _ in -1 },
            iCloudDesktop: TimedDirectoryOpener(maxConcurrentOpens: 1) { _ in
                releaseCloudOpen.wait()
                return -1
            }
        )
        defer { releaseCloudOpen.signal() }

        guard case .timedOut = openers.open("cloud-folder", scope: .iCloudDesktop, timeout: 0.001) else {
            return XCTFail("A stalled iCloud folder should time out in its isolated opener.")
        }
        guard case .failed(_) = openers.open("local-folder", scope: .local, timeout: 1) else {
            return XCTFail("A stalled iCloud folder must not consume local-folder open capacity.")
        }
    }

    func testRepositoryCreatedAfterScanPreventsCleanup() async throws {
        let folder = try temporaryFolder()
        let nested = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: nested.appendingPathComponent("sample.dat"))
        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1000)
        let item = try XCTUnwrap(result.items.first)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent(".git"), withIntermediateDirectories: false)
        guard case .protected = SafeFilePolicy.assess(item, inside: folder) else { return XCTFail("New repository must be protected") }
    }
    func testFindsByteExactDuplicatesAndKeepsOneSuggestedCopy() async throws {
        let folder = try temporaryFolder()
        try Data("same bytes".utf8).write(to: folder.appendingPathComponent("first.txt"))
        try Data("same bytes".utf8).write(to: folder.appendingPathComponent("second.txt"))
        try Data("same bYtes".utf8).write(to: folder.appendingPathComponent("third.txt"))

        let result = try await scan(folder, kind: .duplicates)

        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.categories.contains(.exactDuplicate) })
        XCTAssertTrue(result.items.allSatisfy { $0.duplicateGroupCount == 2 })
        XCTAssertEqual(Set(result.items.compactMap(\.suggestedKeepPath)).count, 1)
    }

    func testFindsLargeByteExactDuplicatesAcrossMultipleHashChunks() async throws {
        let folder = try temporaryFolder()
        let payload = Data(repeating: 0xA5, count: 1_500_000)
        try payload.write(to: folder.appendingPathComponent("first.bin"))
        try payload.write(to: folder.appendingPathComponent("second.bin"))

        let result = try await scan(folder, kind: .duplicates)

        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { $0.categories.contains(.exactDuplicate) })
        XCTAssertTrue(result.items.allSatisfy { $0.duplicateGroupCount == 2 })
    }

    func testDuplicateKeepPreferenceChoosesOldestOrNewestAndSurvivesCleanupRescan() async throws {
        let folder = try temporaryFolder()
        let files = ["old.txt", "middle.txt", "new.txt"].map { folder.appendingPathComponent($0) }
        for file in files { try Data("same bytes".utf8).write(to: file) }
        for (index, file) in files.enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 86_400))],
                ofItemAtPath: file.path
            )
        }

        let oldest = try await scan(folder, kind: .duplicates, keepPreference: .oldest)
        let newest = try await scan(folder, kind: .duplicates, keepPreference: .newest)

        XCTAssertEqual(Set(oldest.items.compactMap(\.suggestedKeepPath)), Set([files[0].path]))
        XCTAssertEqual(Set(newest.items.compactMap(\.suggestedKeepPath)), Set([files[2].path]))
        XCTAssertEqual(newest.duplicateKeepPreference, .newest)
        let rescanned = newest.removingItems(at: [files[0].path])
        XCTAssertEqual(Set(rescanned.items.compactMap(\.suggestedKeepPath)), Set([files[2].path]))
        XCTAssertEqual(rescanned.duplicateKeepPreference, .newest)
    }

    func testLargeAndOldFilesUseConfiguredThresholds() async throws {
        let folder = try temporaryFolder()
        let large = folder.appendingPathComponent("large.dat")
        try Data(repeating: 0x41, count: 4096).write(to: large)
        let oldDate = Date(timeIntervalSinceNow: -400 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: large.path)

        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1000, ageDays: 365)

        XCTAssertEqual(result.items.count, 1)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(item.categories.contains(.largeFile))
        XCTAssertTrue(item.categories.contains(.oldFile))
    }

    func testScannerRecordsLastAccessDateSeparatelyForSorting() async throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("old-file.dat")
        try Data(repeating: 1, count: 4096).write(to: file)
        let modifiedAt = Date(timeIntervalSinceNow: -60 * 24 * 60 * 60)
        let accessedAt = Date(timeIntervalSinceNow: -20 * 24 * 60 * 60)
        let times = [
            timeval(tv_sec: time_t(accessedAt.timeIntervalSince1970), tv_usec: 0),
            timeval(tv_sec: time_t(modifiedAt.timeIntervalSince1970), tv_usec: 0)
        ]
        let timestampResult = file.path.withCString { path in
            times.withUnsafeBufferPointer { buffer in
                utimes(path, buffer.baseAddress!)
            }
        }
        XCTAssertEqual(timestampResult, 0)

        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1000, ageDays: 30)
        let item = try XCTUnwrap(result.items.first)
        let recordedAccess = try XCTUnwrap(item.lastAccessedAt)

        XCTAssertEqual(recordedAccess.timeIntervalSince1970, accessedAt.timeIntervalSince1970, accuracy: 2)
        XCTAssertEqual(item.modifiedAt.timeIntervalSince1970, modifiedAt.timeIntervalSince1970, accuracy: 2)
        XCTAssertEqual(result.removingItems(at: []).items.first?.lastAccessedAt, item.lastAccessedAt)
    }

    func testAIClutterRulesOnlyReturnRecognizedCachePaths() async throws {
        let folder = try temporaryFolder()
        let cache = folder.appendingPathComponent("Library/Caches/com.openai.codex/Code Cache", isDirectory: true)
        let history = folder.appendingPathComponent("Library/Application Support/Codex/History", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("rebuildable".utf8).write(to: cache.appendingPathComponent("cache.bin"))
        try Data("private conversation".utf8).write(to: history.appendingPathComponent("conversation.sqlite"))

        let result = try await scan(folder, kind: .aiClutter)

        XCTAssertEqual(result.items.map(\.name), ["cache.bin"])
        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(item.categories.contains(.aiCacheCandidate))
    }

    func testDeveloperCacheFindingsExplainToolAndKeepArchivesAndDependenciesOut() async throws {
        let volume = try temporaryFolder()
        let home = volume.appendingPathComponent("Users/tester", isDirectory: true)
        let cachePaths = [
            "Library/Developer/Xcode/DerivedData/Example/Build/Intermediates.noindex/Project.build/Objects-normal/arm64/Project.o",
            "Library/Developer/CoreSimulator/Caches/dyld/cache.data",
            "Library/Caches/Homebrew/downloads/package.tar.gz",
            "Library/Caches/pip/http-v2/response.cache",
            ".npm/_cacache/content-v2/sha512/package"
        ]
        let archivePath = "Library/Developer/Xcode/Archives/Example.xcarchive/Products/Applications/App.app/Contents/MacOS/App"
        let dependencyPath = "Documents/Project/node_modules/example/index.js"
        let simulatorDeviceDataPath = "Library/Developer/CoreSimulator/Devices/Device-1/data/Library/Caches/App/cache.data"

        for relativePath in cachePaths + [archivePath, dependencyPath, simulatorDeviceDataPath] {
            let file = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture data".utf8).write(to: file)
        }

        let request = ScanRequest(root: home, kind: .junk, minimumFileSizeBytes: 1, oldFileAgeDays: 365)
        let result = try await FileScanner(accountHome: home).scan(request) { _ in }

        XCTAssertEqual(Set(result.items.map(\.path)), Set(cachePaths.map { home.appendingPathComponent($0).path }))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0.sourceApplication) }),
            [
                "Project.o": "Xcode",
                "cache.data": "Simulator",
                "package.tar.gz": "Homebrew",
                "response.cache": "pip",
                "package": "npm"
            ]
        )
        XCTAssertTrue(result.items.allSatisfy { !$0.plainLanguageSummary.contains("commonly used") })
        let findings = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0) })
        XCTAssertTrue(try XCTUnwrap(findings["Project.o"]).plainLanguageSummary.contains("temporary build products"))
        XCTAssertTrue(try XCTUnwrap(findings["cache.data"]).plainLanguageSummary.contains("virtual devices and their data stay in place"))
        XCTAssertTrue(try XCTUnwrap(findings["package.tar.gz"]).plainLanguageSummary.contains("Installed apps stay in place"))
        XCTAssertTrue(try XCTUnwrap(findings["response.cache"]).plainLanguageSummary.contains("Python installs"))
        let npmItem = try XCTUnwrap(result.items.first { $0.sourceApplication == "npm" })
        XCTAssertTrue(npmItem.consequence.contains("installed dependencies are not removed"))
        XCTAssertFalse(result.items.contains {
            $0.path.contains(".xcarchive")
                || $0.path.contains("node_modules")
                || $0.path.contains("CoreSimulator/Devices")
        })
    }

    func testBrowserCachesAreHandledOnlyByDedicatedPrivacyCleanup() async throws {
        let home = try temporaryFolder()
        let firefoxCache = home.appendingPathComponent(
            "Library/Caches/Firefox/Profiles/test.default-release/cache2/entries",
            isDirectory: true
        )
        let chromeCache = home.appendingPathComponent(
            "Library/Caches/Google/Chrome/Default/Cache/Cache_Data/entry.cache",
            isDirectory: true
        )
        let ordinaryCache = home.appendingPathComponent("Library/Caches/Example/cache.bin")
        try FileManager.default.createDirectory(at: firefoxCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chromeCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinaryCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("browser cache".utf8).write(to: firefoxCache.appendingPathComponent("entry.bin"))
        try Data("chrome browser cache".utf8).write(to: chromeCache)
        try Data("ordinary cache".utf8).write(to: ordinaryCache)

        let request = ScanRequest(root: home, kind: .junk, minimumFileSizeBytes: 1, oldFileAgeDays: 365)
        let result = try await FileScanner(accountHome: home).scan(request) { _ in }

        XCTAssertFalse(result.items.contains { $0.path == firefoxCache.appendingPathComponent("entry.bin").path })
        XCTAssertFalse(result.items.contains { $0.path == chromeCache.path })
        XCTAssertTrue(SafeFilePolicy.shouldSkipDirectory(chromeCache.deletingLastPathComponent().path, homeDirectory: home))
        XCTAssertTrue(SafeFilePolicy.isCacheOrLogCandidate(ordinaryCache.path, homeDirectory: home))
        XCTAssertTrue(SafeFilePolicy.containsProtectedPathComponent(firefoxCache.path))
        XCTAssertTrue(SafeFilePolicy.containsProtectedPathComponent(chromeCache.path))
    }

    func testRecognizedCloudSyncDirectoriesAreSkippedDuringScan() async throws {
        let folder = try temporaryFolder()
        let localCache = folder.appendingPathComponent("Library/Caches/Example", isDirectory: true)
        let cloudCache = folder.appendingPathComponent("Library/CloudStorage/Drive/Caches/Example", isDirectory: true)
        try FileManager.default.createDirectory(at: localCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloudCache, withIntermediateDirectories: true)
        try Data("local temporary data".utf8).write(to: localCache.appendingPathComponent("cache.bin"))
        try Data("synced file".utf8).write(to: cloudCache.appendingPathComponent("cache.bin"))

        let result = try await scan(folder, kind: .junk)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.items[0].path.contains("/Library/Caches/Example/cache.bin"))
    }

    func testDiskScanIncludesOtherLocalAccountsReadOnlyAndOtherDiskLocations() async throws {
        let disk = try temporaryFolder().resolvingSymlinksInPath()
        let home = disk.appendingPathComponent("Users/tester", isDirectory: true)
        let shared = disk.appendingPathComponent("Users/Shared", isDirectory: true)
        let otherAccountLibrary = disk.appendingPathComponent("Users/other/Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherAccountLibrary, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: shared.appendingPathComponent("shared-file.txt"))
        try Data("private cache".utf8).write(to: otherAccountLibrary.appendingPathComponent("other-account-cache.bin"))
        for path in ["Documents/.git", "Documents/Project/.git", "Desktop", "Downloads", "Library/Mobile Documents", "Library/Caches", "Library/Application Support", "../../ExtraData", "../../System", "../other/Documents"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path, isDirectory: true).standardizedFileURL, withIntermediateDirectories: true)
        }
        for (path, value) in [("Documents/report.txt", "document"), ("Desktop/note.txt", "desktop"), ("Downloads/file.txt", "download"), ("Documents/Project/source.txt", "project"), ("Library/Mobile Documents/cloud.txt", "cloud"), ("Library/Caches/rebuildable.bin", "cache"), ("Library/Application Support/private-state.db", "private"), ("../../ExtraData/other.txt", "other"), ("../../System/protected.txt", "system"), ("../other/Documents/other-account.txt", "other account")] {
            try Data(value.utf8).write(to: home.appendingPathComponent(path).standardizedFileURL)
        }
        let request = ScanRequest(root: disk, kind: .largeAndOld, minimumFileSizeBytes: 1, oldFileAgeDays: 365, scanEntireDisk: true)
        let progress = ScanProgressLog()
        let result = try await FileScanner(accountHome: home).scan(request, progress: { progress.append($0) })
        XCTAssertEqual(Set(result.items.map(\.name)), Set(["report.txt", "note.txt", "file.txt", "shared-file.txt", "other.txt", "rebuildable.bin", "other-account.txt"]))
        XCTAssertEqual(result.space?.folderBytes[disk.path], 52)
        XCTAssertEqual(result.space?.directFileCounts[home.appendingPathComponent("Desktop").path], 1)
        XCTAssertEqual(result.space?.directFileCounts[shared.path], 1)
        XCTAssertFalse(result.items.contains { $0.name == "other-account-cache.bin" }, "Other accounts' Library data must stay out of the scan.")
        let otherAccountItem = try XCTUnwrap(result.items.first { $0.name == "other-account.txt" })
        guard case .protected(let reason) = SafeFilePolicy.assess(otherAccountItem, inside: disk, homeDirectory: home) else {
            return XCTFail("Files in another account must remain view-only.")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("view-only"))
        XCTAssertTrue(progress.values.contains { $0.entriesVisited > 0 }, "Progress should report directory entries before the scan has finished.")
        XCTAssertNil(result.removingItems(at: Set([try XCTUnwrap(result.items.first).path])).space)
    }

    func testDiskScanIncludesAccessibleMountedExternalVolumesAndSkipsICloudVolumes() async throws {
        let disk = try temporaryFolder().resolvingSymlinksInPath()
        let home = disk.appendingPathComponent("Users/tester", isDirectory: true)
        let external = disk.appendingPathComponent("Volumes/BackupDrive", isDirectory: true)
        let iCloud = disk.appendingPathComponent("Volumes/iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
        try Data("external file".utf8).write(to: external.appendingPathComponent("archive.dat"))
        try Data("cloud file".utf8).write(to: iCloud.appendingPathComponent("synced.dat"))

        let scanner = FileScanner(accountHome: home, externalVolumeProvider: { _ in [external, iCloud] })
        let request = ScanRequest(root: disk, kind: .largeAndOld, minimumFileSizeBytes: 1, oldFileAgeDays: 365, scanEntireDisk: true)
        let result = try await scanner.scan(request) { _ in }

        XCTAssertEqual(result.items.map(\.name), ["archive.dat"])
        XCTAssertEqual(result.space?.directFileCounts[external.path], 1)
    }

    func testMountedExternalVolumeDiscoveryReturnsDistinctVolumeRoots() {
        let volumes = FileScanner.discoverExternalVolumeRoots(URL(fileURLWithPath: "/", isDirectory: true))
        let paths = volumes.map(\.standardizedFileURL.path)

        XCTAssertEqual(paths, paths.sorted())
        XCTAssertEqual(paths.count, Set(paths).count)
        XCTAssertTrue(paths.allSatisfy { URL(fileURLWithPath: $0).deletingLastPathComponent().path == "/Volumes" })
        XCTAssertTrue(paths.allSatisfy { !SafeFilePolicy.containsProtectedPathComponent($0) })
        if let expectedPath = ProcessInfo.processInfo.environment["MAC_CLEANER_EXPECT_EXTERNAL_VOLUME"] {
            XCTAssertTrue(paths.contains(URL(fileURLWithPath: expectedPath).standardizedFileURL.path))
        }
    }

    func testSpaceSnapshotGroupsFileTypesForEachContainingFolder() async throws {
        let folder = try temporaryFolder()
        let nested = folder.appendingPathComponent("Pictures/Trips", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: nested.appendingPathComponent("one.jpg"))
        try Data(repeating: 2, count: 7).write(to: nested.appendingPathComponent("two.png"))
        try Data(repeating: 3, count: 11).write(to: nested.appendingPathComponent("notes.docx"))
        try Data(repeating: 4, count: 13).write(to: folder.appendingPathComponent("readme"))

        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1)
        let space = try XCTUnwrap(result.space)

        XCTAssertEqual(space.fileTypeBytes[folder.path]?[.photos], 12)
        XCTAssertEqual(space.fileTypeCounts[folder.path]?[.photos], 2)
        XCTAssertEqual(space.fileTypeBytes[nested.path]?[.documents], 11)
        XCTAssertEqual(space.fileTypeCounts[nested.path]?[.documents], 1)
        XCTAssertEqual(space.fileTypeBytes[folder.path]?[.noExtension], 13)
    }

    func testSpaceFileTypesUseReadableBroadCategories() {
        XCTAssertEqual(SpaceFileType.classify(fileExtension: "JPG"), .photos)
        XCTAssertEqual(SpaceFileType.classify(fileExtension: ".mov"), .videos)
        XCTAssertEqual(SpaceFileType.classify(fileExtension: "zip"), .archives)
        XCTAssertEqual(SpaceFileType.classify(fileExtension: "unknown-extension"), .other)
        XCTAssertEqual(SpaceFileType.classify(fileExtension: ""), .noExtension)
    }

    func testScanAccessAcknowledgementPersistsOncePerVersion() {
        let suiteName = "MacCleanerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScanAccessAcknowledgementStore(defaults: defaults)

        XCTAssertFalse(store.hasAccepted)
        store.accept()
        XCTAssertTrue(store.hasAccepted)
        XCTAssertTrue(ScanAccessAcknowledgementStore(defaults: defaults).hasAccepted)
    }

    func testFullDiskScanResultStoreRoundTripsDetailedReviewAndClearsIt() throws {
        let directory = try temporaryFolder()
        let store = ScanResultStore(directoryURL: directory.appendingPathComponent("review-storage", isDirectory: true))
        let result = savedReviewFixture()

        try store.save(result)
        let restored = try XCTUnwrap(store.load())

        XCTAssertTrue(store.hasSavedResult)
        XCTAssertEqual(restored.rootPath, "/")
        XCTAssertEqual(restored.kind, .smart)
        XCTAssertEqual(restored.finishedAt, result.finishedAt)
        XCTAssertEqual(restored.filesVisited, result.filesVisited)
        XCTAssertEqual(restored.items.count, 1)
        XCTAssertEqual(restored.items[0].path, result.items[0].path)
        XCTAssertEqual(restored.items[0].identity, result.items[0].identity)
        XCTAssertEqual(restored.items[0].cacheReviewDetails, result.items[0].cacheReviewDetails)
        XCTAssertEqual(restored.space?.fileTypeBytes["Downloads"]?[.archives], 2048)

        let filePermissions = try FileManager.default.attributesOfItem(atPath: storeFileURL(in: directory).path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("review-storage").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)

        try store.clear()
        XCTAssertFalse(store.hasSavedResult)
        XCTAssertNil(try store.load())
    }

    func testFullDiskScanResultStoreLoadsAndClearsLegacySandboxReview() throws {
        let directory = try temporaryFolder()
        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        let legacyStore = ScanResultStore(directoryURL: legacyDirectory)
        let legacyFile = legacyDirectory.appendingPathComponent("latest-full-disk-review.plist")
        try legacyStore.save(savedReviewFixture())

        let newStore = ScanResultStore(
            directoryURL: directory.appendingPathComponent("current", isDirectory: true),
            legacyFileURL: legacyFile
        )
        XCTAssertEqual(try newStore.load()?.items.first?.path, "/Users/tester/Downloads/archive.zip")
        XCTAssertTrue(newStore.hasSavedResult)

        try newStore.clear()
        XCTAssertFalse(newStore.hasSavedResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testFullDiskScanResultStoreRejectsFolderScopeAndCorruptSavedReview() throws {
        let directory = try temporaryFolder()
        let storageDirectory = directory.appendingPathComponent("review-storage", isDirectory: true)
        let store = ScanResultStore(directoryURL: storageDirectory)
        let folderResult = ScanResult(
            kind: .smart,
            rootPath: "/Users/tester/Documents",
            filesVisited: 0,
            entriesVisited: 0,
            entryLimit: 100,
            bytesVisited: 0,
            skippedItems: 0,
            skippedLocations: [],
            cloudFilesNotLocallyAvailable: nil,
            cloudFilesLocallyAvailable: nil,
            cloudDesktopAccessUnavailable: nil,
            excludedLocations: [],
            items: [],
            finishedAt: .now,
            wasTruncated: false,
            space: nil,
            duplicateKeepPreference: .oldest
        )
        XCTAssertThrowsError(try store.save(folderResult))

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: storageDirectory.appendingPathComponent("latest-full-disk-review.plist"))
        XCTAssertThrowsError(try store.load())
    }

    @MainActor
    func testScanViewModelRestoresSavedReviewWithoutGrantingCleanupAccess() throws {
        let directory = try temporaryFolder()
        let storageDirectory = directory.appendingPathComponent("review-storage", isDirectory: true)
        let resultStore = ScanResultStore(directoryURL: storageDirectory)
        let result = savedReviewFixture()
        try resultStore.save(result)

        let suiteName = "MacCleanerTests.ScanViewModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = ScanViewModel(
            scanNoticeStore: ScanAccessAcknowledgementStore(defaults: defaults),
            scanExclusionStore: ScanExclusionStore(defaults: defaults),
            savedScanFolderStore: SavedScanFolderStore(defaults: defaults),
            scanResultStore: resultStore,
            fullDiskAccessProbe: { false }
        )

        XCTAssertEqual(model.currentResult?.items.first?.path, result.items.first?.path)
        XCTAssertTrue(model.hasSavedFullDiskReview)
        XCTAssertFalse(model.standardFoldersAccessible)
        model.toggleSelection(for: try XCTUnwrap(model.currentResult?.items.first))
        XCTAssertTrue(model.selectedPaths.isEmpty)

        model.forgetSavedFullDiskReview()
        XCTAssertNil(model.currentResult)
        XCTAssertFalse(model.hasSavedFullDiskReview)
        XCTAssertNil(try resultStore.load())
    }

    private func savedReviewFixture() -> ScanResult {
        let item = ScanItem(
            path: "/Users/tester/Downloads/archive.zip",
            identity: FileIdentity(device: 1, inode: 2, size: 2048, modifiedAt: 1_700_000_000, linkCount: 1),
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_100),
            isCloudManaged: nil,
            categories: [.largeFile, .cacheCandidate],
            reasons: ["Large file", "Recognized temporary data"],
            safetyNote: "Review before deciding.",
            confidence: 0.8,
            duplicateGroupID: nil,
            duplicateGroupCount: 0,
            suggestedKeepPath: nil,
            cacheReviewDetails: CacheReviewDetails(
                sourceApplication: "Example App",
                summary: "Temporary data that may be recreated.",
                consequence: "The app may need to rebuild this data.",
                reason: "Known cache location"
            )
        )
        let space = SpaceSnapshot(
            folderBytes: ["Downloads": 2048],
            directFileBytes: ["Downloads": 2048],
            directFileCounts: ["Downloads": 1],
            fileTypeBytes: ["Downloads": [.archives: 2048]],
            fileTypeCounts: ["Downloads": [.archives: 1]]
        )
        return ScanResult(
            kind: .smart,
            rootPath: "/",
            filesVisited: 10,
            entriesVisited: 12,
            entryLimit: 1_000_000,
            bytesVisited: 4096,
            skippedItems: 1,
            skippedLocations: ["/private/example"],
            cloudFilesNotLocallyAvailable: nil,
            cloudFilesLocallyAvailable: nil,
            cloudDesktopAccessUnavailable: nil,
            excludedLocations: ["/Users/tester/Movies"],
            items: [item],
            finishedAt: Date(timeIntervalSince1970: 1_700_001_000),
            wasTruncated: false,
            space: space,
            duplicateKeepPreference: .newest
        )
    }

    private func storeFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("review-storage/latest-full-disk-review.plist")
    }

    func testScanLimitKeepsAndLabelsPartialResults() async throws {
        let folder = try temporaryFolder()
        for name in ["one", "two", "three"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let request = ScanRequest(root: folder, kind: .largeAndOld, minimumFileSizeBytes: 1, oldFileAgeDays: 365)
        let result = try await FileScanner(maximumEntries: 2).scan(request, progress: { _ in })
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.filesVisited, 2)
        XCTAssertEqual(result.entriesVisited, 2)
        XCTAssertEqual(result.entryLimit, 2)
        XCTAssertEqual(result.items.count, 2)
    }

    func testSkippedLocationSummaryShowsExamplesAndCountsTheRest() {
        let paths = (0..<50).map { "/Users/tester/Folder-\($0)" }
        let result = ScanResult(
            kind: .smart,
            rootPath: "/",
            filesVisited: 0,
            entriesVisited: 80,
            entryLimit: 1_000_000,
            bytesVisited: 0,
            skippedItems: 80,
            skippedLocations: paths,
            cloudFilesNotLocallyAvailable: nil,
            cloudFilesLocallyAvailable: nil,
            cloudDesktopAccessUnavailable: nil,
            excludedLocations: [],
            items: [],
            finishedAt: .now,
            wasTruncated: false,
            space: nil,
            duplicateKeepPreference: .oldest
        )

        XCTAssertEqual(result.displayedSkippedLocations.count, 5)
        XCTAssertEqual(result.omittedSkippedLocationCount, 75)
    }

    func testConfiguredExclusionSkipsSubtreeAndReportsExcludedPath() async throws {
        let root = try temporaryFolder()
        let excluded = root.appendingPathComponent("Downloads/Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 17).write(to: root.appendingPathComponent("keep.dat"))
        try Data(repeating: 2, count: 31).write(to: excluded.appendingPathComponent("skip.dat"))

        let request = ScanRequest(
            root: root,
            kind: .largeAndOld,
            minimumFileSizeBytes: 1,
            oldFileAgeDays: 365,
            excludedPaths: [excluded.path]
        )
        let result = try await FileScanner().scan(request) { _ in }

        XCTAssertEqual(result.filesVisited, 1)
        XCTAssertEqual(result.items.map(\.name), ["keep.dat"])
        XCTAssertEqual(result.excludedLocations, [excluded.path])
        XCTAssertEqual(result.space?.folderBytes[root.path], 17)
        XCTAssertNil(result.space?.folderBytes[excluded.path])
        XCTAssertEqual(result.skippedItems, 0)
    }

    func testCannotStartSpecificFolderScanInsideExcludedLocation() async throws {
        let root = try temporaryFolder()
        try Data("sample".utf8).write(to: root.appendingPathComponent("sample.txt"))
        let request = ScanRequest(
            root: root,
            kind: .largeAndOld,
            minimumFileSizeBytes: 1,
            oldFileAgeDays: 365,
            excludedPaths: [root.path]
        )

        do {
            _ = try await FileScanner().scan(request) { _ in }
            XCTFail("A folder inside a saved exclusion should not be scanned")
        } catch let error as ScanError {
            XCTAssertEqual(error, .excludedFolder(root.path))
        }
    }

    func testDuplicateSpaceEstimateExcludesOneSuggestedCopy() async throws {
        let folder = try temporaryFolder()
        for name in ["first.bin", "second.bin", "third.bin"] {
            try Data("same bytes".utf8).write(to: folder.appendingPathComponent(name))
        }

        let result = try await scan(folder, kind: .duplicates)

        XCTAssertEqual(result.potentialBytesToReview, 20)
        XCTAssertTrue(result.items.allSatisfy { $0.plainLanguageSummary.contains("same contents") })
    }

    func testHardLinksAreNotReportedAsRecoverableDuplicateCopies() async throws {
        let folder = try temporaryFolder()
        let original = folder.appendingPathComponent("original.bin")
        let hardLink = folder.appendingPathComponent("hard-link.bin")
        try Data("same data".utf8).write(to: original)
        let result = original.path.withCString { source in
            hardLink.path.withCString { destination in Darwin.link(source, destination) }
        }
        XCTAssertEqual(result, 0)

        let scanResult = try await scan(folder, kind: .duplicates)

        XCTAssertTrue(scanResult.items.isEmpty)
    }

    func testSymlinkAndProtectedCredentialsAreSkipped() async throws {
        let folder = try temporaryFolder()
        let target = folder.appendingPathComponent("ordinary.txt")
        try Data("ordinary".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: target)
        let ssh = folder.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("private key".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))

        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1)

        XCTAssertEqual(result.items.map(\.name), ["ordinary.txt"])
    }

    func testScanRootCannotBeAnEssentialSystemDirectory() async throws {
        do {
            _ = try await scan(URL(fileURLWithPath: "/System", isDirectory: true), kind: .smart)
            XCTFail("Expected the essential system location to be rejected")
        } catch let error as ScanError {
            XCTAssertEqual(error, .protectedFolder)
        }
    }

    func testCleanupRevalidationRejectsAChangedFile() async throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("candidate.bin")
        try Data("before".utf8).write(to: file)
        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1)
        let item = try XCTUnwrap(result.items.first)
        try Data("after with a different size".utf8).write(to: file)

        let assessment = SafeFilePolicy.assess(item, inside: folder)

        guard case .protected(let message) = assessment else {
            return XCTFail("Changed files must be blocked from cleanup")
        }
        XCTAssertTrue(message.contains("changed since scanning"))
    }

    func testCleanupRevalidationRejectsASelectedRootReplacedBySymlink() async throws {
        let parent = try temporaryFolder()
        let selectedRoot = parent.appendingPathComponent("selected", isDirectory: true)
        let movedRoot = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        let file = selectedRoot.appendingPathComponent("candidate.bin")
        try Data("candidate".utf8).write(to: file)

        let result = try await scan(selectedRoot, kind: .largeAndOld, minimumSize: 1)
        let item = try XCTUnwrap(result.items.first)
        try FileManager.default.moveItem(at: selectedRoot, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: movedRoot)

        guard case .protected = SafeFilePolicy.assess(item, inside: selectedRoot) else {
            return XCTFail("A selected root replaced by a symbolic link must be blocked")
        }
    }

    func testDuplicateGroupNeedsAnUnchangedUnselectedSurvivor() async throws {
        let folder = try temporaryFolder()
        try Data("identical bytes".utf8).write(to: folder.appendingPathComponent("first.bin"))
        try Data("identical bytes".utf8).write(to: folder.appendingPathComponent("second.bin"))
        let result = try await scan(folder, kind: .duplicates)
        let selected = try XCTUnwrap(result.items.first)
        let survivor = try XCTUnwrap(result.items.first { $0.path != selected.path })
        let groupID = try XCTUnwrap(selected.duplicateGroupID)
        let selection = Set([selected.path])

        XCTAssertTrue(SafeFilePolicy.hasCurrentDuplicateSurvivor(
            groupID: groupID,
            candidates: result.items,
            selectedPaths: selection,
            inside: folder
        ))
        try Data("replacement content with a different size".utf8).write(to: URL(fileURLWithPath: survivor.path))
        XCTAssertFalse(SafeFilePolicy.hasCurrentDuplicateSurvivor(
            groupID: groupID,
            candidates: result.items,
            selectedPaths: selection,
            inside: folder
        ))
    }

    func testDuplicateResultsDropStaleGroupAfterCleanup() async throws {
        let folder = try temporaryFolder()
        for name in ["first.bin", "second.bin", "third.bin"] {
            try Data("same bytes".utf8).write(to: folder.appendingPathComponent(name))
        }
        let result = try await scan(folder, kind: .smart, minimumSize: 1)
        XCTAssertEqual(result.items.count, 3)

        let firstPath = try XCTUnwrap(result.items.first).path
        let oneRemoved = result.removingItems(at: Set([firstPath]))
        XCTAssertEqual(oneRemoved.items.count, 2)
        XCTAssertTrue(oneRemoved.items.allSatisfy { $0.duplicateGroupCount == 2 })

        let twoRemoved = Set(result.items.prefix(2).map(\.path))
        let oneRemaining = result.removingItems(at: twoRemoved)
        XCTAssertEqual(oneRemaining.items.count, 1)
        let item = try XCTUnwrap(oneRemaining.items.first)
        XCTAssertFalse(item.categories.contains(.exactDuplicate))
        XCTAssertNil(item.duplicateGroupID)
    }

    func testPathContainmentUsesComponentBoundaries() {
        XCTAssertFalse(SafeFilePolicy.isInside("/tmp/scan-copy/item", root: "/tmp/scan"))
        XCTAssertTrue(SafeFilePolicy.isInside("/tmp/scan/item", root: "/tmp/scan"))
    }

    func testNestedRepositoryContentsAreExcluded() async throws {
        let folder = try temporaryFolder()
        let repository = folder.appendingPathComponent("Project", isDirectory: true)
        let metadata = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: repository.appendingPathComponent("source.swift"))
        try Data("ordinary".utf8).write(to: folder.appendingPathComponent("ordinary.txt"))

        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1)

        XCTAssertEqual(result.items.map(\.name), ["ordinary.txt"])
    }

    func testRepositoryRootIsRejected() async throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        do {
            _ = try await scan(folder, kind: .smart)
            XCTFail("A repository root should not be scanned for cleanup")
        } catch let error as ScanError {
            XCTAssertEqual(error, .protectedRepository)
        }
    }

    func testRepositoryProtectionRecognizesWorktreeMetadataAboveSelectedFolder() throws {
        let repository = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: repository) }
        try Data("gitdir: ../.git/worktrees/sample".utf8).write(to: repository.appendingPathComponent(".git"))
        let selectedFolder = repository.appendingPathComponent("working-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: false)

        XCTAssertTrue(SafeFilePolicy.isInsideDevelopmentRepository(selectedFolder.path))
    }

    func testCancellationPropagatesToTheScanner() async throws {
        let folder = try temporaryFolder()
        let request = ScanRequest(root: folder, kind: .smart, minimumFileSizeBytes: 1, oldFileAgeDays: 1)
        let operation = Task { try await FileScanner().scan(request, progress: { _ in }) }
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("The cancelled scan should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func scan(
        _ folder: URL,
        kind: ScanKind,
        minimumSize: Int64 = 1_000_000,
        ageDays: Int = 365,
        keepPreference: DuplicateKeepPreference = .oldest
    ) async throws -> ScanResult {
        try await FileScanner().scan(
            ScanRequest(
                root: folder,
                kind: kind,
                minimumFileSizeBytes: minimumSize,
                oldFileAgeDays: ageDays,
                duplicateKeepPreference: keepPreference
            ),
            progress: { _ in }
        )
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacCleanerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

final class ApplicationInventoryTests: XCTestCase {
    func testFindsBundlesWithoutFollowingSymlinksOrCountingNestedApps() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app/Contents", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.example", "CFBundleName": "Example", "CFBundleShortVersionString": "1.2"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        try Data(repeating: 1, count: 20).write(to: app.appendingPathComponent("data"))
        let hiddenContents = root.appendingPathComponent(".Hidden.app/Contents", isDirectory: true)
        try fm.createDirectory(at: hiddenContents, withIntermediateDirectories: true)
        let hiddenPlist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.hidden"],
            format: .xml,
            options: 0
        )
        try hiddenPlist.write(to: hiddenContents.appendingPathComponent("Info.plist"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: app.deletingLastPathComponent())
        let result = ApplicationInventory().scan(roots: [root, root])
        XCTAssertEqual(result.applications.count, 1)
        XCTAssertEqual(result.applications.first?.name, "Example")
        XCTAssertEqual(result.applications.first?.version, "1.2")
        XCTAssertEqual(result.applications.first?.logicalSize, Int64(data.count + 20))
        XCTAssertEqual(result.inaccessibleLocations, 0)

        let identifiers = ApplicationInventory().bundleIdentifiers(roots: [root])
        XCTAssertEqual(identifiers.identifiers, ["test.example", "test.hidden"])
        XCTAssertTrue(identifiers.isComplete)
    }

    func testBundleIdentifierInventoryReportsApplicationAndTraversalLimits() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        for (name, identifier) in [("First", "test.first"), ("Second", "test.second")] {
            let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": identifier],
                format: .xml,
                options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }

        let appLimited = ApplicationInventory().bundleIdentifiers(roots: [root], maximumApplications: 1)
        XCTAssertEqual(appLimited.identifiers.count, 1)
        XCTAssertTrue(appLimited.wasLimited)
        XCTAssertFalse(appLimited.isComplete)

        let traversalLimited = ApplicationInventory().bundleIdentifiers(roots: [root], maximumVisitedEntries: 0)
        XCTAssertTrue(traversalLimited.identifiers.isEmpty)
        XCTAssertTrue(traversalLimited.wasLimited)
        XCTAssertFalse(traversalLimited.isComplete)
    }

    func testApplicationInventoryAppliesEntryAndBundleSizeBudgets() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Large.app/Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.large", "CFBundleName": "Large"],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        for index in 0..<512 {
            try Data([UInt8(index % 255)]).write(to: contents.appendingPathComponent("file-\(index)"))
            try Data([UInt8(index % 255)]).write(to: root.appendingPathComponent("root-file-\(index)"))
        }

        let sizeLimited = ApplicationInventory().scan(
            roots: [root],
            maximumSizeEntries: 16
        )
        XCTAssertEqual(sizeLimited.applications.count, 1)
        XCTAssertTrue(sizeLimited.applications[0].sizeIncomplete)
        XCTAssertTrue(sizeLimited.wasLimited)
        XCTAssertFalse(sizeLimited.isComplete)

        let entryLimited = ApplicationInventory().scan(
            roots: [root],
            includeSizes: false,
            maximumVisitedEntries: 1
        )
        XCTAssertTrue(entryLimited.wasLimited)
        XCTAssertFalse(entryLimited.isComplete)
    }

    func testApplicationInventoryStopsWhenCancelled() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("item"))

        let result = ApplicationInventory().scan(roots: [root], includeSizes: false, isCancelled: { true })

        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.isComplete)
    }

    func testGroupOwnershipUsesSignedEntitlementsAndRejectsChangedBundles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Shared.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Shared")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.shared.app",
            "CFBundleName": "Shared",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Shared"
        ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let groupID = "ABCDE12345.test.shared.app.group"
        let entitlements = try PropertyListSerialization.data(fromPropertyList: [
            "com.apple.security.application-groups": [groupID]
        ], format: .xml, options: 0)
        let entitlementsURL = root.appendingPathComponent("entitlements.plist")
        try entitlements.write(to: entitlementsURL)

        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--entitlements", entitlementsURL.path, bundle.path]
        signer.standardOutput = Pipe()
        signer.standardError = Pipe()
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        XCTAssertEqual(ApplicationGroupEntitlementReader.readGroupIdentifiers(from: bundle), [groupID])
        let inventory = ApplicationInventory().bundleIdentifiers(roots: [root])
        XCTAssertEqual(inventory.groupOwners[groupID]?.map(\.bundleIdentifier), ["test.shared.app"])
        XCTAssertFalse(inventory.groupOwnershipIncomplete)

        var alteredExecutable = try Data(contentsOf: executable)
        alteredExecutable.append(Data("# changed after signing\n".utf8))
        try alteredExecutable.write(to: executable)
        XCTAssertNil(ApplicationGroupEntitlementReader.readGroupIdentifiers(from: bundle))
        XCTAssertTrue(ApplicationInventory().bundleIdentifiers(roots: [root]).groupOwnershipIncomplete)
    }
}
