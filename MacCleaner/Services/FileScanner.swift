import CryptoKit
import Darwin
import Foundation
import OSLog

enum DirectoryOpenResult {
    case opened(Int32)
    case failed(Int32)
    case timedOut
    case busy
}

final class TimedDirectoryOpener: @unchecked Sendable {
    private let slots: DispatchSemaphore
    private let openDescriptor: @Sendable (String) -> Int32

    init(maxConcurrentOpens: Int = 4, openDescriptor: @escaping @Sendable (String) -> Int32 = { path in
        SafeFileAccess.openDirectoryDescriptor(path)
    }) {
        slots = DispatchSemaphore(value: max(1, maxConcurrentOpens))
        self.openDescriptor = openDescriptor
    }

    func open(_ path: String, timeout: TimeInterval = 5) -> DirectoryOpenResult {
        guard slots.wait(timeout: .now()) == .success else { return .busy }

        let state = DirectoryOpenState()
        let queue = DispatchQueue.global(qos: Self.currentQoSClass())
        queue.async { [slots, openDescriptor] in
            defer { slots.signal() }
            let descriptor = openDescriptor(path)
            state.complete(descriptor: descriptor, error: errno)
        }
        return state.wait(timeout: timeout)
    }

    private static func currentQoSClass() -> DispatchQoS.QoSClass {
        var qosClass = QOS_CLASS_UNSPECIFIED
        var relativePriority: Int32 = 0
        guard pthread_get_qos_class_np(pthread_self(), &qosClass, &relativePriority) == 0 else { return .utility }

        switch qosClass {
        case QOS_CLASS_USER_INTERACTIVE: return DispatchQoS.QoSClass.userInteractive
        case QOS_CLASS_USER_INITIATED: return DispatchQoS.QoSClass.userInitiated
        case QOS_CLASS_DEFAULT: return DispatchQoS.QoSClass.default
        case QOS_CLASS_UTILITY: return DispatchQoS.QoSClass.utility
        case QOS_CLASS_BACKGROUND: return DispatchQoS.QoSClass.background
        default: return DispatchQoS.QoSClass.utility
        }
    }
}

struct ScanDirectoryOpeners: Sendable {
    enum Scope: Sendable {
        case local
        case iCloudDesktop
    }

    private let local: TimedDirectoryOpener
    private let iCloudDesktop: TimedDirectoryOpener

    static let shared = ScanDirectoryOpeners(
        local: FileScanner.directoryOpener,
        iCloudDesktop: FileScanner.iCloudDesktopDirectoryOpener
    )

    init(
        local: TimedDirectoryOpener = TimedDirectoryOpener(),
        iCloudDesktop: TimedDirectoryOpener = TimedDirectoryOpener(maxConcurrentOpens: 1)
    ) {
        self.local = local
        self.iCloudDesktop = iCloudDesktop
    }

    func open(_ path: String, scope: Scope, timeout: TimeInterval = 5) -> DirectoryOpenResult {
        switch scope {
        case .local:
            local.open(path, timeout: timeout)
        case .iCloudDesktop:
            iCloudDesktop.open(path, timeout: timeout)
        }
    }
}

private final class DirectoryOpenState: @unchecked Sendable {
    private enum State {
        case waiting
        case opened(Int32)
        case failed(Int32)
        case timedOut
    }

    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var state = State.waiting

    func complete(descriptor: Int32, error: Int32) {
        lock.lock()
        if case .timedOut = state {
            lock.unlock()
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            return
        }

        state = descriptor >= 0 ? .opened(descriptor) : .failed(error)
        lock.unlock()
        completed.signal()
    }

    func wait(timeout: TimeInterval) -> DirectoryOpenResult {
        _ = completed.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .waiting:
            state = .timedOut
            return .timedOut
        case .opened(let descriptor):
            return .opened(descriptor)
        case .failed(let error):
            return .failed(error)
        case .timedOut:
            return .timedOut
        }
    }
}

protocol ScanServicing: Sendable {
    func scan(
        _ request: ScanRequest,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResult
}

struct FileScanner: ScanServicing {
    private static let coverageLogger = Logger(subsystem: "com.manateek1.MacCleaner", category: "ScanCoverage")
    private let accountHome: URL
    private let maximumEntries: Int
    private let directoryOpeners: ScanDirectoryOpeners
    private let externalVolumeProvider: @Sendable (URL) -> [URL]
    static let directoryOpener = TimedDirectoryOpener()
    static let iCloudDesktopDirectoryOpener = TimedDirectoryOpener(maxConcurrentOpens: 1)

    init(
        accountHome: URL = SafeFilePolicy.accountHome,
        maximumEntries: Int = 1_000_000,
        directoryOpeners: ScanDirectoryOpeners = .shared,
        externalVolumeProvider: @escaping @Sendable (URL) -> [URL] = { root in
            FileScanner.discoverExternalVolumeRoots(root)
        }
    ) {
        self.accountHome = accountHome.standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.directoryOpeners = directoryOpeners
        self.externalVolumeProvider = externalVolumeProvider
    }

    func scan(
        _ request: ScanRequest,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResult {
        progress(ScanProgress(stage: "Preparing scan", filesVisited: 0, bytesVisited: 0, entriesVisited: 0))
        let externalVolumeProvider = self.externalVolumeProvider
        let operation = Task.detached(priority: .utility) {
            try Self.scanSynchronously(
                request,
                accountHome: accountHome,
                maximumEntries: maximumEntries,
                directoryOpeners: directoryOpeners,
                externalVolumeProvider: externalVolumeProvider,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private struct FileRecord: Sendable {
        let path: String
        let identity: FileIdentity
        let lastAccessedAt: Date?
        let isCloudManaged: Bool
    }

    private struct FileMetadata: Sendable {
        let identity: FileIdentity
        let lastAccessedAt: Date?
    }

    private struct ICloudDesktopScanResult {
        var records: [FileRecord] = []
        var bytesVisited: Int64 = 0
        var entriesVisited = 0
        var skippedItems = 0
        var skippedLocations: [String] = []
        var excludedLocations: Set<String> = []
        var cloudFilesNotLocallyAvailable = 0
        var cloudFilesLocallyAvailable = 0
        var cloudDesktopAccessUnavailable = false
        var wasTruncated = false
    }

    private static func scanSynchronously(
        _ request: ScanRequest,
        accountHome: URL,
        maximumEntries: Int,
        directoryOpeners: ScanDirectoryOpeners,
        externalVolumeProvider: @Sendable (URL) -> [URL],
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> ScanResult {
        progress(ScanProgress(stage: "Opening scan folder", filesVisited: 0, bytesVisited: 0, entriesVisited: 0))
        guard let canonicalRootPath = SafeFileAccess.canonicalDirectoryPath(request.root.standardizedFileURL.path) else {
            throw ScanError.invalidFolder
        }
        let root = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
        progress(ScanProgress(stage: "Checking scan access", filesVisited: 0, bytesVisited: 0, entriesVisited: 0))
        let excludedPaths = ScanExclusionPolicy.normalized(request.excludedPaths)
        guard isDirectory(root.path) else {
            throw ScanError.invalidFolder
        }
        guard !SafeFilePolicy.isEssentialSystemLocation(root.path) else {
            throw ScanError.protectedFolder
        }
        progress(ScanProgress(stage: "Checking repository protection", filesVisited: 0, bytesVisited: 0, entriesVisited: 0))
        guard !SafeFilePolicy.isInsideDevelopmentRepository(root.path, homeDirectory: accountHome) else {
            throw ScanError.protectedRepository
        }
        if let excluded = ScanExclusionPolicy.matchingNormalizedExclusion(for: root.path, in: excludedPaths) {
            throw ScanError.excludedFolder(excluded)
        }

        var skipped = 0
        var skippedLocations: [String] = []
        var excludedLocations: Set<String> = []
        var records: [FileRecord] = []
        var bytes: Int64 = 0
        var cloudFilesNotLocallyAvailable = 0
        var cloudFilesLocallyAvailable = 0
        var cloudDesktopAccessUnavailable = false
        var wasTruncated = false
        let diskScan = request.scanEntireDisk
        progress(ScanProgress(stage: "Preparing scan locations", filesVisited: 0, bytesVisited: 0, entriesVisited: 0))
        let cloudDesktopRoot = ICloudDesktopPolicy.shouldInspectDesktop(
            for: root,
            scanEntireDisk: diskScan,
            accountHome: accountHome
        ) ? ICloudDesktopPolicy.iCloudDesktopRoot(accountHome: accountHome) : nil
        let scanRoots: [URL]
        var otherAccountLibraryPaths: Set<String> = []
        if diskScan {
            let excluded = Set(["System", "private", "dev", "Volumes", "cores", "bin", "sbin", "usr", "Users", "Library"])
            let topLevel = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let userHomeDiscovery = Self.discoverOtherLocalAccountHomes(root: root, accountHome: accountHome)
            if let skippedUsersPath = userHomeDiscovery.skippedPath {
                skipped += 1
                skippedLocations.append(skippedUsersPath)
            }
            otherAccountLibraryPaths = Set(userHomeDiscovery.homes.map {
                $0.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
            })
            let selectedSystemCacheRoots = [
                URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
                URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
                URL(fileURLWithPath: "/Library/Developer/Xcode/DerivedData", isDirectory: true),
                URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches", isDirectory: true)
            ].filter { isDirectory($0.path) }
            let sharedFiles = root.appendingPathComponent("Users/Shared", isDirectory: true)
            let sharedScanRoots = [sharedFiles].filter { isDirectory($0.path) }
            let volumesDirectory = root.appendingPathComponent("Volumes", isDirectory: true).standardizedFileURL
            let externalScanRoots = externalVolumeProvider(root).map(\.standardizedFileURL).filter { volume in
                volume.deletingLastPathComponent().standardizedFileURL == volumesDirectory
                    && !volume.lastPathComponent.hasPrefix(".")
                    && !isSymbolicLink(volume.path)
                    && !SafeFilePolicy.containsProtectedPathComponent(volume.path)
            }.sorted { $0.path < $1.path }
            let systemScanRoots = topLevel.filter {
                !$0.lastPathComponent.hasPrefix(".") && !excluded.contains($0.lastPathComponent) && isDirectory($0.path)
            }.sorted { $0.path < $1.path }
            let localDeveloperTools = [root.appendingPathComponent("usr/local", isDirectory: true)].filter { isDirectory($0.path) }
            var discoveredScanRoots = [accountHome]
            discoveredScanRoots.append(contentsOf: userHomeDiscovery.homes)
            discoveredScanRoots.append(contentsOf: selectedSystemCacheRoots)
            discoveredScanRoots.append(contentsOf: sharedScanRoots)
            discoveredScanRoots.append(contentsOf: externalScanRoots)
            discoveredScanRoots.append(contentsOf: systemScanRoots)
            discoveredScanRoots.append(contentsOf: localDeveloperTools)
            scanRoots = discoveredScanRoots
        } else {
            scanRoots = [root]
        }

        var entriesVisited = 0
        for scanRoot in scanRoots {
            try Task.checkCancellation()
            guard isDirectory(scanRoot.path) else {
                skipped += 1
                if skippedLocations.count < 50 { skippedLocations.append(scanRoot.path) }
                continue
            }
            var pendingDirectories = [scanRoot]
            var directoriesVisited = 0
            while let directory = pendingDirectories.popLast() {
                try Task.checkCancellation()
                if let excluded = ScanExclusionPolicy.matchingNormalizedExclusion(for: directory.path, in: excludedPaths) {
                    excludedLocations.insert(excluded)
                    continue
                }
                guard SafeFilePolicy.isInside(directory.path, root: root.path) || directory.standardizedFileURL.path == root.path,
                      isDirectory(directory.path),
                      !isPackageDirectory(directory),
                      !(diskScan && otherAccountLibraryPaths.contains(directory.standardizedFileURL.path)),
                      !SafeFilePolicy.shouldSkipDirectory(directory.path, homeDirectory: accountHome) else {
                    continue
                }

                if let cloudDesktopRoot,
                   ICloudDesktopPolicy.contains(directory, inside: cloudDesktopRoot) {
                    let remainingEntries = max(0, maximumEntries - entriesVisited)
                    let cloudScan = try Self.scanICloudDesktop(
                        directory,
                        scanRoot: root,
                        accountHome: accountHome,
                        excludedPaths: excludedPaths,
                        maximumEntries: remainingEntries,
                        directoryOpeners: directoryOpeners,
                        baseFileCount: records.count,
                        baseBytes: bytes,
                        baseEntries: entriesVisited,
                        progress: progress
                    )
                    records.append(contentsOf: cloudScan.records)
                    bytes += cloudScan.bytesVisited
                    entriesVisited += cloudScan.entriesVisited
                    skipped += cloudScan.skippedItems
                    cloudFilesNotLocallyAvailable += cloudScan.cloudFilesNotLocallyAvailable
                    cloudFilesLocallyAvailable += cloudScan.cloudFilesLocallyAvailable
                    cloudDesktopAccessUnavailable = cloudDesktopAccessUnavailable || cloudScan.cloudDesktopAccessUnavailable
                    skippedLocations.append(contentsOf: cloudScan.skippedLocations.prefix(max(0, 50 - skippedLocations.count)))
                    excludedLocations.formUnion(cloudScan.excludedLocations)
                    wasTruncated = wasTruncated || cloudScan.wasTruncated
                    continue
                }

                directoriesVisited += 1
                progress(ScanProgress(
                    stage: "Checking \(directory.lastPathComponent.isEmpty ? "disk" : directory.lastPathComponent)",
                    filesVisited: records.count,
                    bytesVisited: bytes,
                    entriesVisited: entriesVisited
                ))

                let directoryHandle: UnsafeMutablePointer<DIR>?
                switch directoryOpeners.open(directory.path, scope: .local) {
                case .opened(let descriptor):
                    directoryHandle = Darwin.fdopendir(descriptor)
                    if directoryHandle == nil {
                        let error = errno
                        _ = Darwin.close(descriptor)
                        Self.logStandardFolderFailure(directory.path, accountHome: accountHome, reason: "fdopendir errno \(error)")
                    }
                case .failed(let error):
                    Self.logStandardFolderFailure(directory.path, accountHome: accountHome, reason: "open errno \(error)")
                    directoryHandle = nil
                case .timedOut:
                    Self.logStandardFolderFailure(directory.path, accountHome: accountHome, reason: "open timed out")
                    directoryHandle = nil
                case .busy:
                    Self.logStandardFolderFailure(directory.path, accountHome: accountHome, reason: "all directory-open slots were busy")
                    directoryHandle = nil
                }

                guard let directoryHandle else {
                    skipped += 1
                    if skippedLocations.count < 50 { skippedLocations.append(directory.path) }
                    if !diskScan && directory.standardizedFileURL.path == scanRoot.standardizedFileURL.path {
                        throw ScanError.cannotReadFolder
                    }
                    continue
                }
                defer { Darwin.closedir(directoryHandle) }

                var directoryReadFailed = false
                var directoryReadError: Int32 = 0
                while true {
                    try Task.checkCancellation()
                    errno = 0
                    guard let entry = Darwin.readdir(directoryHandle) else {
                        directoryReadError = errno
                        directoryReadFailed = directoryReadError != 0
                        break
                    }
                    let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                            String(cString: $0)
                        }
                    }
                    guard !name.isEmpty, name != ".", name != ".." else { continue }
                    let item = directory.appendingPathComponent(name)
                    if entriesVisited >= maximumEntries {
                        wasTruncated = true
                        break
                    }
                    entriesVisited += 1
                    if isSymbolicLink(item.path) { continue }
                    if isDirectory(item.path) {
                        if isPackageDirectory(item) || SafeFilePolicy.shouldSkipDirectory(item.path, homeDirectory: accountHome) { continue }
                        if diskScan && otherAccountLibraryPaths.contains(item.standardizedFileURL.path) { continue }
                        pendingDirectories.append(item)
                    } else {
                        guard let metadata = readRegularFileMetadata(item.path),
                              SafeFilePolicy.isInside(item.path, root: root.path),
                              !SafeFilePolicy.containsProtectedPathComponent(item.path) else { continue }
                        if records.count >= maximumEntries {
                            wasTruncated = true
                            break
                        }
                        records.append(FileRecord(path: item.path, identity: metadata.identity, lastAccessedAt: metadata.lastAccessedAt, isCloudManaged: false))
                        bytes += metadata.identity.size
                    }
                    if entriesVisited.isMultiple(of: 64) {
                        progress(ScanProgress(
                            stage: "Checking \(directory.lastPathComponent.isEmpty ? "disk" : directory.lastPathComponent)",
                            filesVisited: records.count,
                            bytesVisited: bytes,
                            entriesVisited: entriesVisited
                        ))
                    }
                }
                if directoryReadFailed {
                    Self.logStandardFolderFailure(directory.path, accountHome: accountHome, reason: "readdir errno \(directoryReadError)")
                    skipped += 1
                    if skippedLocations.count < 50 { skippedLocations.append(directory.path) }
                }
                if directoriesVisited == 1 || directoriesVisited.isMultiple(of: 16) || entriesVisited.isMultiple(of: 64) {
                    progress(ScanProgress(
                        stage: "Checking \(directory.lastPathComponent.isEmpty ? "disk" : directory.lastPathComponent)",
                        filesVisited: records.count,
                        bytesVisited: bytes,
                        entriesVisited: entriesVisited
                    ))
                }
                if wasTruncated { break }
            }
            if wasTruncated { break }
        }

        try Task.checkCancellation()
        let duplicateMap: [String: (groupID: String, count: Int, keepPath: String)]
        if request.kind == .duplicates || request.kind == .smart {
            progress(ScanProgress(stage: "Checking exact duplicates", filesVisited: records.count, bytesVisited: bytes))
            duplicateMap = try Self.exactDuplicates(
                in: records.filter { !$0.isCloudManaged },
                keepPreference: request.duplicateKeepPreference,
                baseFileCount: records.count,
                bytesVisited: bytes,
                progress: progress
            )
        } else {
            duplicateMap = [:]
        }

        let now = Date()
        let oldCutoff = now.addingTimeInterval(-Double(request.oldFileAgeDays) * 24 * 60 * 60)
        let items = records.compactMap { record -> ScanItem? in
            let url = URL(fileURLWithPath: record.path)
            let categories = categoriesFor(
                path: record.path,
                identity: record.identity,
                kind: request.kind,
                minimumSize: request.minimumFileSizeBytes,
                oldCutoff: oldCutoff,
                duplicate: duplicateMap[record.path],
                accountHome: accountHome
            )
            guard !categories.isEmpty else { return nil }
            let duplicate = duplicateMap[record.path]
            let cacheDetails = SafeFilePolicy.cacheReviewDetails(for: record.path, homeDirectory: accountHome)
            let reasons = reasonList(
                categories: categories,
                identity: record.identity,
                oldCutoff: oldCutoff,
                duplicate: duplicate,
                cacheDetails: cacheDetails
            )
            let note: String
            if SafeFilePolicy.isReadOnlyCurrentAccountLibraryItem(
                path: record.path,
                categories: categories,
                homeDirectory: accountHome
            ) {
                note = "Read-only: app Library files can contain settings or state the app needs."
            } else if SafeFilePolicy.requiresExtraConfirmation(path: record.path, categories: categories) {
                note = "Review carefully: this may be a personal file. It starts unselected."
            } else {
                note = "Candidate only: confirm the path and expected effect before moving it to Trash."
            }
            return ScanItem(
                path: url.path,
                identity: record.identity,
                lastAccessedAt: record.lastAccessedAt,
                isCloudManaged: record.isCloudManaged,
                categories: categories,
                reasons: reasons,
                safetyNote: note,
                confidence: confidence(for: categories),
                duplicateGroupID: duplicate?.groupID,
                duplicateGroupCount: duplicate?.count ?? 0,
                suggestedKeepPath: duplicate?.keepPath,
                cacheReviewDetails: cacheDetails
            )
        }

        progress(ScanProgress(stage: "Preparing space view", filesVisited: records.count, bytesVisited: bytes, entriesVisited: entriesVisited))
        let space = try makeSpaceSnapshot(records: records, root: root)
        progress(ScanProgress(stage: "Organizing findings", filesVisited: records.count, bytesVisited: bytes, entriesVisited: entriesVisited))
        let sortedItems = items.sorted { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        progress(ScanProgress(stage: "Review ready", filesVisited: records.count, bytesVisited: bytes, entriesVisited: entriesVisited))
        return ScanResult(
            kind: request.kind,
            rootPath: root.path,
            filesVisited: records.count,
            entriesVisited: entriesVisited,
            entryLimit: maximumEntries,
            bytesVisited: bytes,
            skippedItems: skipped,
            skippedLocations: skippedLocations,
            cloudFilesNotLocallyAvailable: cloudFilesNotLocallyAvailable,
            cloudFilesLocallyAvailable: cloudDesktopRoot == nil ? nil : cloudFilesLocallyAvailable,
            cloudDesktopAccessUnavailable: cloudDesktopRoot == nil ? nil : cloudDesktopAccessUnavailable,
            excludedLocations: excludedLocations.sorted(),
            items: sortedItems,
            finishedAt: now,
            wasTruncated: wasTruncated,
            space: space,
            duplicateKeepPreference: request.duplicateKeepPreference
        )
    }

    private static func scanICloudDesktop(
        _ directory: URL,
        scanRoot: URL,
        accountHome: URL,
        excludedPaths: [String],
        maximumEntries: Int,
        directoryOpeners: ScanDirectoryOpeners,
        baseFileCount: Int,
        baseBytes: Int64,
        baseEntries: Int,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> ICloudDesktopScanResult {
        var result = ICloudDesktopScanResult()
        guard maximumEntries > 0 else {
            result.wasTruncated = true
            return result
        }
        let resourceKeys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]
        let desktopRootPath = directory.standardizedFileURL.path

        var pendingDirectories = [directory]
        while let currentDirectory = pendingDirectories.popLast() {
            try Task.checkCancellation()
            let currentPath = currentDirectory.standardizedFileURL.path
            if let excluded = ScanExclusionPolicy.matchingNormalizedExclusion(for: currentPath, in: excludedPaths) {
                result.excludedLocations.insert(excluded)
                continue
            }
            guard SafeFilePolicy.isInside(currentPath, root: scanRoot.path) else { continue }
            guard isDirectory(currentPath) else {
                if currentPath == desktopRootPath {
                    result.cloudDesktopAccessUnavailable = true
                    result.skippedItems += 1
                    if result.skippedLocations.count < 50 { result.skippedLocations.append(currentPath) }
                }
                continue
            }
            guard !isPackageDirectory(currentDirectory),
                  !SafeFilePolicy.shouldSkipDirectory(currentPath, homeDirectory: accountHome) else { continue }

            if currentPath != desktopRootPath {
                guard let directoryValues = try? currentDirectory.resourceValues(forKeys: resourceKeys) else {
                    result.skippedItems += 1
                    if result.skippedLocations.count < 50 { result.skippedLocations.append(currentPath) }
                    continue
                }
                if !ICloudDesktopPolicy.isLocallyAvailable(
                    isUbiquitous: directoryValues.isUbiquitousItem,
                    downloadStatus: directoryValues.ubiquitousItemDownloadingStatus,
                    isDownloading: directoryValues.ubiquitousItemIsDownloading
                ) {
                    result.cloudFilesNotLocallyAvailable += 1
                    continue
                }
            }

            switch directoryOpeners.open(currentPath, scope: .iCloudDesktop) {
            case .opened(let descriptor):
                do {
                    guard let directoryHandle = Darwin.fdopendir(descriptor) else {
                        _ = Darwin.close(descriptor)
                        result.skippedItems += 1
                        if result.skippedLocations.count < 50 { result.skippedLocations.append(currentPath) }
                        continue
                    }
                    defer { Darwin.closedir(directoryHandle) }

                    progress(ScanProgress(
                        stage: "Checking iCloud Desktop (local files only)",
                        filesVisited: baseFileCount + result.records.count,
                        bytesVisited: baseBytes + result.bytesVisited,
                        entriesVisited: baseEntries + result.entriesVisited
                    ))

                    var directoryReadFailed = false
                    while true {
                        try Task.checkCancellation()
                        errno = 0
                        guard let entry = Darwin.readdir(directoryHandle) else {
                            directoryReadFailed = errno != 0
                            break
                        }
                        let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                                String(cString: $0)
                            }
                        }
                        guard !name.isEmpty, name != ".", name != ".." else { continue }
                        guard result.entriesVisited < maximumEntries else {
                            result.wasTruncated = true
                            break
                        }
                        result.entriesVisited += 1

                        let item = currentDirectory.appendingPathComponent(name).standardizedFileURL
                        let path = item.path
                        if let excluded = ScanExclusionPolicy.matchingNormalizedExclusion(for: path, in: excludedPaths) {
                            result.excludedLocations.insert(excluded)
                            continue
                        }
                        guard SafeFilePolicy.isInside(path, root: scanRoot.path) else { continue }

                        var info = Darwin.stat()
                        guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
                            result.skippedItems += 1
                            if result.skippedLocations.count < 50 { result.skippedLocations.append(path) }
                            continue
                        }
                        let mode = info.st_mode & mode_t(S_IFMT)
                        if mode == mode_t(S_IFLNK) { continue }
                        if mode == mode_t(S_IFDIR) {
                            guard !isPackageDirectory(item),
                                  !SafeFilePolicy.shouldSkipDirectory(path, homeDirectory: accountHome) else { continue }
                            guard let values = try? item.resourceValues(forKeys: resourceKeys) else {
                                result.skippedItems += 1
                                if result.skippedLocations.count < 50 { result.skippedLocations.append(path) }
                                continue
                            }
                            if !ICloudDesktopPolicy.isLocallyAvailable(
                                isUbiquitous: values.isUbiquitousItem,
                                downloadStatus: values.ubiquitousItemDownloadingStatus,
                                isDownloading: values.ubiquitousItemIsDownloading
                            ) {
                                result.cloudFilesNotLocallyAvailable += 1
                                continue
                            }
                            pendingDirectories.append(item)
                        } else {
                            guard mode == mode_t(S_IFREG),
                                  !SafeFilePolicy.containsProtectedPathComponent(path),
                                  let values = try? item.resourceValues(forKeys: resourceKeys) else { continue }
                            guard ICloudDesktopPolicy.isLocallyAvailable(
                                isUbiquitous: values.isUbiquitousItem,
                                downloadStatus: values.ubiquitousItemDownloadingStatus,
                                isDownloading: values.ubiquitousItemIsDownloading
                            ) else {
                                result.cloudFilesNotLocallyAvailable += 1
                                continue
                            }
                            guard let metadata = readRegularFileMetadata(path) else { continue }
                            if result.records.count >= maximumEntries {
                                result.wasTruncated = true
                                break
                            }
                            result.records.append(FileRecord(
                                path: path,
                                identity: metadata.identity,
                                lastAccessedAt: metadata.lastAccessedAt,
                                isCloudManaged: true
                            ))
                            result.cloudFilesLocallyAvailable += 1
                            result.bytesVisited += metadata.identity.size
                        }

                        if result.entriesVisited.isMultiple(of: 64) {
                            progress(ScanProgress(
                                stage: "Checking iCloud Desktop (local files only)",
                                filesVisited: baseFileCount + result.records.count,
                                bytesVisited: baseBytes + result.bytesVisited,
                                entriesVisited: baseEntries + result.entriesVisited
                            ))
                        }
                    }
                    if directoryReadFailed {
                        result.skippedItems += 1
                        if result.skippedLocations.count < 50 { result.skippedLocations.append(currentPath) }
                    }
                }

            case .failed(_), .timedOut, .busy:
                result.skippedItems += 1
                if result.skippedLocations.count < 50 { result.skippedLocations.append(currentPath) }
                if currentPath == desktopRootPath { result.cloudDesktopAccessUnavailable = true }
            }
        }
        return result
    }

    private static func logStandardFolderFailure(_ path: String, accountHome: URL, reason: String) {
        let folderName = ["Documents", "Downloads"].first { name in
            accountHome.appendingPathComponent(name, isDirectory: true).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
        }
        guard let folderName else { return }
        coverageLogger.error("Could not enumerate \(folderName, privacy: .public): \(reason, privacy: .public)")
    }

    private static func discoverOtherLocalAccountHomes(root: URL, accountHome: URL) -> (homes: [URL], skippedPath: String?) {
        let usersDirectory = root.appendingPathComponent("Users", isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: usersDirectory.path) else { return ([], nil) }
        guard isDirectory(usersDirectory.path), !isSymbolicLink(usersDirectory.path) else {
            return ([], usersDirectory.path)
        }

        do {
            let homes = try FileManager.default.contentsOfDirectory(
                at: usersDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { home in
                home.standardizedFileURL.path != accountHome.standardizedFileURL.path
                    && home.lastPathComponent != "Shared"
                    && isDirectory(home.path)
                    && !isSymbolicLink(home.path)
            }
            .sorted { $0.path < $1.path }
            return (homes, nil)
        } catch {
            return ([], usersDirectory.path)
        }
    }

    private static func makeSpaceSnapshot(records: [FileRecord], root: URL) throws -> SpaceSnapshot {
        var directBytes: [String: Int64] = [:]
        var directCounts: [String: Int] = [:]
        var directTypeBytes: [String: [SpaceFileType: Int64]] = [:]
        var directTypeCounts: [String: [SpaceFileType: Int]] = [:]
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            let fileURL = URL(fileURLWithPath: record.path)
            let folder = fileURL.deletingLastPathComponent().standardizedFileURL.path
            let fileType = SpaceFileType.classify(fileExtension: fileURL.pathExtension)
            directBytes[folder, default: 0] += record.identity.size
            directCounts[folder, default: 0] += 1
            directTypeBytes[folder, default: [:]][fileType, default: 0] += record.identity.size
            directTypeCounts[folder, default: [:]][fileType, default: 0] += 1
        }

        var folderBytes: [String: Int64] = [:]
        var fileTypeBytes: [String: [SpaceFileType: Int64]] = [:]
        var fileTypeCounts: [String: [SpaceFileType: Int]] = [:]
        let rootPath = root.standardizedFileURL.path
        for (index, entry) in directBytes.enumerated() {
            if index.isMultiple(of: 1024) { try Task.checkCancellation() }
            var folder = URL(fileURLWithPath: entry.key, isDirectory: true).standardizedFileURL
            while true {
                let path = folder.path
                guard path == rootPath || SafeFilePolicy.isInside(path, root: rootPath) else { break }
                folderBytes[path, default: 0] += entry.value
                for (type, bytes) in directTypeBytes[entry.key] ?? [:] {
                    fileTypeBytes[path, default: [:]][type, default: 0] += bytes
                }
                for (type, count) in directTypeCounts[entry.key] ?? [:] {
                    fileTypeCounts[path, default: [:]][type, default: 0] += count
                }
                if path == rootPath { break }
                let parent = folder.deletingLastPathComponent().standardizedFileURL
                if parent.path == path { break }
                folder = parent
            }
        }
        return SpaceSnapshot(
            folderBytes: folderBytes,
            directFileBytes: directBytes,
            directFileCounts: directCounts,
            fileTypeBytes: fileTypeBytes,
            fileTypeCounts: fileTypeCounts
        )
    }

    private static func categoriesFor(
        path: String,
        identity: FileIdentity,
        kind: ScanKind,
        minimumSize: Int64,
        oldCutoff: Date,
        duplicate: (groupID: String, count: Int, keepPath: String)?,
        accountHome: URL
    ) -> [FindingCategory] {
        let isLarge = identity.size >= minimumSize
        let isOld = Date(timeIntervalSince1970: identity.modifiedAt) < oldCutoff
        let isCache = SafeFilePolicy.isCacheOrLogCandidate(path, homeDirectory: accountHome)
        let isAI = SafeFilePolicy.isAIAppCacheCandidate(path)
        var result: [FindingCategory] = []

        switch kind {
        case .smart:
            if isLarge { result.append(.largeFile) }
            if isOld { result.append(.oldFile) }
            if isCache { result.append(.cacheCandidate) }
            if isAI { result.append(.aiCacheCandidate) }
            if duplicate != nil { result.append(.exactDuplicate) }
        case .largeAndOld:
            if isLarge { result.append(.largeFile) }
            if isOld { result.append(.oldFile) }
        case .duplicates:
            if duplicate != nil { result.append(.exactDuplicate) }
        case .junk:
            if isCache { result.append(.cacheCandidate) }
        case .aiClutter:
            if isAI { result.append(.aiCacheCandidate) }
        }
        return result
    }

    static func discoverExternalVolumeRoots(_ systemRoot: URL) -> [URL] {
        guard systemRoot.standardizedFileURL.path == "/" else { return [] }
        let volumesDirectory = systemRoot.appendingPathComponent("Volumes", isDirectory: true).standardizedFileURL
        let keys: [URLResourceKey] = [
            .volumeIsLocalKey,
            .volumeIsBrowsableKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey
        ]
        let rootDevice = deviceIdentifier(systemRoot.path)
        guard let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var seenDevices: Set<UInt64> = []
        return mountedVolumes.compactMap { candidate in
            let volume = candidate.standardizedFileURL
            guard volume.deletingLastPathComponent().standardizedFileURL == volumesDirectory,
                  !volume.lastPathComponent.hasPrefix("."),
                  !isSymbolicLink(volume.path),
                  !SafeFilePolicy.containsProtectedPathComponent(volume.path),
                  let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true,
                  values.volumeIsBrowsable == true,
                  values.volumeIsRemovable == true || values.volumeIsEjectable == true else { return nil }
            if let device = deviceIdentifier(volume.path) {
                if let rootDevice, device == rootDevice { return nil }
                guard seenDevices.insert(device).inserted else { return nil }
            }
            return volume
        }.sorted { $0.path < $1.path }
    }

    private static func deviceIdentifier(_ path: String) -> UInt64? {
        var info = Darwin.stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        return UInt64(info.st_dev)
    }

    private static func reasonList(
        categories: [FindingCategory],
        identity: FileIdentity,
        oldCutoff: Date,
        duplicate: (groupID: String, count: Int, keepPath: String)?,
        cacheDetails: CacheReviewDetails?
    ) -> [String] {
        var reasons: [String] = []
        if categories.contains(.largeFile) {
            reasons.append("At or above the configured size threshold (\(identity.size.formattedByteCount)).")
        }
        if categories.contains(.oldFile) {
            let date = Date(timeIntervalSince1970: identity.modifiedAt).formatted(date: .abbreviated, time: .omitted)
            reasons.append("Last modified \(date), before the selected age cutoff (\(oldCutoff.formatted(date: .abbreviated, time: .omitted))).")
        }
        if categories.contains(.cacheCandidate) {
            reasons.append(cacheDetails?.reason ?? "Located under a recognized cache or log folder. Contents can still include useful state.")
        }
        if categories.contains(.aiCacheCandidate) {
            reasons.append("Located under a recognized AI tool and cache/log path. Conversation, settings, credentials, and model folders are excluded.")
        }
        if let duplicate {
            reasons.append("Byte-for-byte match in a group of \(duplicate.count). Suggested keep: \(URL(fileURLWithPath: duplicate.keepPath).lastPathComponent).")
        }
        return reasons
    }

    private static func confidence(for categories: [FindingCategory]) -> Double {
        if categories.contains(.exactDuplicate) { return 0.85 }
        if categories.contains(.aiCacheCandidate) { return 0.75 }
        if categories.contains(.cacheCandidate) { return 0.60 }
        return 0.25
    }

    private static func exactDuplicates(
        in records: [FileRecord],
        keepPreference: DuplicateKeepPreference,
        baseFileCount: Int,
        bytesVisited: Int64,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> [String: (groupID: String, count: Int, keepPath: String)] {
        let sizeGroups = Dictionary(grouping: records.filter { $0.identity.linkCount == 1 && $0.identity.size > 0 }, by: \.identity.size)
        var result: [String: (groupID: String, count: Int, keepPath: String)] = [:]
        let candidateCount = sizeGroups.values.reduce(0) { total, group in total + (group.count > 1 ? group.count : 0) }
        var hashedCount = 0
        var fullyChecked = 0
        for candidates in sizeGroups.values where candidates.count > 1 {
            try Task.checkCancellation()
            var partialGroups: [String: [FileRecord]] = [:]
            for candidate in candidates {
                try Task.checkCancellation()
                let candidateNumber = hashedCount + 1
                let reportProgress = candidateNumber == 1 || candidateNumber.isMultiple(of: 32) || candidateNumber == candidateCount
                if reportProgress {
                    progress(ScanProgress(stage: "Checking duplicates · \(candidateNumber)/\(candidateCount)", filesVisited: baseFileCount, bytesVisited: bytesVisited))
                }
                if let fingerprint = try digest(path: candidate.path, identity: candidate.identity, partial: true),
                   currentIdentity(candidate.path) == candidate.identity {
                    partialGroups[fingerprint, default: []].append(candidate)
                }
                hashedCount += 1
                if reportProgress {
                    progress(ScanProgress(stage: "Checked duplicate candidate · \(hashedCount)/\(candidateCount)", filesVisited: baseFileCount, bytesVisited: bytesVisited))
                }
            }
            for partialMatches in partialGroups.values where partialMatches.count > 1 {
                var fullGroups: [String: [FileRecord]] = [:]
                if fullyChecked.isMultiple(of: 32) {
                    progress(ScanProgress(stage: "Verifying matching files · \(fullyChecked.formatted()) checked", filesVisited: baseFileCount, bytesVisited: bytesVisited))
                }
                for candidate in partialMatches {
                    try Task.checkCancellation()
                    if let digest = try digest(path: candidate.path, identity: candidate.identity, partial: false, onProgress: { processed in
                        progress(ScanProgress(stage: "Verifying a large match · \(processed.formattedByteCount) of \(candidate.identity.size.formattedByteCount)", filesVisited: baseFileCount, bytesVisited: bytesVisited))
                    }),
                       currentIdentity(candidate.path) == candidate.identity {
                        fullGroups[digest, default: []].append(candidate)
                    }
                    fullyChecked += 1
                    if fullyChecked.isMultiple(of: 32) {
                        progress(ScanProgress(stage: "Verifying matching files · \(fullyChecked.formatted()) checked", filesVisited: baseFileCount, bytesVisited: bytesVisited))
                    }
                }
                for (hash, matches) in fullGroups where matches.count > 1 {
                    let ordered = matches.sorted(by: { lhs, rhs in
                        keepPreference.ranksBefore(
                            lhs.identity.modifiedAt,
                            path: lhs.path,
                            rhs.identity.modifiedAt,
                            path: rhs.path
                        )
                    })
                    let keepPath = ordered[0].path
                    for match in matches {
                        result[match.path] = (hash, matches.count, keepPath)
                    }
                }
            }
        }
        return result
    }

    private static func digest(path: String, identity expected: FileIdentity, partial: Bool, onProgress: ((Int64) -> Void)? = nil) throws -> String? {
        guard let descriptor = SafeFileAccess.openRegularFileDescriptor(path) else { return nil }
        var openedInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              SafeFileAccess.identity(from: openedInfo) == expected else {
            Darwin.close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            let size = expected.size
            let sampleSize = 64 * 1024
            if partial {
                var payload = try autoreleasepool {
                    try handle.read(upToCount: sampleSize) ?? Data()
                }
                if size > Int64(sampleSize * 2) {
                    try handle.seek(toOffset: UInt64(size - Int64(sampleSize)))
                    let tail = try autoreleasepool {
                        try handle.read(upToCount: sampleSize) ?? Data()
                    }
                    payload.append(tail)
                }
                return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            }

            var hasher = SHA256()
            var processed: Int64 = 0
            var nextUpdate: Int64 = 128 * 1024 * 1024
            while true {
                try Task.checkCancellation()
                let chunk = try autoreleasepool {
                    try handle.read(upToCount: 1_048_576) ?? Data()
                }
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                processed += Int64(chunk.count)
                if processed >= nextUpdate {
                    onProgress?(processed)
                    nextUpdate = processed + 128 * 1024 * 1024
                }
            }
            guard currentIdentity(path) == expected else { return nil }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func currentIdentity(_ path: String) -> FileIdentity? {
        SafeFileAccess.identity(at: path)
    }

    private static func readRegularFileMetadata(_ path: String) -> FileMetadata? {
        guard let descriptor = SafeFileAccess.openRegularFileDescriptor(path) else { return nil }
        defer { Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { return nil }
        let accessTime = TimeInterval(info.st_atimespec.tv_sec) + TimeInterval(info.st_atimespec.tv_nsec) / 1_000_000_000
        return FileMetadata(
            identity: SafeFileAccess.identity(from: info),
            lastAccessedAt: accessTime > 0 ? Date(timeIntervalSince1970: accessTime) : nil
        )
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = Darwin.stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        return result == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var info = Darwin.stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        return result == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static func isPackageDirectory(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "app" { return true }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}

enum ScanError: LocalizedError, Equatable {
    case invalidFolder
    case cannotReadFolder
    case protectedFolder
    case protectedRepository
    case excludedFolder(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose a folder that still exists and can be read."
        case .cannotReadFolder: "Mac Cleaner could not enumerate that folder. Check its permissions and try again."
        case .protectedFolder: "This is an essential macOS location. Choose a user folder or an external volume instead."
        case .protectedRepository: "This folder is inside a Git, Mercurial, or Subversion repository. Project files are protected from cleanup."
        case .excludedFolder(let path): "This folder is excluded in Settings: \(path). Remove that exclusion before scanning it."
        }
    }
}
