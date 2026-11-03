import CryptoKit
import Darwin
import Foundation

enum LocalBrowser: String, CaseIterable, Equatable, Sendable {
    case safari
    case chrome
    case firefox

    var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .firefox: "org.mozilla.firefox"
        }
    }
}

struct BrowserCacheCandidate: Identifiable, Equatable, Sendable {
    let browser: LocalBrowser
    let title: String
    let path: String
    let sizeBytes: Int64
    let fileCount: Int
    let lastChangedAt: Date?
    let browserIsRunning: Bool
    let canMoveToTrash: Bool
    let statusMessage: String?
    fileprivate let fingerprint: String

    var id: String { path }
    var name: String { URL(fileURLWithPath: path, isDirectory: true).lastPathComponent }
}

struct BrowserPrivacyProgress: Sendable {
    let locationName: String
    let entriesChecked: Int
}

struct BrowserPrivacyInventory: Sendable {
    let candidates: [BrowserCacheCandidate]
    let skippedLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool
}

enum BrowserPrivacyCleanupError: LocalizedError, Equatable {
    case browserRunning
    case outsideSupportedCache
    case changedSinceReview
    case incomplete
    case unavailable

    var errorDescription: String? {
        switch self {
        case .browserRunning:
            "Quit the browser before moving its cache to Trash."
        case .outsideSupportedCache:
            "This folder is outside the browser cache locations Mac Cleaner supports."
        case .changedSinceReview:
            "This cache changed after it was reviewed. Scan again before deciding what to do."
        case .incomplete:
            "Mac Cleaner could not fully inspect this cache, so it was left in place."
        case .unavailable:
            "This cache is no longer available. Scan again before deciding what to do."
        }
    }
}

struct BrowserCacheMoveResult: Sendable {
    let path: String
    let sizeBytes: Int64
}

struct BrowserPrivacyCleanupService: Sendable {
    private static let chromeCacheDirectories = [
        ("Cache", "web cache"),
        ("Code Cache", "code cache"),
        ("GPUCache", "graphics cache"),
        ("image_cache", "image cache"),
        ("ShaderCache", "shader cache")
    ]

    private let homeURL: URL
    private let maximumEntriesPerCache: Int
    private let maximumTotalEntries: Int
    private let trashOperation: @Sendable (URL) throws -> Void

    init(
        homeURL: URL = SafeFilePolicy.accountHome,
        maximumEntriesPerCache: Int = 100_000,
        maximumTotalEntries: Int = 500_000,
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.homeURL = homeURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        self.maximumEntriesPerCache = max(1, maximumEntriesPerCache)
        self.maximumTotalEntries = max(1, maximumTotalEntries)
        self.trashOperation = trashOperation
    }

    func scan(
        runningBundleIdentifiers: Set<String> = [],
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (BrowserPrivacyProgress) -> Void = { _ in }
    ) -> BrowserPrivacyInventory {
        guard isSafeHome else {
            return BrowserPrivacyInventory(candidates: [], skippedLocations: 1, wasLimited: false, wasCancelled: false)
        }

        var skipped = 0
        let targets = discoverTargets(skippedLocations: &skipped)
        var candidates: [BrowserCacheCandidate] = []
        var entriesChecked = 0
        var wasLimited = false

        for target in targets {
            guard !isCancelled() else {
                return BrowserPrivacyInventory(candidates: [], skippedLocations: skipped, wasLimited: wasLimited, wasCancelled: true)
            }
            let remaining = maximumTotalEntries - entriesChecked
            guard remaining > 0 else {
                wasLimited = true
                break
            }
            guard isSupportedCache(target.url, for: target.browser), let metadata = metadata(at: target.url), metadata.kind == .directory else {
                skipped += 1
                continue
            }

            let running = runningBundleIdentifiers.contains(target.browser.bundleIdentifier)
            let entriesCheckedBeforeTarget = entriesChecked
            let inspection = inspect(
                target.url,
                browser: target.browser,
                maximumEntries: min(maximumEntriesPerCache, remaining),
                isCancelled: isCancelled,
                progress: { count in
                    progress(BrowserPrivacyProgress(
                        locationName: target.title,
                        entriesChecked: entriesCheckedBeforeTarget + count
                    ))
                }
            )
            guard let inspection else {
                skipped += 1
                continue
            }
            if inspection.wasCancelled {
                return BrowserPrivacyInventory(candidates: [], skippedLocations: skipped, wasLimited: wasLimited, wasCancelled: true)
            }

            entriesChecked += inspection.entriesChecked
            wasLimited = wasLimited || inspection.wasLimited
            skipped += inspection.unreadableLocations
            candidates.append(BrowserCacheCandidate(
                browser: target.browser,
                title: target.title,
                path: target.url.path,
                sizeBytes: inspection.sizeBytes,
                fileCount: inspection.fileCount,
                lastChangedAt: inspection.lastChangedAt,
                browserIsRunning: running,
                canMoveToTrash: !running && inspection.isComplete,
                statusMessage: running
                    ? "Quit \(target.browser.title) before clearing its cache."
                    : inspection.isComplete
                        ? nil
                        : "This cache could not be fully checked, so it is unavailable for cleanup.",
                fingerprint: inspection.fingerprint
            ))
        }

        candidates.sort {
            if $0.browser != $1.browser { return $0.browser.title < $1.browser.title }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return BrowserPrivacyInventory(
            candidates: candidates,
            skippedLocations: skipped,
            wasLimited: wasLimited,
            wasCancelled: false
        )
    }

    func moveToTrash(
        _ candidate: BrowserCacheCandidate,
        runningBundleIdentifiers: Set<String>
    ) throws -> BrowserCacheMoveResult {
        guard isSupportedCache(URL(fileURLWithPath: candidate.path, isDirectory: true), for: candidate.browser) else {
            throw BrowserPrivacyCleanupError.outsideSupportedCache
        }
        guard candidate.canMoveToTrash else { throw BrowserPrivacyCleanupError.incomplete }
        guard !runningBundleIdentifiers.contains(candidate.browser.bundleIdentifier) else {
            throw BrowserPrivacyCleanupError.browserRunning
        }

        let url = URL(fileURLWithPath: candidate.path, isDirectory: true).standardizedFileURL
        guard let current = inspect(
            url,
            browser: candidate.browser,
            maximumEntries: maximumEntriesPerCache,
            isCancelled: { false },
            progress: { _ in }
        ) else {
            throw BrowserPrivacyCleanupError.unavailable
        }
        guard current.isComplete else { throw BrowserPrivacyCleanupError.incomplete }
        guard current.fingerprint == candidate.fingerprint,
              current.sizeBytes == candidate.sizeBytes,
              current.fileCount == candidate.fileCount,
              current.lastChangedAt == candidate.lastChangedAt else {
            throw BrowserPrivacyCleanupError.changedSinceReview
        }

        try trashOperation(url)
        return BrowserCacheMoveResult(path: url.path, sizeBytes: candidate.sizeBytes)
    }

    private struct Target {
        let url: URL
        let browser: LocalBrowser
        let title: String
    }

    private struct Inspection {
        let sizeBytes: Int64
        let fileCount: Int
        let lastChangedAt: Date?
        let fingerprint: String
        let entriesChecked: Int
        let unreadableLocations: Int
        let wasLimited: Bool
        let wasCancelled: Bool
        let isComplete: Bool
    }

    private struct FileMetadata {
        enum Kind: UInt8 {
            case directory = 1
            case regularFile = 2
            case symbolicLink = 3
            case other = 4
        }

        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedAt: Date
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let kind: Kind
    }

    private var isSafeHome: Bool {
        return metadata(at: homeURL)?.kind == .directory
    }

    private func discoverTargets(skippedLocations: inout Int) -> [Target] {
        var targets: [Target] = []
        let safariCaches = [
            (homeURL.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true), "Safari web cache"),
            (homeURL.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Caches", isDirectory: true), "Safari app cache")
        ]
        for (url, title) in safariCaches {
            if metadata(at: url) != nil {
                if isSupportedCache(url, for: .safari) {
                    targets.append(Target(url: url, browser: .safari, title: title))
                } else {
                    skippedLocations += 1
                }
            }
        }

        let firefoxProfileRoots = [
            homeURL.appendingPathComponent("Library/Caches/Firefox/Profiles", isDirectory: true),
            homeURL.appendingPathComponent("Library/Caches/Mozilla/Firefox/Profiles", isDirectory: true)
        ]
        var profileNumber = 0
        for profilesRoot in firefoxProfileRoots {
            guard metadata(at: profilesRoot) != nil else { continue }
            guard isSafeDirectory(profilesRoot),
                  let profileURLs = try? FileManager.default.contentsOfDirectory(
                    at: profilesRoot,
                    includingPropertiesForKeys: nil,
                    options: []
                  ) else {
                skippedLocations += 1
                continue
            }
            for profileURL in profileURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isSafeDirectory(profileURL) else {
                    skippedLocations += 1
                    continue
                }
                profileNumber += 1
                for cacheName in ["cache2", "startupCache"] {
                    let cacheURL = profileURL.appendingPathComponent(cacheName, isDirectory: true)
                    guard metadata(at: cacheURL) != nil else { continue }
                    guard isSupportedCache(cacheURL, for: .firefox) else {
                        skippedLocations += 1
                        continue
                    }
                    let suffix = cacheName == "cache2" ? "web cache" : "startup cache"
                    targets.append(Target(
                        url: cacheURL,
                        browser: .firefox,
                        title: "Firefox profile \(profileNumber) · \(suffix)"
                    ))
                }
            }
        }

        let chromeProfilesRoot = homeURL.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true)
        if metadata(at: chromeProfilesRoot) != nil {
            guard isSafeDirectory(chromeProfilesRoot),
                  let profileURLs = try? FileManager.default.contentsOfDirectory(
                    at: chromeProfilesRoot,
                    includingPropertiesForKeys: nil,
                    options: []
                  ) else {
                skippedLocations += 1
                return targets
            }
            var profileNumber = 0
            for profileURL in profileURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isSafeDirectory(profileURL) else {
                    skippedLocations += 1
                    continue
                }
                profileNumber += 1
                for (cacheName, suffix) in Self.chromeCacheDirectories {
                    let cacheURL = profileURL.appendingPathComponent(cacheName, isDirectory: true)
                    guard metadata(at: cacheURL) != nil else { continue }
                    guard isSupportedCache(cacheURL, for: .chrome) else {
                        skippedLocations += 1
                        continue
                    }
                    targets.append(Target(
                        url: cacheURL,
                        browser: .chrome,
                        title: "Chrome profile \(profileNumber) · \(suffix)"
                    ))
                }
            }
        }
        return targets
    }

    private func isSupportedCache(_ url: URL, for browser: LocalBrowser) -> Bool {
        let path = url.standardizedFileURL.path
        guard SafeFilePolicy.isInside(path, root: homeURL.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: path, root: homeURL.path) else { return false }

        switch browser {
        case .safari:
            let allowed = [
                homeURL.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true).standardizedFileURL.path,
                homeURL.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Caches", isDirectory: true).standardizedFileURL.path
            ]
            return allowed.contains(path)
        case .firefox:
            let roots = [
                homeURL.appendingPathComponent("Library/Caches/Firefox/Profiles", isDirectory: true).standardizedFileURL.path,
                homeURL.appendingPathComponent("Library/Caches/Mozilla/Firefox/Profiles", isDirectory: true).standardizedFileURL.path
            ]
            return roots.contains { root in
                let relative = String(path.dropFirst(root.count + 1))
                let components = relative.split(separator: "/")
                return path.hasPrefix(root + "/")
                    && components.count == 2
                    && !components[0].isEmpty
                    && ["cache2", "startupCache"].contains(String(components[1]))
            }
        case .chrome:
            let root = homeURL.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true).standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { return false }
            let relative = String(path.dropFirst(root.count + 1))
            let components = relative.split(separator: "/")
            return components.count == 2
                && !components[0].isEmpty
                && Self.chromeCacheDirectories.contains { $0.0 == String(components[1]) }
        }
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard SafeFilePolicy.isInside(url.standardizedFileURL.path, root: homeURL.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: url.standardizedFileURL.path, root: homeURL.path),
              let file = metadata(at: url) else { return false }
        return file.kind == .directory
    }

    private func inspect(
        _ root: URL,
        browser: LocalBrowser,
        maximumEntries: Int,
        isCancelled: @Sendable () -> Bool,
        progress: @Sendable (Int) -> Void
    ) -> Inspection? {
        guard isSupportedCache(root, for: browser),
              let rootInfo = metadata(at: root), rootInfo.kind == .directory else { return nil }

        var pending = [root]
        var entries: [String] = []
        var sizeBytes: Int64 = 0
        var fileCount = 0
        var latestDate: Date?
        var entriesChecked = 0
        var unreadable = 0
        var wasLimited = false
        var wasCancelled = false

        while let url = pending.popLast() {
            if isCancelled() {
                wasCancelled = true
                break
            }
            guard entriesChecked < maximumEntries else {
                wasLimited = true
                break
            }
            entriesChecked += 1
            progress(entriesChecked)

            guard let info = metadata(at: url) else {
                unreadable += 1
                continue
            }
            latestDate = max(latestDate ?? info.modifiedAt, info.modifiedAt)
            let normalizedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            let normalizedEntryPath = canonicalEntryPath(url, kind: info.kind)
            guard normalizedEntryPath == normalizedRootPath
                    || SafeFilePolicy.isInside(normalizedEntryPath, root: normalizedRootPath) else {
                unreadable += 1
                continue
            }
            let relativePath = normalizedEntryPath == normalizedRootPath
                ? "."
                : String(normalizedEntryPath.dropFirst(normalizedRootPath.count + 1))
            entries.append("\(relativePath)|\(info.device)|\(info.inode)|\(info.size)|\(info.modifiedSeconds)|\(info.modifiedNanoseconds)|\(info.kind.rawValue)")

            switch info.kind {
            case .directory:
                do {
                    let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                    pending.append(contentsOf: children.sorted { $0.lastPathComponent > $1.lastPathComponent })
                } catch {
                    unreadable += 1
                }
            case .regularFile:
                let (sum, overflow) = sizeBytes.addingReportingOverflow(info.size)
                sizeBytes = overflow ? Int64.max : sum
                fileCount += 1
            case .symbolicLink, .other:
                break
            }
        }

        let fingerprint = SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Inspection(
            sizeBytes: sizeBytes,
            fileCount: fileCount,
            lastChangedAt: latestDate,
            fingerprint: fingerprint,
            entriesChecked: entriesChecked,
            unreadableLocations: unreadable,
            wasLimited: wasLimited,
            wasCancelled: wasCancelled,
            isComplete: !wasLimited && unreadable == 0 && !wasCancelled
        )
    }

    private func metadata(at url: URL) -> FileMetadata? {
        var info = Darwin.stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else { return nil }
        let type = info.st_mode & mode_t(S_IFMT)
        let kind: FileMetadata.Kind
        switch type {
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFREG): kind = .regularFile
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        let modified = info.st_mtimespec
        let seconds = Int64(modified.tv_sec)
        let nanoseconds = Int64(modified.tv_nsec)
        return FileMetadata(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: max(0, Int64(info.st_size)),
            modifiedAt: Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000),
            modifiedSeconds: seconds,
            modifiedNanoseconds: nanoseconds,
            kind: kind
        )
    }

    private func canonicalEntryPath(_ url: URL, kind: FileMetadata.Kind) -> String {
        if kind == .symbolicLink {
            return url.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent, isDirectory: false)
                .standardizedFileURL
                .path
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
