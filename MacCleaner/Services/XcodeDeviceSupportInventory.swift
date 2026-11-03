import Darwin
import Foundation

struct XcodeDeviceSupportFolder: Identifiable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int64
    let fileCount: Int
    let modifiedAt: Date
    let checkedEntries: Int
    let skippedEntries: Int
    let isComplete: Bool
    let removalPlan: XcodeDeviceSupportRemovalPlan?

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var canMoveToTrash: Bool { isComplete && fileCount > 0 && removalPlan != nil }
}

enum XcodeDeviceSupportNodeKind: Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other
}

struct XcodeDeviceSupportNodeSnapshot: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedAt: TimeInterval
    let changedAt: TimeInterval
    let linkCount: UInt32
    let kind: XcodeDeviceSupportNodeKind
}

struct XcodeDeviceSupportRemovalPlan: Equatable, Sendable {
    let parentSnapshot: XcodeDeviceSupportNodeSnapshot
    let entries: [XcodeDeviceSupportNodeSnapshot]
}

struct XcodeDeviceSupportProgress: Sendable {
    let folderName: String
    let entriesChecked: Int
}

struct XcodeDeviceSupportInventory: Sendable {
    let folders: [XcodeDeviceSupportFolder]
    let isAvailable: Bool
    let message: String?
    let entriesChecked: Int
    let skippedLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool

    static let empty = XcodeDeviceSupportInventory(
        folders: [], isAvailable: false, message: nil, entriesChecked: 0,
        skippedLocations: 0, wasLimited: false, wasCancelled: false
    )
}

struct XcodeStorageScanResult: Sendable {
    let archives: XcodeArchiveInventory
    let deviceSupport: XcodeDeviceSupportInventory
}

/// Inventories standard local Xcode device-support folders without opening file
/// contents. Only complete, ordinary folders receive a revalidation snapshot.
struct XcodeDeviceSupportInventoryService: Sendable {
    private let rootURL: URL
    private let securityAnchorURL: URL
    private let maximumEntries: Int
    private let maximumRemovalSnapshotEntries: Int

    init(homeURL: URL = SafeFilePolicy.accountHome, maximumEntries: Int = 250_000, maximumRemovalSnapshotEntries: Int = 50_000) {
        let home = homeURL.standardizedFileURL
        self.init(
            rootURL: home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true),
            securityAnchorURL: home,
            maximumEntries: maximumEntries,
            maximumRemovalSnapshotEntries: maximumRemovalSnapshotEntries
        )
    }

    init(rootURL: URL, maximumEntries: Int = 250_000, maximumRemovalSnapshotEntries: Int = 50_000) {
        self.init(
            rootURL: rootURL.standardizedFileURL,
            securityAnchorURL: rootURL.standardizedFileURL,
            maximumEntries: maximumEntries,
            maximumRemovalSnapshotEntries: maximumRemovalSnapshotEntries
        )
    }

    private init(rootURL: URL, securityAnchorURL: URL, maximumEntries: Int, maximumRemovalSnapshotEntries: Int) {
        self.rootURL = rootURL.standardizedFileURL
        self.securityAnchorURL = securityAnchorURL.standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.maximumRemovalSnapshotEntries = max(1, maximumRemovalSnapshotEntries)
    }

    func scan(
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (XcodeDeviceSupportProgress) -> Void = { _ in }
    ) -> XcodeDeviceSupportInventory {
        switch checkPath(from: securityAnchorURL, to: rootURL) {
        case .symbolicLink:
            return unavailable("The standard Xcode Device Support folder includes a symbolic link, so Mac Cleaner did not open it.", skipped: 1)
        case .unavailable:
            return unavailable("The Xcode Device Support folder could not be read with Mac Cleaner’s current permissions.", skipped: 1)
        case .safe:
            break
        }

        guard let kind = nodeKind(at: rootURL) else {
            if errno == ENOENT {
                return XcodeDeviceSupportInventory(
                    folders: [], isAvailable: true,
                    message: "No local Xcode Device Support folder was found.",
                    entriesChecked: 0, skippedLocations: 0, wasLimited: false, wasCancelled: false
                )
            }
            return unavailable("The Xcode Device Support folder could not be read with Mac Cleaner’s current permissions.", skipped: 1)
        }
        guard kind == .directory else {
            return unavailable("The Xcode Device Support location is not a regular folder.", skipped: 1)
        }
        guard let parentSnapshot = nodeSnapshot(at: rootURL), parentSnapshot.kind == .directory else {
            return unavailable("The Xcode Device Support folder changed while it was being checked.", skipped: 1)
        }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return unavailable("The Xcode Device Support folder is present but could not be listed.", skipped: 1)
        }

        var folders: [XcodeDeviceSupportFolder] = []
        var entriesChecked = 0
        var skipped = 0
        var wasLimited = false
        var wasCancelled = false

        for child in children {
            guard !isCancelled() else { wasCancelled = true; break }
            guard entriesChecked < maximumEntries else { wasLimited = true; break }
            entriesChecked += 1
            guard let childKind = nodeKind(at: child) else { skipped += 1; continue }
            guard childKind != .symbolicLink else { skipped += 1; continue }
            guard childKind == .directory else { continue }
            let remaining = maximumEntries - entriesChecked
            let entriesBeforeFolder = entriesChecked
            let folderName = child.lastPathComponent
            let inspection = inspect(
                child,
                maximumEntries: remaining,
                maximumRemovalSnapshotEntries: maximumRemovalSnapshotEntries,
                parentSnapshot: parentSnapshot,
                isCancelled: isCancelled,
                progress: { update in
                    progress(XcodeDeviceSupportProgress(
                        folderName: folderName,
                        entriesChecked: entriesBeforeFolder + update.entriesChecked
                    ))
                }
            )
            entriesChecked += inspection.entriesChecked
            skipped += inspection.skippedEntries
            wasLimited = wasLimited || inspection.wasLimited
            wasCancelled = wasCancelled || inspection.wasCancelled
            folders.append(XcodeDeviceSupportFolder(
                path: child.path,
                sizeBytes: inspection.sizeBytes,
                fileCount: inspection.fileCount,
                modifiedAt: inspection.modifiedAt,
                checkedEntries: inspection.entriesChecked,
                skippedEntries: inspection.skippedEntries,
                isComplete: inspection.isComplete,
                removalPlan: inspection.removalPlan
            ))
            if wasLimited || wasCancelled { break }
        }

        return XcodeDeviceSupportInventory(
            folders: folders.sorted {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            isAvailable: true,
            message: folders.isEmpty && !wasLimited && !wasCancelled
                ? "No device-support folders were found in Xcode's standard local location."
                : nil,
            entriesChecked: entriesChecked,
            skippedLocations: skipped,
            wasLimited: wasLimited,
            wasCancelled: wasCancelled
        )
    }

    private func inspect(
        _ folder: URL,
        maximumEntries: Int,
        maximumRemovalSnapshotEntries: Int,
        parentSnapshot: XcodeDeviceSupportNodeSnapshot,
        isCancelled: @Sendable () -> Bool,
        progress: @Sendable (XcodeDeviceSupportProgress) -> Void
    ) -> Inspection {
        guard checkPath(from: securityAnchorURL, to: folder) == .safe,
              nodeKind(at: folder) == .directory else {
            return Inspection(sizeBytes: 0, fileCount: 0, modifiedAt: modifiedDate(at: folder), entriesChecked: 0, skippedEntries: 1, isComplete: false, wasLimited: false, wasCancelled: false, removalPlan: nil)
        }

        var sizeBytes: Int64 = 0
        var fileCount = 0
        var entriesChecked = 0
        var skippedEntries = 0
        var wasLimited = false
        var wasCancelled = false
        var canBuildRemovalPlan = true
        var removalSnapshots: [XcodeDeviceSupportNodeSnapshot] = []
        guard let rootSnapshot = nodeSnapshot(at: folder), rootSnapshot.kind == .directory else {
            return Inspection(sizeBytes: 0, fileCount: 0, modifiedAt: modifiedDate(at: folder), entriesChecked: 0, skippedEntries: 1, isComplete: false, wasLimited: false, wasCancelled: false, removalPlan: nil)
        }
        if rootSnapshot.device == parentSnapshot.device {
            removalSnapshots.append(rootSnapshot)
        } else {
            canBuildRemovalPlan = false
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                skippedEntries += 1
                return true
            }
        )

        guard let enumerator else {
            return Inspection(sizeBytes: 0, fileCount: 0, modifiedAt: modifiedDate(at: folder), entriesChecked: 0, skippedEntries: 1, isComplete: false, wasLimited: false, wasCancelled: false, removalPlan: nil)
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
            if snapshot.device != rootSnapshot.device
                || snapshot.kind == .symbolicLink
                || snapshot.kind == .other
                || (snapshot.kind == .regularFile && snapshot.linkCount != 1) {
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
                progress(XcodeDeviceSupportProgress(folderName: folder.lastPathComponent, entriesChecked: entriesChecked))
            }
        }

        let isComplete = !wasLimited && !wasCancelled && skippedEntries == 0
        let removalPlan = canBuildRemovalPlan && isComplete
            ? XcodeDeviceSupportRemovalPlan(parentSnapshot: parentSnapshot, entries: removalSnapshots.sorted { $0.path < $1.path })
            : nil
        return Inspection(
            sizeBytes: sizeBytes,
            fileCount: fileCount,
            modifiedAt: modifiedDate(at: folder),
            entriesChecked: entriesChecked,
            skippedEntries: skippedEntries,
            isComplete: isComplete,
            wasLimited: wasLimited,
            wasCancelled: wasCancelled,
            removalPlan: removalPlan
        )
    }

    private func unavailable(_ message: String, skipped: Int) -> XcodeDeviceSupportInventory {
        XcodeDeviceSupportInventory(folders: [], isAvailable: false, message: message, entriesChecked: 0, skippedLocations: skipped, wasLimited: false, wasCancelled: false)
    }

    private func checkPath(from anchor: URL, to target: URL) -> PathCheck {
        let anchorPath = anchor.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == anchorPath || SafeFilePolicy.isInside(targetPath, root: anchorPath) else { return .unavailable }
        guard let anchorKind = nodeKind(at: anchor) else { return errno == ENOENT ? .safe : .unavailable }
        guard anchorKind != .symbolicLink else { return .symbolicLink }
        if targetPath != anchorPath && anchorKind != .directory { return .unavailable }
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

    private func nodeSnapshot(at url: URL) -> XcodeDeviceSupportNodeSnapshot? {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        let rawType = info.st_mode & S_IFMT
        let kind: XcodeDeviceSupportNodeKind
        if rawType == S_IFDIR { kind = .directory }
        else if rawType == S_IFREG { kind = .regularFile }
        else if rawType == S_IFLNK { kind = .symbolicLink }
        else { kind = .other }
        return XcodeDeviceSupportNodeSnapshot(
            path: url.standardizedFileURL.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: max(0, Int64(info.st_size)),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            changedAt: TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000,
            linkCount: UInt32(info.st_nlink),
            kind: kind
        )
    }

    private func modifiedDate(at url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private enum NodeKind: Equatable { case directory, file, symbolicLink, other }
    private enum PathCheck: Equatable { case safe, symbolicLink, unavailable }

    private struct Inspection {
        let sizeBytes: Int64
        let fileCount: Int
        let modifiedAt: Date
        let entriesChecked: Int
        let skippedEntries: Int
        let isComplete: Bool
        let wasLimited: Bool
        let wasCancelled: Bool
        let removalPlan: XcodeDeviceSupportRemovalPlan?
    }
}
