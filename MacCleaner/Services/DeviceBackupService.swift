import CryptoKit
import Darwin
import Foundation

struct DeviceBackup: Identifiable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int64
    let lastChangedAt: Date
    let fileCount: Int
    let isRecognizedBackup: Bool
    let canMoveToTrash: Bool
    let statusMessage: String?
    fileprivate let fingerprint: String

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct DeviceBackupProgress: Sendable {
    let backupName: String
    let entriesChecked: Int
}

struct DeviceBackupInventory: Sendable {
    let backups: [DeviceBackup]
    let isAvailable: Bool
    let message: String?
    let skippedLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool
}

enum DeviceBackupServiceError: LocalizedError {
    case outsideBackupFolder
    case incompleteBackup
    case changedSinceReview
    case unsafeContents
    case unavailable

    var errorDescription: String? {
        switch self {
        case .outsideBackupFolder:
            "This item is no longer inside the standard iPhone or iPad backup folder. Scan again before continuing."
        case .incompleteBackup:
            "This folder does not contain the expected iPhone or iPad backup files, so it was left in place."
        case .changedSinceReview:
            "This backup changed after it was reviewed. Scan again before deciding what to do."
        case .unsafeContents:
            "This backup contains a link, unreadable location, or unsupported file. Mac Cleaner left it in place."
        case .unavailable:
            "The local backup folder is not available. Check that Mac Cleaner still has Full Disk Access."
        }
    }
}

struct DeviceBackupMoveResult: Sendable {
    let path: String
    let sizeBytes: Int64
}

struct DeviceBackupService: Sendable {
    private let backupRootURL: URL
    private let securityAnchorURL: URL
    private let maximumEntriesPerBackup: Int
    private let maximumTotalEntries: Int
    private let trashOperation: @Sendable (URL) throws -> Void

    init(
        homeURL: URL = SafeFilePolicy.accountHome,
        maximumEntriesPerBackup: Int = 250_000,
        maximumTotalEntries: Int = 500_000,
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.init(
            backupRootURL: homeURL.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true),
            securityAnchorURL: homeURL,
            maximumEntriesPerBackup: maximumEntriesPerBackup,
            maximumTotalEntries: maximumTotalEntries,
            trashOperation: trashOperation
        )
    }

    init(
        backupRootURL: URL,
        maximumEntriesPerBackup: Int = 250_000,
        maximumTotalEntries: Int = 500_000,
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.init(
            backupRootURL: backupRootURL,
            securityAnchorURL: backupRootURL,
            maximumEntriesPerBackup: maximumEntriesPerBackup,
            maximumTotalEntries: maximumTotalEntries,
            trashOperation: trashOperation
        )
    }

    private init(
        backupRootURL: URL,
        securityAnchorURL: URL,
        maximumEntriesPerBackup: Int,
        maximumTotalEntries: Int,
        trashOperation: @escaping @Sendable (URL) throws -> Void
    ) {
        self.backupRootURL = backupRootURL.standardizedFileURL
        self.securityAnchorURL = securityAnchorURL.standardizedFileURL
        self.maximumEntriesPerBackup = max(1, maximumEntriesPerBackup)
        self.maximumTotalEntries = max(1, maximumTotalEntries)
        self.trashOperation = trashOperation
    }

    func scan(
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (DeviceBackupProgress) -> Void = { _ in }
    ) -> DeviceBackupInventory {
        guard let rootMetadata = metadata(at: backupRootURL), rootMetadata.kind == .directory else {
            let exists = FileManager.default.fileExists(atPath: backupRootURL.path)
            return DeviceBackupInventory(
                backups: [],
                isAvailable: !exists,
                message: exists ? "The standard backup folder could not be read safely." : "No local device-backup folder was found.",
                skippedLocations: exists ? 1 : 0,
                wasLimited: false,
                wasCancelled: false
            )
        }
        guard hasNoSymlinkedPathComponent(backupRootURL) else {
            return DeviceBackupInventory(
                backups: [],
                isAvailable: false,
                message: "The standard backup folder contains a symbolic link, so Mac Cleaner did not open it.",
                skippedLocations: 1,
                wasLimited: false,
                wasCancelled: false
            )
        }
        var backups: [DeviceBackup] = []
        var skipped = 0
        var limited = false
        var cancelled = false
        var topLevelEntries = 0
        var totalEntriesChecked = 0
        let rootWasReadable = enumerateDirectory(backupRootURL) { name in
            if isCancelled() {
                cancelled = true
                return false
            }
            guard totalEntriesChecked < maximumTotalEntries else {
                limited = true
                return false
            }
            topLevelEntries += 1
            if topLevelEntries > 1_024 {
                limited = true
                return false
            }
            let candidateURL = backupRootURL.appendingPathComponent(name, isDirectory: true).standardizedFileURL
            guard SafeFilePolicy.isInside(candidateURL.path, root: backupRootURL.path),
                  let candidateMetadata = metadata(at: candidateURL),
                  candidateMetadata.kind == .directory else {
                skipped += 1
                return true
            }
            let remainingEntries = maximumTotalEntries - totalEntriesChecked
            let inspection = inspect(
                candidateURL,
                maximumEntries: min(maximumEntriesPerBackup, remainingEntries),
                isCancelled: isCancelled,
                progress: { entries in
                    progress(DeviceBackupProgress(backupName: name, entriesChecked: entries))
                }
            )
            guard let inspection else {
                skipped += 1
                return true
            }
            if inspection.wasCancelled {
                cancelled = true
                return false
            }
            totalEntriesChecked += inspection.entriesChecked
            limited = limited || inspection.wasLimited
            backups.append(inspection.backup)
            return true
        }
        if cancelled || isCancelled() {
            return DeviceBackupInventory(
                backups: [],
                isAvailable: true,
                message: "Scan cancelled. Run Find Backups again to review local backups.",
                skippedLocations: skipped,
                wasLimited: limited,
                wasCancelled: true
            )
        }
        guard rootWasReadable else {
            return DeviceBackupInventory(
                backups: backups,
                isAvailable: !backups.isEmpty,
                message: "Mac Cleaner could not fully read the standard backup folder. Unreadable items stay out of cleanup review.",
                skippedLocations: skipped + 1,
                wasLimited: limited,
                wasCancelled: false
            )
        }
        backups.sort {
            if $0.lastChangedAt != $1.lastChangedAt { return $0.lastChangedAt > $1.lastChangedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return DeviceBackupInventory(
            backups: backups,
            isAvailable: true,
            message: backups.isEmpty ? "No local iPhone or iPad backups were found in the standard backup folder." : nil,
            skippedLocations: skipped,
            wasLimited: limited,
            wasCancelled: false
        )
    }

    func moveToTrash(_ backup: DeviceBackup) throws -> DeviceBackupMoveResult {
        let candidateURL = URL(fileURLWithPath: backup.path, isDirectory: true).standardizedFileURL
        guard candidateURL.deletingLastPathComponent().standardizedFileURL == backupRootURL,
              SafeFilePolicy.isInside(candidateURL.path, root: backupRootURL.path),
              hasNoSymlinkedPathComponent(candidateURL) else {
            throw DeviceBackupServiceError.outsideBackupFolder
        }
        guard backup.canMoveToTrash, backup.isRecognizedBackup else {
            throw DeviceBackupServiceError.incompleteBackup
        }
        guard let current = inspect(
            candidateURL,
            maximumEntries: maximumEntriesPerBackup,
            isCancelled: { false },
            progress: { _ in }
        ) else {
            throw DeviceBackupServiceError.unavailable
        }
        guard current.backup.isRecognizedBackup else { throw DeviceBackupServiceError.incompleteBackup }
        guard current.backup.canMoveToTrash else { throw DeviceBackupServiceError.unsafeContents }
        guard current.backup.fingerprint == backup.fingerprint,
              current.backup.sizeBytes == backup.sizeBytes,
              current.backup.lastChangedAt == backup.lastChangedAt else {
            throw DeviceBackupServiceError.changedSinceReview
        }
        try trashOperation(candidateURL)
        return DeviceBackupMoveResult(path: candidateURL.path, sizeBytes: backup.sizeBytes)
    }

    private struct Inspection {
        let backup: DeviceBackup
        let wasLimited: Bool
        let wasCancelled: Bool
        let entriesChecked: Int
    }

    private enum EntryKind: UInt8 {
        case directory = 1
        case regularFile = 2
        case other = 3
    }

    private struct Entry: Sendable {
        let relativePath: String
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let kind: EntryKind

        var canonical: String {
            "\(relativePath)|\(device)|\(inode)|\(size)|\(modifiedSeconds)|\(modifiedNanoseconds)|\(kind.rawValue)"
        }
    }

    private struct Metadata {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let kind: EntryKind
        var modifiedAt: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000) }
    }

    private func inspect(
        _ backupURL: URL,
        maximumEntries: Int,
        isCancelled: @Sendable () -> Bool,
        progress: @Sendable (Int) -> Void
    ) -> Inspection? {
        guard backupURL.deletingLastPathComponent().standardizedFileURL == backupRootURL,
              let rootInfo = metadata(at: backupURL),
              rootInfo.kind == .directory else { return nil }

        var pending = [backupURL]
        var entries: [Entry] = []
        var bytes: Int64 = 0
        var fileCount = 0
        var skipped = false
        var wasLimited = false
        var wasCancelled = false
        var latestModificationDate = rootInfo.modifiedAt
        var hasInfo = false
        var hasManifest = false
        var checked = 0

        while let directory = pending.popLast(), !wasLimited, !wasCancelled {
            let directoryWasReadable = enumerateDirectory(directory) { name in
                if isCancelled() {
                    wasCancelled = true
                    return false
                }
                let itemURL = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
                if checked >= maximumEntries {
                    wasLimited = true
                    return false
                }
                checked += 1
                guard SafeFilePolicy.isInside(itemURL.path, root: backupURL.path),
                      let item = metadata(at: itemURL) else {
                    skipped = true
                    return true
                }
                let relativePath = String(itemURL.path.dropFirst(backupURL.path.count + 1))
                entries.append(Entry(
                    relativePath: relativePath,
                    device: item.device,
                    inode: item.inode,
                    size: item.size,
                    modifiedSeconds: item.modifiedSeconds,
                    modifiedNanoseconds: item.modifiedNanoseconds,
                    kind: item.kind
                ))
                latestModificationDate = max(latestModificationDate, item.modifiedAt)
                switch item.kind {
                case .directory:
                    pending.append(itemURL)
                case .regularFile:
                    fileCount += 1
                    let total = bytes.addingReportingOverflow(item.size)
                    bytes = total.overflow ? Int64.max : total.partialValue
                    if directory == backupURL && name == "Info.plist" { hasInfo = true }
                    if directory == backupURL && (name == "Manifest.db" || name == "Manifest.plist") { hasManifest = true }
                case .other:
                    skipped = true
                }
                if checked.isMultiple(of: 256) { progress(checked) }
                return true
            }
            if !directoryWasReadable { skipped = true }
        }

        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data((entry.canonical + "\n").utf8))
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let recognized = hasInfo && hasManifest
        let isCompleteEnoughToReview = recognized && !wasLimited && !skipped
        let statusMessage: String?
        if wasLimited {
            statusMessage = "This backup contains more files than Mac Cleaner can safely verify in one review. It is view-only."
        } else if skipped {
            statusMessage = "Some backup items could not be checked. This backup is view-only."
        } else if !recognized {
            statusMessage = "Expected backup files were not found. This folder is view-only."
        } else {
            statusMessage = nil
        }
        let backup = DeviceBackup(
            path: backupURL.path,
            sizeBytes: bytes,
            lastChangedAt: latestModificationDate,
            fileCount: fileCount,
            isRecognizedBackup: recognized,
            canMoveToTrash: isCompleteEnoughToReview,
            statusMessage: statusMessage,
            fingerprint: fingerprint
        )
        return Inspection(backup: backup, wasLimited: wasLimited, wasCancelled: wasCancelled, entriesChecked: checked)
    }

    private func metadata(at url: URL) -> Metadata? {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else { return nil }
        let fileType = info.st_mode & mode_t(S_IFMT)
        let kind: EntryKind
        if fileType == mode_t(S_IFDIR) { kind = .directory }
        else if fileType == mode_t(S_IFREG) { kind = .regularFile }
        else if fileType == mode_t(S_IFLNK) { return nil }
        else { kind = .other }
        return Metadata(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: max(0, Int64(info.st_size)),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            kind: kind
        )
    }

    private func enumerateDirectory(_ url: URL, visit: (String) -> Bool) -> Bool {
        guard let handle = url.path.withCString({ Darwin.opendir($0) }) else { return false }
        defer { Darwin.closedir(handle) }
        var stoppedByVisitor = false
        var readFailed = false
        while true {
            errno = 0
            guard let entry = Darwin.readdir(handle) else {
                readFailed = errno != 0
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            if !visit(name) {
                stoppedByVisitor = true
                break
            }
        }
        return stoppedByVisitor || !readFailed
    }

    private func hasNoSymlinkedPathComponent(_ url: URL) -> Bool {
        let anchor = securityAnchorURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate == anchor || SafeFilePolicy.isInside(candidate.path, root: anchor.path) else { return false }
        var anchorInfo = stat()
        let anchorResult = anchor.path.withCString { Darwin.lstat($0, &anchorInfo) }
        guard anchorResult == 0, anchorInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
        var current = anchor
        let anchorComponents = anchor.pathComponents
        for component in candidate.pathComponents.dropFirst(anchorComponents.count) {
            current.appendPathComponent(component)
            var info = stat()
            let result = current.path.withCString { Darwin.lstat($0, &info) }
            guard result == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { return false }
        }
        return true
    }
}
