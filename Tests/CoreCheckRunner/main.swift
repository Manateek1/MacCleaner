import Darwin
import Foundation

@main
enum CoreCheckRunner {
    static func main() async throws {
        try run("descriptor path", checkDescriptorPath)
        try run("iCloud Desktop metadata scope", checkICloudDesktopMetadataScope)
        try await run("exact duplicates", checkDuplicates)
        try await run("large and old files", checkLargeAndOldFiles)
        try await run("AI clutter rules", checkAIClutterRules)
        try await run("developer cache review", checkDeveloperCacheReview)
        try await run("cloud-sync exclusions", checkCloudSyncDirectoriesAreSkipped)
        try await run("full-disk personal folders", checkDiskScanIncludesPersonalFoldersAndOtherLocations)
        try await run("partial results at scan limit", checkLargeScanReturnsPartialResults)
        try await run("hard-link safety", checkHardLinks)
        try await run("symlink and sensitive-path safety", checkSymlinksAndSensitivePaths)
        try await run("system-root protection", checkSystemRootProtection)
        try await run("changed-file protection", checkChangedFileProtection)
        try await run("duplicate survivor validation", checkDuplicateSurvivorValidation)
        try await run("duplicate results refresh", checkDuplicateResultsRefreshAfterRemoval)
        try await run("duplicate space estimate and explanation", checkDuplicateSpaceEstimateAndExplanation)
        try await run("selected-root symlink protection", checkSelectedRootSymlinkProtection)
        try await run("nested repository protection", checkNestedRepositoryProtection)
        try await run("repository-root protection", checkRepositoryRootProtection)
        try await run("scan cancellation", checkCancellation)
        try await run("10,000-file tree stress", checkLargeTreeStress)
        try run("path boundaries", checkPathBoundaries)
        try run("CPU metric math", checkCPUMetricMath)
        print("Mac Cleaner core checks passed (23 cases).")
    }

    private static func run(_ name: String, _ check: () async throws -> Void) async throws {
        let startedAt = Date()
        print("[CoreCheck] Starting \(name)")
        fflush(stdout)
        try await check()
        print("[CoreCheck] Passed \(name) in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        fflush(stdout)
    }

    private static func run(_ name: String, _ check: () throws -> Void) throws {
        let startedAt = Date()
        print("[CoreCheck] Starting \(name)")
        fflush(stdout)
        try check()
        print("[CoreCheck] Passed \(name) in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        fflush(stdout)
    }

    private static func checkDuplicates() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("same bytes".utf8).write(to: folder.appendingPathComponent("first.txt"))
        try Data("same bytes".utf8).write(to: folder.appendingPathComponent("second.txt"))
        try Data("same bYtes".utf8).write(to: folder.appendingPathComponent("third.txt"))
        let result = try await FileScanner().scan(
            ScanRequest(root: folder, kind: .duplicates, minimumFileSizeBytes: 1_000_000, oldFileAgeDays: 365),
            progress: { progress in
                print("[CoreCheck] Duplicate scan progress: \(progress.stage)")
                fflush(stdout)
            }
        )
        try expect(result.items.count == 2, "exact duplicates should be grouped")
        try expect(result.items.allSatisfy { $0.duplicateGroupCount == 2 }, "duplicate group count should be two")
        try expect(Set(result.items.compactMap(\.suggestedKeepPath)).count == 1, "one suggested copy should remain")
    }

    private static func checkDescriptorPath() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let canonical = SafeFileAccess.canonicalDirectoryPath(folder.path) else {
            throw CheckFailure(message: "a temporary directory should have a canonical descriptor path")
        }
        let descriptor = SafeFileAccess.openDirectoryDescriptor(canonical)
        try expect(descriptor >= 0, "a canonical temporary directory should open safely")
        defer { Darwin.close(descriptor) }
        try expect(SafeFileAccess.descriptorPath(descriptor) == canonical, "descriptor path should match the canonical directory")
    }

    private static func checkICloudDesktopMetadataScope() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/tmp/mac-cleaner-fixture", isDirectory: true)

        try expect(
            ICloudDesktopPolicy.shouldInspectDesktop(for: desktop, scanEntireDisk: false, accountHome: home),
            "a Desktop scan should inspect whether Desktop is in iCloud"
        )
        try expect(
            ICloudDesktopPolicy.shouldInspectDesktop(for: desktop.appendingPathComponent("Photos"), scanEntireDisk: false, accountHome: home),
            "a scan inside Desktop should inspect whether Desktop is in iCloud"
        )
        try expect(
            ICloudDesktopPolicy.shouldInspectDesktop(for: home, scanEntireDisk: false, accountHome: home),
            "a home-folder scan should inspect whether Desktop is in iCloud"
        )
        try expect(
            !ICloudDesktopPolicy.shouldInspectDesktop(for: downloads, scanEntireDisk: false, accountHome: home),
            "a Downloads scan should not coordinate unrelated Desktop metadata"
        )
        try expect(
            !ICloudDesktopPolicy.shouldInspectDesktop(for: temporary, scanEntireDisk: false, accountHome: home),
            "an unrelated folder scan should not coordinate Desktop metadata"
        )
        try expect(
            ICloudDesktopPolicy.shouldInspectDesktop(for: URL(fileURLWithPath: "/", isDirectory: true), scanEntireDisk: true, accountHome: home),
            "a full-disk scan should inspect Desktop whether or not it is in iCloud"
        )
    }

    private static func checkLargeAndOldFiles() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("large.dat")
        try Data(repeating: 0x41, count: 4096).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 24 * 60 * 60)], ofItemAtPath: file.path)
        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1000, ageDays: 365)
        try expect(result.items.count == 1, "threshold scanner should return the matching file")
        try expect(result.items[0].categories.contains(.largeFile), "size threshold should match")
        try expect(result.items[0].categories.contains(.oldFile), "age threshold should match")
    }

    private static func checkAIClutterRules() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("Library/Caches/com.openai.codex/Code Cache", isDirectory: true)
        let history = folder.appendingPathComponent("Library/Application Support/Codex/History", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("rebuildable".utf8).write(to: cache.appendingPathComponent("cache.bin"))
        try Data("private conversation".utf8).write(to: history.appendingPathComponent("conversation.sqlite"))
        let result = try await scan(folder, kind: .aiClutter)
        try expect(result.items.map(\.name) == ["cache.bin"], "only the AI cache file should be included")
    }

    private static func checkDeveloperCacheReview() async throws {
        let volume = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: volume) }
        let home = volume.appendingPathComponent("Users/tester", isDirectory: true)
        let cachePaths = [
            "Library/Developer/Xcode/DerivedData/Example/Build/Intermediates.noindex/Project.build/Objects-normal/arm64/Project.o",
            "Library/Developer/CoreSimulator/Caches/dyld/cache.data",
            "Library/Caches/Homebrew/downloads/package.tar.gz",
            "Library/Caches/pip/http-v2/response.cache",
            ".npm/_cacache/content-v2/sha512/package"
        ]
        let archivePath = home.appendingPathComponent("Library/Developer/Xcode/Archives/Example.xcarchive/Products/Applications/App.app/Contents/MacOS/App")
        let simulatorDeviceData = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/Device-1/data/Library/Caches/App/cache.data")
        for relativePath in cachePaths {
            let file = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        try FileManager.default.createDirectory(at: archivePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user archive".utf8).write(to: archivePath)
        try FileManager.default.createDirectory(at: simulatorDeviceData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user simulator data".utf8).write(to: simulatorDeviceData)

        let result = try await FileScanner(accountHome: home).scan(
            ScanRequest(root: home, kind: .junk, minimumFileSizeBytes: 1, oldFileAgeDays: 365)
        ) { _ in }

        try expect(result.items.count == 5, "only the five recognized default developer caches should be candidates: \(result.items.map { $0.path })")
        try expect(Set(result.items.map { $0.sourceApplication }) == Set(["Xcode", "Simulator", "Homebrew", "pip", "npm"]), "each known cache should identify its tool")
        try expect(result.items.allSatisfy { !$0.plainLanguageSummary.contains("commonly used") }, "known caches should have a useful plain-language explanation")
        try expect(!result.items.contains { $0.path.contains(".xcarchive") }, "Xcode archives must not be treated as caches")
        try expect(!result.items.contains { $0.path.contains("CoreSimulator/Devices") }, "simulator device data must stay protected")
    }

    private static func checkCloudSyncDirectoriesAreSkipped() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let localCache = folder.appendingPathComponent("Library/Caches/Example", isDirectory: true)
        let cloudCache = folder.appendingPathComponent("Library/CloudStorage/Drive/Caches/Example", isDirectory: true)
        try FileManager.default.createDirectory(at: localCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloudCache, withIntermediateDirectories: true)
        try Data("local temporary data".utf8).write(to: localCache.appendingPathComponent("cache.bin"))
        try Data("synced file".utf8).write(to: cloudCache.appendingPathComponent("cache.bin"))

        let result = try await scan(folder, kind: .junk)

        try expect(
            result.items.count == 1 && result.items[0].path.contains("/Library/Caches/Example/cache.bin"),
            "recognized cloud-sync folders should not be traversed: \(result.items.map(\.path))"
        )
    }

    private static func checkDiskScanIncludesPersonalFoldersAndOtherLocations() async throws {
        let temporary = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let disk = temporary.resolvingSymlinksInPath()
        let home = disk.appendingPathComponent("Users/tester", isDirectory: true)
        let folders = ["Documents/.git", "Documents/Project/.git", "Desktop", "Downloads", "Library/Mobile Documents", "../../ExtraData", "../../System"]
        for path in folders { try FileManager.default.createDirectory(at: home.appendingPathComponent(path, isDirectory: true).standardizedFileURL, withIntermediateDirectories: true) }
        for (path, value) in [("Documents/report.txt", "document"), ("Desktop/note.txt", "desktop"), ("Downloads/file.txt", "download"), ("Documents/Project/source.txt", "project"), ("Library/Mobile Documents/cloud.txt", "cloud"), ("../../ExtraData/other.txt", "other"), ("../../System/protected.txt", "system")] {
            try Data(value.utf8).write(to: home.appendingPathComponent(path).standardizedFileURL)
        }
        let request = ScanRequest(root: disk, kind: .largeAndOld, minimumFileSizeBytes: 1, oldFileAgeDays: 365, scanEntireDisk: true)
        let result = try await FileScanner(accountHome: home).scan(request, progress: { _ in })
        try expect(Set(result.items.map(\.name)) == Set(["report.txt", "note.txt", "file.txt", "other.txt"]), "disk scan should include personal folders and other disk locations once, while skipping cloud, nested repositories, and system data")
        guard let space = result.space else { throw CheckFailure(message: "disk scan should include folder totals") }
        try expect(space.folderBytes[disk.path] == 28, "space map should sum only checked files: root=\(disk.path), totals=\(space.folderBytes)")
        try expect(space.directFileCounts[home.appendingPathComponent("Desktop").path] == 1, "space map should count files in their direct folder")
        try expect(result.removingItems(at: Set([result.items[0].path])).space == nil, "cleanup should invalidate the old space map")
    }

    private static func checkLargeScanReturnsPartialResults() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["one", "two", "three"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let request = ScanRequest(root: folder, kind: .largeAndOld, minimumFileSizeBytes: 1, oldFileAgeDays: 365)
        let result = try await FileScanner(maximumEntries: 2).scan(request, progress: { _ in })
        try expect(result.wasTruncated && result.filesVisited == 2 && result.items.count == 2, "a large scan should keep and label partial results")
    }

    private static func checkHardLinks() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.bin")
        let linked = folder.appendingPathComponent("hard-link.bin")
        try Data("same data".utf8).write(to: original)
        let linkResult = original.path.withCString { source in linked.path.withCString { Darwin.link(source, $0) } }
        try expect(linkResult == 0, "fixture hard link should be created")
        let result = try await scan(folder, kind: .duplicates)
        try expect(result.items.isEmpty, "hard links must not count as duplicate storage")
    }

    private static func checkSymlinksAndSensitivePaths() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ordinary = folder.appendingPathComponent("ordinary.txt")
        try Data("ordinary".utf8).write(to: ordinary)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: ordinary)
        let ssh = folder.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("private key".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1)
        try expect(result.items.map(\.name) == ["ordinary.txt"], "symlinks and SSH material must be excluded")
    }

    private static func checkSystemRootProtection() async throws {
        do {
            _ = try await scan(URL(fileURLWithPath: "/System", isDirectory: true), kind: .smart)
            throw CheckFailure(message: "essential system roots should be rejected")
        } catch ScanError.protectedFolder {
            return
        }
    }

    private static func checkChangedFileProtection() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("candidate.bin")
        try Data("before".utf8).write(to: file)
        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1)
        guard let item = result.items.first else { throw CheckFailure(message: "test candidate was not found") }
        try Data("after with a different size".utf8).write(to: file)
        let decision = SafeFilePolicy.assess(item, inside: folder)
        guard case .protected(let message) = decision, message.contains("changed since scanning") else {
            throw CheckFailure(message: "changed file should be blocked at cleanup revalidation")
        }
    }

    private static func checkDuplicateSurvivorValidation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("identical bytes".utf8).write(to: folder.appendingPathComponent("first.bin"))
        try Data("identical bytes".utf8).write(to: folder.appendingPathComponent("second.bin"))
        let result = try await scan(folder, kind: .duplicates)
        guard let selected = result.items.first,
              let survivor = result.items.first(where: { $0.path != selected.path }),
              let groupID = selected.duplicateGroupID else {
            throw CheckFailure(message: "the duplicate fixture should produce one two-file group")
        }
        let selection = Set([selected.path])
        try expect(
            SafeFilePolicy.hasCurrentDuplicateSurvivor(groupID: groupID, candidates: result.items, selectedPaths: selection, inside: folder),
            "an unchanged unselected duplicate should count as the survivor"
        )
        try Data("replacement content with a different size".utf8).write(to: URL(fileURLWithPath: survivor.path))
        try expect(
            !SafeFilePolicy.hasCurrentDuplicateSurvivor(groupID: groupID, candidates: result.items, selectedPaths: selection, inside: folder),
            "a changed unselected duplicate must not count as the survivor"
        )
    }

    private static func checkDuplicateResultsRefreshAfterRemoval() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["first.bin", "second.bin", "third.bin"] {
            try Data("same bytes".utf8).write(to: folder.appendingPathComponent(name))
        }
        let result = try await scan(folder, kind: .smart, minimumSize: 1)
        try expect(result.items.count == 3, "all duplicate fixtures should be listed")
        let oneRemoved = result.removingItems(at: Set([result.items[0].path]))
        try expect(oneRemoved.items.count == 2, "remaining duplicate candidates should stay visible")
        try expect(oneRemoved.items.allSatisfy { $0.duplicateGroupCount == 2 }, "the remaining group size should be refreshed")
        let twoRemovedPaths = Set(result.items.prefix(2).map(\.path))
        let oneRemaining = result.removingItems(at: twoRemovedPaths)
        try expect(oneRemaining.items.count == 1, "non-duplicate findings should remain visible")
        try expect(!oneRemaining.items[0].categories.contains(.exactDuplicate), "the final copy must lose stale duplicate status")
        try expect(oneRemaining.items[0].duplicateGroupID == nil, "the final copy must lose duplicate selection metadata")
    }

    private static func checkDuplicateSpaceEstimateAndExplanation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["first.bin", "second.bin", "third.bin"] {
            try Data("same bytes".utf8).write(to: folder.appendingPathComponent(name))
        }

        let result = try await scan(folder, kind: .duplicates)

        try expect(result.potentialBytesToReview == 20, "estimated duplicate space should exclude one suggested copy")
        try expect(result.items.allSatisfy { $0.plainLanguageSummary.contains("same contents") }, "duplicate explanation should use plain language")
    }

    private static func checkSelectedRootSymlinkProtection() async throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let selectedRoot = parent.appendingPathComponent("selected", isDirectory: true)
        let movedRoot = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        let file = selectedRoot.appendingPathComponent("candidate.bin")
        try Data("candidate".utf8).write(to: file)
        let result = try await scan(selectedRoot, kind: .largeAndOld, minimumSize: 1)
        guard let item = result.items.first else { throw CheckFailure(message: "test candidate was not found") }
        try FileManager.default.moveItem(at: selectedRoot, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: movedRoot)
        guard case .protected = SafeFilePolicy.assess(item, inside: selectedRoot) else {
            throw CheckFailure(message: "a symlink replacement of the selected root must be blocked")
        }
    }

    private static func checkNestedRepositoryProtection() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = folder.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: repository.appendingPathComponent("source.swift"))
        try Data("ordinary".utf8).write(to: folder.appendingPathComponent("ordinary.txt"))
        let result = try await scan(folder, kind: .largeAndOld, minimumSize: 1)
        try expect(result.items.map(\.name) == ["ordinary.txt"], "nested repositories and source files must be skipped")
    }

    private static func checkRepositoryRootProtection() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        do {
            _ = try await scan(folder, kind: .smart)
            throw CheckFailure(message: "a repository root should not be scanned")
        } catch ScanError.protectedRepository {
            return
        }
    }

    private static func checkCancellation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = ScanRequest(root: folder, kind: .smart, minimumFileSizeBytes: 1, oldFileAgeDays: 1)
        let operation = Task { try await FileScanner().scan(request, progress: { _ in }) }
        operation.cancel()
        do {
            _ = try await operation.value
            throw CheckFailure(message: "the cancelled scan should throw CancellationError")
        } catch is CancellationError {
            return
        }
    }

    private static func checkLargeTreeStress() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileCount = 10_000
        let bucketCount = 100
        for bucket in 0..<bucketCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(String(format: "bucket-%02d", bucket), isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        for index in 0..<fileCount {
            let bucket = String(format: "bucket-%02d", index % bucketCount)
            let file = root.appendingPathComponent(bucket, isDirectory: true)
                .appendingPathComponent(String(format: "file-%05d.dat", index))
            try Data([UInt8(index & 0xff)]).write(to: file)
        }

        let startedAt = Date()
        let result = try await FileScanner(maximumEntries: fileCount + bucketCount + 100).scan(
            ScanRequest(root: root, kind: .largeAndOld, minimumFileSizeBytes: Int64.max, oldFileAgeDays: 365),
            progress: { _ in }
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        try expect(result.filesVisited == fileCount, "stress scan should inspect all \(fileCount) synthetic files; found \(result.filesVisited)")
        try expect(!result.wasTruncated && result.items.isEmpty, "stress scan should finish without truncation or candidates")
        print("[Stress] Traversed \(fileCount.formatted()) synthetic files in \(String(format: "%.2f", elapsed))s")
        fflush(stdout)
    }

    private static func checkPathBoundaries() throws {
        try expect(!SafeFilePolicy.isInside("/tmp/scan-copy/item", root: "/tmp/scan"), "path prefix must respect component boundaries")
        try expect(SafeFilePolicy.isInside("/tmp/scan/item", root: "/tmp/scan"), "child path should be inside root")
    }

    private static func checkCPUMetricMath() throws {
        let previous = CPULoadCounters(totalTicks: 100, idleTicks: 60)
        let current = CPULoadCounters(totalTicks: 200, idleTicks: 110)
        try expect(
            SystemMetricMath.cpuUsagePercent(previous: previous, current: current) == 50,
            "CPU usage should be calculated from the change in busy ticks"
        )
        try expect(
            SystemMetricMath.cpuUsagePercent(previous: nil, current: current) == nil,
            "CPU usage should be unavailable without a baseline sample"
        )
        try expect(
            SystemMetricMath.cpuUsagePercent(previous: current, current: previous) == nil,
            "CPU usage should be unavailable when counters reset"
        )
    }

    private static func scan(_ folder: URL, kind: ScanKind, minimumSize: Int64 = 1_000_000, ageDays: Int = 365) async throws -> ScanResult {
        try await FileScanner().scan(
            ScanRequest(root: folder, kind: kind, minimumFileSizeBytes: minimumSize, oldFileAgeDays: ageDays),
            progress: { _ in }
        )
    }

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacCleanerCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message: message) }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
