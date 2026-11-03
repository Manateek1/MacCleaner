import Darwin
import Foundation

struct XcodeArchiveRecord: Identifiable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int64
    let fileCount: Int
    let modifiedAt: Date
    let checkedEntries: Int
    let skippedEntries: Int
    let isComplete: Bool
    let removalPlan: XcodeArchiveRemovalPlan?

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    var canMoveToTrash: Bool { isComplete && removalPlan != nil }
}

enum XcodeArchiveNodeKind: Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other
}

struct XcodeArchiveNodeSnapshot: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedAt: TimeInterval
    let linkCount: UInt32
    let kind: XcodeArchiveNodeKind
}

struct XcodeArchiveRemovalPlan: Equatable, Sendable {
    let parentSnapshot: XcodeArchiveNodeSnapshot
    let entries: [XcodeArchiveNodeSnapshot]
}

struct XcodeArchiveProgress: Sendable {
    let archiveName: String
    let entriesChecked: Int
}

struct XcodeArchiveInventory: Sendable {
    let archives: [XcodeArchiveRecord]
    let isAvailable: Bool
    let message: String?
    let entriesChecked: Int
    let skippedLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool

    static let empty = XcodeArchiveInventory(
        archives: [],
        isAvailable: false,
        message: nil,
        entriesChecked: 0,
        skippedLocations: 0,
        wasLimited: false,
        wasCancelled: false
    )
}

/// Reads archive metadata and prepares a revalidation snapshot only for complete,
/// ordinary archives that contain no links or shared files.
struct XcodeArchiveInventoryService: Sendable {
    private let archiveRootURL: URL
    private let securityAnchorURL: URL
    private let maximumEntries: Int
    private let maximumRemovalSnapshotEntries: Int

    init(homeURL: URL = SafeFilePolicy.accountHome, maximumEntries: Int = 500_000, maximumRemovalSnapshotEntries: Int = 50_000) {
        let home = homeURL.standardizedFileURL
        self.init(
            archiveRootURL: home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true),
            securityAnchorURL: home,
            maximumEntries: maximumEntries,
            maximumRemovalSnapshotEntries: maximumRemovalSnapshotEntries
        )
    }

    init(archiveRootURL: URL, maximumEntries: Int = 500_000, maximumRemovalSnapshotEntries: Int = 50_000) {
        self.init(
            archiveRootURL: archiveRootURL.standardizedFileURL,
            securityAnchorURL: archiveRootURL.standardizedFileURL,
            maximumEntries: maximumEntries,
            maximumRemovalSnapshotEntries: maximumRemovalSnapshotEntries
        )
    }

    private init(archiveRootURL: URL, securityAnchorURL: URL, maximumEntries: Int, maximumRemovalSnapshotEntries: Int) {
        self.archiveRootURL = archiveRootURL.standardizedFileURL
        self.securityAnchorURL = securityAnchorURL.standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.maximumRemovalSnapshotEntries = max(1, maximumRemovalSnapshotEntries)
    }

    func scan(
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (XcodeArchiveProgress) -> Void = { _ in }
    ) -> XcodeArchiveInventory {
        switch checkPath(from: securityAnchorURL, to: archiveRootURL) {
        case .symbolicLink:
            return unavailable("The standard Xcode Archives folder includes a symbolic link, so Mac Cleaner did not open it.", skipped: 1)
        case .unavailable:
            return unavailable("The Xcode Archives folder could not be read with Mac Cleaner’s current permissions.", skipped: 1)
        case .safe:
            break
        }

        guard let rootKind = nodeKind(at: archiveRootURL) else {
            if errno == ENOENT {
                return XcodeArchiveInventory(
                    archives: [], isAvailable: true,
                    message: "No local Xcode Archives folder was found.",
                    entriesChecked: 0, skippedLocations: 0, wasLimited: false, wasCancelled: false
                )
            }
            return unavailable("The Xcode Archives folder could not be read with Mac Cleaner’s current permissions.", skipped: 1)
        }
        guard rootKind == .directory else {
            return unavailable("The Xcode Archives location is not a regular folder.", skipped: 1)
        }

        let fileManager = FileManager.default
        guard let firstLevel = try? fileManager.contentsOfDirectory(
            at: archiveRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return unavailable("The Xcode Archives folder is present but could not be listed.", skipped: 1)
        }

        var candidates: [URL] = []
        var skipped = 0
        var entriesChecked = 0
        var wasLimited = false
        var wasCancelled = false

        // Xcode stores archives directly or one level down in date-named folders.
        for firstLevelURL in firstLevel {
            guard !isCancelled() else { wasCancelled = true; break }
            guard entriesChecked < maximumEntries else { wasLimited = true; break }
            entriesChecked += 1
            guard let kind = nodeKind(at: firstLevelURL), kind != .symbolicLink else {
                skipped += 1
                continue
            }
            if firstLevelURL.pathExtension.lowercased() == "xcarchive" {
                if kind == .directory { candidates.append(firstLevelURL) }
                continue
            }
            guard kind == .directory else { continue }
            guard let secondLevel = try? fileManager.contentsOfDirectory(
                    at: firstLevelURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                  ) else {
                skipped += 1
                continue
            }

            for candidate in secondLevel {
                guard !isCancelled() else { wasCancelled = true; break }
                guard entriesChecked < maximumEntries else { wasLimited = true; break }
                entriesChecked += 1
                guard candidate.pathExtension.lowercased() == "xcarchive" else { continue }
                guard nodeKind(at: candidate) == .directory else {
                    skipped += 1
                    continue
                }
                candidates.append(candidate)
            }
            if wasCancelled || wasLimited { break }
        }

        var archives: [XcodeArchiveRecord] = []
        for candidate in candidates {
            guard !isCancelled() else { wasCancelled = true; break }
            guard entriesChecked < maximumEntries else { wasLimited = true; break }
            let remaining = maximumEntries - entriesChecked
            let entriesBeforeArchive = entriesChecked
            let archiveName = candidate.deletingPathExtension().lastPathComponent
            let inspection = inspect(
                candidate,
                maximumEntries: remaining,
                isCancelled: isCancelled,
                progress: { update in
                    progress(XcodeArchiveProgress(
                        archiveName: archiveName,
                        entriesChecked: entriesBeforeArchive + update.entriesChecked
                    ))
                }
            )
            entriesChecked += inspection.entriesChecked
            skipped += inspection.skippedEntries
            wasLimited = wasLimited || inspection.wasLimited
            wasCancelled = wasCancelled || inspection.wasCancelled
            archives.append(XcodeArchiveRecord(
                path: candidate.path,
                sizeBytes: inspection.sizeBytes,
                fileCount: inspection.fileCount,
                modifiedAt: inspection.modifiedAt,
                checkedEntries: inspection.entriesChecked,
                skippedEntries: inspection.skippedEntries,
                isComplete: inspection.isComplete,
                removalPlan: inspection.isComplete ? inspection.removalPlan : nil
            ))
            if wasCancelled || wasLimited { break }
        }

        return XcodeArchiveInventory(
            archives: archives.sorted {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            isAvailable: true,
            message: archives.isEmpty && !wasCancelled && !wasLimited
                ? "No Xcode archives were found in the standard local Archives folder."
                : nil,
            entriesChecked: entriesChecked,
            skippedLocations: skipped,
            wasLimited: wasLimited,
            wasCancelled: wasCancelled
        )
    }

    private func inspect(
        _ archive: URL,
        maximumEntries: Int,
        isCancelled: @Sendable () -> Bool,
        progress: @Sendable (XcodeArchiveProgress) -> Void
    ) -> Inspection {
        guard checkPath(from: securityAnchorURL, to: archive) == .safe,
              nodeKind(at: archive) == .directory else {
            return Inspection(sizeBytes: 0, fileCount: 0, modifiedAt: date(at: archive), entriesChecked: 0, skippedEntries: 1, isComplete: false, wasLimited: false, wasCancelled: false, removalPlan: nil)
        }

        var sizeBytes: Int64 = 0
        var fileCount = 0
        var entriesChecked = 0
        var skippedEntries = 0
        var wasLimited = false
        var wasCancelled = false
        var canBuildRemovalPlan = true
        var removalSnapshots: [XcodeArchiveNodeSnapshot] = []
        let archiveDate = date(at: archive)
        if let rootSnapshot = nodeSnapshot(at: archive), rootSnapshot.kind == .directory {
            removalSnapshots.append(rootSnapshot)
        } else {
            canBuildRemovalPlan = false
        }
        let parentSnapshot = nodeSnapshot(at: archive.deletingLastPathComponent())
        if parentSnapshot?.kind != .directory { canBuildRemovalPlan = false }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: archive,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                skippedEntries += 1
                return true
            }
        )

        guard let enumerator else {
            return Inspection(sizeBytes: 0, fileCount: 0, modifiedAt: archiveDate, entriesChecked: 0, skippedEntries: 1, isComplete: false, wasLimited: false, wasCancelled: false, removalPlan: nil)
        }

        while let item = enumerator.nextObject() as? URL {
            if isCancelled() { wasCancelled = true; break }
            guard entriesChecked < maximumEntries else { wasLimited = true; break }
            entriesChecked += 1
            guard let snapshot = nodeSnapshot(at: item) else {
                skippedEntries += 1
                canBuildRemovalPlan = false
                continue
            }
            if snapshot.kind == .symbolicLink || snapshot.kind == .other {
                canBuildRemovalPlan = false
            } else if snapshot.kind == .regularFile && snapshot.linkCount != 1 {
                canBuildRemovalPlan = false
            }
            if canBuildRemovalPlan {
                if removalSnapshots.count < maximumRemovalSnapshotEntries {
                    removalSnapshots.append(snapshot)
                } else {
                    canBuildRemovalPlan = false
                    removalSnapshots.removeAll(keepingCapacity: false)
                }
            }
            do {
                let values = try item.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    skippedEntries += 1
                } else if values.isRegularFile == true {
                    fileCount += 1
                    sizeBytes = Self.saturatingAdd(sizeBytes, Int64(max(0, values.fileSize ?? 0)))
                } else if values.isDirectory != true {
                    skippedEntries += 1
                }
            } catch {
                skippedEntries += 1
            }
            if entriesChecked.isMultiple(of: 500) {
                progress(XcodeArchiveProgress(archiveName: archive.lastPathComponent, entriesChecked: entriesChecked))
            }
        }

        let removalPlan: XcodeArchiveRemovalPlan?
        if canBuildRemovalPlan,
           !wasLimited,
           !wasCancelled,
           skippedEntries == 0,
           let parentSnapshot {
            removalPlan = XcodeArchiveRemovalPlan(
                parentSnapshot: parentSnapshot,
                entries: removalSnapshots.sorted { $0.path < $1.path }
            )
        } else {
            removalPlan = nil
        }
        return Inspection(
            sizeBytes: sizeBytes,
            fileCount: fileCount,
            modifiedAt: archiveDate,
            entriesChecked: entriesChecked,
            skippedEntries: skippedEntries,
            isComplete: !wasLimited && !wasCancelled && skippedEntries == 0,
            wasLimited: wasLimited,
            wasCancelled: wasCancelled,
            removalPlan: removalPlan
        )
    }

    private func unavailable(_ message: String, skipped: Int) -> XcodeArchiveInventory {
        XcodeArchiveInventory(
            archives: [], isAvailable: false, message: message,
            entriesChecked: 0, skippedLocations: skipped, wasLimited: false, wasCancelled: false
        )
    }

    private func checkPath(from anchor: URL, to target: URL) -> PathCheck {
        let anchorPath = anchor.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == anchorPath || SafeFilePolicy.isInside(targetPath, root: anchorPath) else { return .unavailable }
        guard let anchorKind = nodeKind(at: anchor) else {
            return errno == ENOENT ? .safe : .unavailable
        }
        guard anchorKind != .symbolicLink else { return .symbolicLink }
        if targetPath != anchorPath, anchorKind != .directory { return .unavailable }
        if targetPath == anchorPath { return .safe }

        let relativePath = String(targetPath.dropFirst(anchorPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var current = anchor
        let components = relativePath.split(separator: "/")
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            guard let kind = nodeKind(at: current) else { return errno == ENOENT ? .safe : .unavailable }
            guard kind != .symbolicLink else { return .symbolicLink }
            if index < components.count - 1 && kind != .directory { return .unavailable }
        }
        return .safe
    }

    private func nodeKind(at url: URL) -> NodeKind? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return nil }
        let fileType = info.st_mode & S_IFMT
        if fileType == S_IFDIR { return .directory }
        if fileType == S_IFREG { return .file }
        if fileType == S_IFLNK { return .symbolicLink }
        return .other
    }

    private func nodeSnapshot(at url: URL) -> XcodeArchiveNodeSnapshot? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return nil }
        let rawType = info.st_mode & S_IFMT
        let kind: XcodeArchiveNodeKind
        if rawType == S_IFDIR { kind = .directory }
        else if rawType == S_IFREG { kind = .regularFile }
        else if rawType == S_IFLNK { kind = .symbolicLink }
        else { kind = .other }
        return XcodeArchiveNodeSnapshot(
            path: url.standardizedFileURL.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: max(0, Int64(info.st_size)),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            linkCount: UInt32(info.st_nlink),
            kind: kind
        )
    }

    private func date(at url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private enum NodeKind: Equatable {
        case directory, file, symbolicLink, other
    }

    private enum PathCheck: Equatable {
        case safe, symbolicLink, unavailable
    }

    private struct Inspection {
        let sizeBytes: Int64
        let fileCount: Int
        let modifiedAt: Date
        let entriesChecked: Int
        let skippedEntries: Int
        let isComplete: Bool
        let wasLimited: Bool
        let wasCancelled: Bool
        let removalPlan: XcodeArchiveRemovalPlan?
    }
}

struct XcodeArchiveRemovalFailure: Equatable, Sendable {
    let path: String
    let reason: String
}

struct XcodeArchiveRemovalResult: Sendable {
    let movedPaths: [String]
    let failures: [XcodeArchiveRemovalFailure]
    let bytesMoved: Int64
}

struct XcodeArchiveRemovalService: Sendable {
    private let homeURL: URL
    private let maximumEntries: Int
    private let trashOperation: @Sendable (URL) throws -> Void

    init(
        homeURL: URL = SafeFilePolicy.accountHome,
        maximumEntries: Int = 50_000,
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.homeURL = homeURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.trashOperation = trashOperation
    }

    func moveToTrash(_ archives: [XcodeArchiveRecord]) -> XcodeArchiveRemovalResult {
        let uniqueArchives = Dictionary(grouping: archives, by: \.path)
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
        var movedPaths: [String] = []
        var failures: [XcodeArchiveRemovalFailure] = []
        var bytesMoved: Int64 = 0

        for archive in uniqueArchives {
            guard archive.isComplete, let plan = archive.removalPlan, !plan.entries.isEmpty else {
                failures.append(failure(archive, "This archive was not fully checked, so it was left in place."))
                continue
            }
            guard isApprovedArchivePath(archive.path),
                  let parentSnapshot = Self.snapshot(at: URL(fileURLWithPath: archive.path).deletingLastPathComponent()),
                  Self.sameDirectoryIdentity(parentSnapshot, plan.parentSnapshot) else {
                failures.append(failure(archive, "The archive location changed or is outside the standard Xcode Archives folder."))
                continue
            }

            do {
                let currentEntries = try snapshotTree(at: URL(fileURLWithPath: archive.path))
                guard currentEntries == plan.entries else {
                    failures.append(failure(archive, "This archive changed after the scan. Refresh and review it again."))
                    continue
                }
            } catch let error as RemovalError {
                failures.append(failure(archive, error.localizedDescription))
                continue
            } catch {
                failures.append(failure(archive, "The archive could not be rechecked safely, so it was left in place."))
                continue
            }

            do {
                try trashOperation(URL(fileURLWithPath: archive.path))
                movedPaths.append(archive.path)
                bytesMoved = Self.saturatingAdd(bytesMoved, archive.sizeBytes)
            } catch {
                failures.append(failure(archive, "macOS could not move this archive to Trash."))
            }
        }

        return XcodeArchiveRemovalResult(movedPaths: movedPaths, failures: failures, bytesMoved: bytesMoved)
    }

    private func isApprovedArchivePath(_ path: String) -> Bool {
        let archiveRoot = homeURL.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true).standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard candidate.pathExtension.lowercased() == "xcarchive",
              SafeFilePolicy.isInside(candidate.path, root: archiveRoot.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: archiveRoot.path, root: homeURL.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: candidate.path, root: homeURL.path),
              !SafeFilePolicy.isEssentialSystemLocation(candidate.path),
              !SafeFilePolicy.isInsideDevelopmentRepository(candidate.path, homeDirectory: homeURL) else { return false }

        let relativePath = String(candidate.path.dropFirst(archiveRoot.path.count + 1))
        let components = relativePath.split(separator: "/")
        guard components.count == 1 || components.count == 2 else { return false }
        return components.last?.lowercased().hasSuffix(".xcarchive") == true
    }

    private func snapshotTree(at root: URL) throws -> [XcodeArchiveNodeSnapshot] {
        guard isApprovedArchivePath(root.path),
              let rootSnapshot = Self.snapshot(at: root), rootSnapshot.kind == .directory else {
            throw RemovalError.protectedLocation
        }
        var directories = [root]
        var entries = [rootSnapshot]
        var visited = 0

        while let directory = directories.popLast() {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            } catch {
                throw RemovalError.inaccessible
            }
            for child in children {
                visited += 1
                guard visited <= maximumEntries else { throw RemovalError.tooLargeToCheck }
                guard SafeFilePolicy.isInside(child.standardizedFileURL.path, root: root.path),
                      let snapshot = Self.snapshot(at: child) else { throw RemovalError.changed }
                switch snapshot.kind {
                case .directory:
                    directories.append(child)
                case .regularFile:
                    guard snapshot.linkCount == 1 else { throw RemovalError.sharedFile }
                case .symbolicLink:
                    throw RemovalError.unsafeSymbolicLink
                case .other:
                    throw RemovalError.unsupportedFileType
                }
                entries.append(snapshot)
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func failure(_ archive: XcodeArchiveRecord, _ reason: String) -> XcodeArchiveRemovalFailure {
        XcodeArchiveRemovalFailure(path: archive.path, reason: reason)
    }

    private static func snapshot(at url: URL) -> XcodeArchiveNodeSnapshot? {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        let rawType = info.st_mode & S_IFMT
        let kind: XcodeArchiveNodeKind
        if rawType == S_IFDIR { kind = .directory }
        else if rawType == S_IFREG { kind = .regularFile }
        else if rawType == S_IFLNK { kind = .symbolicLink }
        else { kind = .other }
        return XcodeArchiveNodeSnapshot(
            path: url.standardizedFileURL.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: max(0, Int64(info.st_size)),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            linkCount: UInt32(info.st_nlink),
            kind: kind
        )
    }

    private static func sameDirectoryIdentity(_ lhs: XcodeArchiveNodeSnapshot, _ rhs: XcodeArchiveNodeSnapshot) -> Bool {
        lhs.path == rhs.path
            && lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.kind == .directory
            && rhs.kind == .directory
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private enum RemovalError: Error, LocalizedError {
        case protectedLocation
        case changed
        case inaccessible
        case tooLargeToCheck
        case sharedFile
        case unsafeSymbolicLink
        case unsupportedFileType

        var errorDescription: String? {
            switch self {
            case .protectedLocation:
                "Only complete archives in the standard Xcode Archives folder can be moved."
            case .changed:
                "This archive changed after the scan. Refresh and review it again."
            case .inaccessible:
                "Some archive contents could not be checked; the archive was left in place."
            case .tooLargeToCheck:
                "This archive exceeds the safety limit and was left in place."
            case .sharedFile:
                "This archive contains a shared file and was left in place."
            case .unsafeSymbolicLink:
                "This archive contains a symbolic link and was left in place."
            case .unsupportedFileType:
                "This archive contains an unsupported item and was left in place."
            }
        }
    }
}
