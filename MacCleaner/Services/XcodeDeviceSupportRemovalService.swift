import AppKit
import Darwin
import Foundation

struct XcodeDeviceSupportRemovalFailure: Equatable, Sendable {
    let path: String
    let reason: String
}

struct XcodeDeviceSupportRemovalResult: Sendable {
    let movedPaths: [String]
    let failures: [XcodeDeviceSupportRemovalFailure]
    let bytesMoved: Int64
}

struct XcodeDeviceSupportRemovalService: Sendable {
    private let homeURL: URL
    private let maximumEntries: Int
    private let isXcodeRunning: @Sendable () -> Bool
    private let trashOperation: @Sendable (URL) throws -> Void

    init(
        homeURL: URL = SafeFilePolicy.accountHome,
        maximumEntries: Int = 50_000,
        isXcodeRunning: @escaping @Sendable () -> Bool = {
            ["com.apple.dt.Xcode", "com.apple.dt.Xcode-beta"].contains { bundleID in
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
            }
        },
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.homeURL = homeURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.isXcodeRunning = isXcodeRunning
        self.trashOperation = trashOperation
    }

    func moveToTrash(_ folders: [XcodeDeviceSupportFolder]) -> XcodeDeviceSupportRemovalResult {
        let uniqueFolders = Dictionary(grouping: folders, by: \.path)
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
        var movedPaths: [String] = []
        var failures: [XcodeDeviceSupportRemovalFailure] = []
        var bytesMoved: Int64 = 0

        for folder in uniqueFolders {
            guard folder.canMoveToTrash, let plan = folder.removalPlan else {
                failures.append(failure(folder, "This support folder was not fully checked, so it was left in place."))
                continue
            }
            guard isApprovedPath(folder.path),
                  let parentSnapshot = Self.snapshot(at: URL(fileURLWithPath: folder.path).deletingLastPathComponent()),
                  Self.sameDirectoryIdentity(parentSnapshot, plan.parentSnapshot) else {
                failures.append(failure(folder, "The folder location changed or is outside Xcode's standard Device Support folder."))
                continue
            }

            do {
                let currentEntries = try snapshotTree(at: URL(fileURLWithPath: folder.path))
                guard currentEntries == plan.entries else {
                    failures.append(failure(folder, "This support folder changed after the scan. Refresh and review it again."))
                    continue
                }
            } catch let error as RemovalError {
                failures.append(failure(folder, error.localizedDescription))
                continue
            } catch {
                failures.append(failure(folder, "The folder could not be rechecked safely, so it was left in place."))
                continue
            }

            guard !isXcodeRunning() else {
                failures.append(failure(folder, "Quit Xcode before moving device-support folders. This folder was left in place."))
                continue
            }

            do {
                try trashOperation(URL(fileURLWithPath: folder.path))
                movedPaths.append(folder.path)
                bytesMoved = Self.saturatingAdd(bytesMoved, folder.sizeBytes)
            } catch {
                failures.append(failure(folder, "macOS could not move this support folder to Trash."))
            }
        }

        return XcodeDeviceSupportRemovalResult(movedPaths: movedPaths, failures: failures, bytesMoved: bytesMoved)
    }

    private func isApprovedPath(_ path: String) -> Bool {
        let supportRoot = homeURL.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true).standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard candidate.path != supportRoot.path,
              SafeFilePolicy.isInside(candidate.path, root: supportRoot.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: supportRoot.path, root: homeURL.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: candidate.path, root: homeURL.path),
              !SafeFilePolicy.isEssentialSystemLocation(candidate.path),
              !SafeFilePolicy.isInsideDevelopmentRepository(candidate.path, homeDirectory: homeURL) else { return false }

        let relative = String(candidate.path.dropFirst(supportRoot.path.count + 1))
        return !relative.isEmpty && !relative.contains("/")
    }

    private func snapshotTree(at root: URL) throws -> [XcodeDeviceSupportNodeSnapshot] {
        guard isApprovedPath(root.path),
              let rootSnapshot = Self.snapshot(at: root), rootSnapshot.kind == .directory,
              let parentSnapshot = Self.snapshot(at: root.deletingLastPathComponent()),
              rootSnapshot.device == parentSnapshot.device else {
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
                      let snapshot = Self.snapshot(at: child), snapshot.device == rootSnapshot.device else {
                    throw RemovalError.changed
                }
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

    private func failure(_ folder: XcodeDeviceSupportFolder, _ reason: String) -> XcodeDeviceSupportRemovalFailure {
        XcodeDeviceSupportRemovalFailure(path: folder.path, reason: reason)
    }

    private static func snapshot(at url: URL) -> XcodeDeviceSupportNodeSnapshot? {
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

    private static func sameDirectoryIdentity(
        _ lhs: XcodeDeviceSupportNodeSnapshot,
        _ rhs: XcodeDeviceSupportNodeSnapshot
    ) -> Bool {
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
                "Only folders in the standard local Xcode Device Support location can be moved."
            case .changed:
                "This folder changed after the scan. Refresh and review it again."
            case .inaccessible:
                "Some folder contents could not be checked; the folder was left in place."
            case .tooLargeToCheck:
                "This folder exceeds the safety limit and was left in place."
            case .sharedFile:
                "This folder contains a shared file and was left in place."
            case .unsafeSymbolicLink:
                "This folder contains a symbolic link and was left in place."
            case .unsupportedFileType:
                "This folder contains an unsupported item and was left in place."
            }
        }
    }
}
