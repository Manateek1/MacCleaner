import Darwin
import Foundation

struct DiagnosticReport: Identifiable, Equatable, Sendable {
    let path: String
    let identity: FileIdentity
    let canMoveToTrash: Bool
    let statusMessage: String?

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var sizeBytes: Int64 { identity.size }
    var modifiedAt: Date { Date(timeIntervalSince1970: identity.modifiedAt) }
}

struct DiagnosticReportProgress: Sendable {
    let reportsChecked: Int
}

struct DiagnosticReportInventory: Sendable {
    let reports: [DiagnosticReport]
    let isAvailable: Bool
    let message: String?
    let ageThresholdDays: Int
    let recentReportsKept: Int
    let entriesChecked: Int
    let skippedLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool

    static func empty(ageThresholdDays: Int = 90) -> DiagnosticReportInventory {
        DiagnosticReportInventory(
            reports: [], isAvailable: false, message: nil, ageThresholdDays: ageThresholdDays,
            recentReportsKept: 0, entriesChecked: 0, skippedLocations: 0,
            wasLimited: false, wasCancelled: false
        )
    }
}

enum DiagnosticReportServiceError: LocalizedError {
    case outsideReportFolder
    case changedSinceReview
    case tooRecent
    case sharedFile
    case unavailable

    var errorDescription: String? {
        switch self {
        case .outsideReportFolder:
            "This report is no longer inside the standard DiagnosticReports folder. Scan again before continuing."
        case .changedSinceReview:
            "This report changed after it was reviewed. Scan again before deciding what to do."
        case .tooRecent:
            "This report is newer than the selected age cutoff. It was left in place."
        case .sharedFile:
            "This report has a hard-linked copy, so Mac Cleaner left it in place."
        case .unavailable:
            "The standard DiagnosticReports folder could not be opened with Mac Cleaner’s current permissions."
        }
    }
}

struct DiagnosticReportActionOutcome: Sendable {
    let path: String
    let bytesMoved: Int64
    let error: String?
}

private final class DiagnosticReportErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct DiagnosticReportInventoryService: Sendable {
    private static let supportedExtensions: Set<String> = ["crash", "ips", "diag", "hang", "spin", "panic"]

    private let reportRootURL: URL
    private let securityAnchorURL: URL
    private let maximumEntries: Int
    private let trashOperation: @Sendable (URL) throws -> Void

    init(
        homeURL: URL = SafeFilePolicy.accountHome,
        maximumEntries: Int = 100_000,
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        let home = homeURL.standardizedFileURL
        self.init(
            reportRootURL: home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            securityAnchorURL: home,
            maximumEntries: maximumEntries,
            trashOperation: trashOperation
        )
    }

    init(
        reportRootURL: URL,
        maximumEntries: Int = 100_000,
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.init(
            reportRootURL: reportRootURL.standardizedFileURL,
            securityAnchorURL: reportRootURL.standardizedFileURL,
            maximumEntries: maximumEntries,
            trashOperation: trashOperation
        )
    }

    private init(
        reportRootURL: URL,
        securityAnchorURL: URL,
        maximumEntries: Int,
        trashOperation: @escaping @Sendable (URL) throws -> Void
    ) {
        self.reportRootURL = reportRootURL.standardizedFileURL
        self.securityAnchorURL = securityAnchorURL.standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.trashOperation = trashOperation
    }

    func scan(
        olderThanDays: Int = 90,
        now: Date = Date(),
        isCancelled: @Sendable () -> Bool = { Task.isCancelled },
        progress: @Sendable (DiagnosticReportProgress) -> Void = { _ in }
    ) -> DiagnosticReportInventory {
        let threshold = max(30, olderThanDays)
        guard let rootKind = nodeKind(at: reportRootURL) else {
            if errno == ENOENT {
                return result([], available: true, message: "No local DiagnosticReports folder was found.", threshold: threshold)
            }
            return unavailable("The DiagnosticReports folder could not be read with Mac Cleaner’s current permissions.", threshold: threshold, skipped: 1)
        }
        guard rootKind == .directory else {
            return unavailable("The DiagnosticReports location is not a regular folder.", threshold: threshold, skipped: 1)
        }
        guard pathHasNoSymlinks(reportRootURL.path) else {
            return unavailable("The standard DiagnosticReports folder contains a symbolic link or could not be checked safely.", threshold: threshold, skipped: 1)
        }
        let enumerationErrors = DiagnosticReportErrorCounter()
        guard let enumerator = FileManager.default.enumerator(
            at: reportRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationErrors.increment()
                return true
            }
        ) else {
            return unavailable("The DiagnosticReports folder is present but could not be opened.", threshold: threshold, skipped: 1)
        }
        if isCancelled() {
            return DiagnosticReportInventory(
                reports: [], isAvailable: true, message: nil, ageThresholdDays: threshold,
                recentReportsKept: 0, entriesChecked: 0, skippedLocations: 0,
                wasLimited: false, wasCancelled: true
            )
        }

        let cutoff = now.addingTimeInterval(-Double(threshold) * 24 * 60 * 60)
        var reports: [DiagnosticReport] = []
        var recent = 0
        var entriesChecked = 0
        var skipped = 0
        var wasLimited = false
        var wasCancelled = false

        while let item = enumerator.nextObject() as? URL {
            if isCancelled() { wasCancelled = true; break }
            guard entriesChecked < maximumEntries else { wasLimited = true; break }
            entriesChecked += 1
            guard Self.supportedExtensions.contains(item.pathExtension.lowercased()) else { continue }
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  let identity = identity(at: item) else {
                skipped += 1
                continue
            }
            if modifiedAt > cutoff {
                recent += 1
                continue
            }
            let hasSafeParents = pathHasNoSymlinks(item.path)
            let canMoveToTrash = identity.linkCount == 1 && hasSafeParents
            reports.append(DiagnosticReport(
                path: item.path,
                identity: identity,
                canMoveToTrash: canMoveToTrash,
                statusMessage: canMoveToTrash ? nil : (identity.linkCount > 1 ? "Hard-linked report; view-only." : "Path changed or could not be checked; view-only.")
            ))
            if entriesChecked.isMultiple(of: 500) {
                progress(DiagnosticReportProgress(reportsChecked: entriesChecked))
            }
        }
        skipped += enumerationErrors.count

        let message = reports.isEmpty && recent == 0 && !wasLimited && !wasCancelled
            ? "No diagnostic reports older than \(threshold) days were found in the standard local folder."
            : nil
        return DiagnosticReportInventory(
            reports: reports.sorted {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            isAvailable: true,
            message: message,
            ageThresholdDays: threshold,
            recentReportsKept: recent,
            entriesChecked: entriesChecked,
            skippedLocations: skipped,
            wasLimited: wasLimited,
            wasCancelled: wasCancelled
        )
    }

    func moveToTrash(_ report: DiagnosticReport, olderThanDays: Int = 90, now: Date = Date()) throws -> Int64 {
        let path = URL(fileURLWithPath: report.path).standardizedFileURL.path
        guard isInsideReportFolder(path),
              Self.supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              pathHasNoSymlinks(path) else {
            throw DiagnosticReportServiceError.outsideReportFolder
        }
        guard let current = identity(at: URL(fileURLWithPath: path)), current == report.identity else {
            throw DiagnosticReportServiceError.changedSinceReview
        }
        guard current.linkCount == 1 else { throw DiagnosticReportServiceError.sharedFile }
        let cutoff = now.addingTimeInterval(-Double(max(30, olderThanDays)) * 24 * 60 * 60)
        guard Date(timeIntervalSince1970: current.modifiedAt) <= cutoff else {
            throw DiagnosticReportServiceError.tooRecent
        }
        try trashOperation(URL(fileURLWithPath: path))
        return current.size
    }

    private func result(
        _ reports: [DiagnosticReport],
        available: Bool,
        message: String?,
        threshold: Int
    ) -> DiagnosticReportInventory {
        DiagnosticReportInventory(
            reports: reports,
            isAvailable: available,
            message: message,
            ageThresholdDays: threshold,
            recentReportsKept: 0,
            entriesChecked: 0,
            skippedLocations: 0,
            wasLimited: false,
            wasCancelled: false
        )
    }

    private func unavailable(_ message: String, threshold: Int, skipped: Int) -> DiagnosticReportInventory {
        DiagnosticReportInventory(
            reports: [], isAvailable: false, message: message, ageThresholdDays: threshold,
            recentReportsKept: 0, entriesChecked: 0, skippedLocations: skipped,
            wasLimited: false, wasCancelled: false
        )
    }

    private func nodeKind(at url: URL) -> NodeKind? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return nil }
        let fileType = info.st_mode & S_IFMT
        if fileType == S_IFDIR { return .directory }
        if fileType == S_IFREG { return .regularFile }
        if fileType == S_IFLNK { return .symbolicLink }
        return .other
    }

    private func identity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            linkCount: UInt32(info.st_nlink)
        )
    }

    private func isInsideReportFolder(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = reportRootURL.standardizedFileURL.path
        return candidate != root && SafeFilePolicy.isInside(candidate, root: root)
    }

    private func pathHasNoSymlinks(_ path: String) -> Bool {
        let anchor = securityAnchorURL.standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target == anchor || SafeFilePolicy.isInside(target, root: anchor),
              let anchorKind = nodeKind(at: URL(fileURLWithPath: anchor, isDirectory: true)),
              anchorKind == .directory else { return false }
        if target == anchor { return true }

        let relative = String(target.dropFirst(anchor.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.split(separator: "/")
        var current = anchor == "/" ? "" : anchor
        for (index, component) in components.enumerated() {
            current += "/" + component
            guard let kind = nodeKind(at: URL(fileURLWithPath: current)) else { return false }
            guard kind != .symbolicLink else { return false }
            if index < components.count - 1 && kind != .directory { return false }
        }
        return true
    }

    private enum NodeKind: Equatable { case directory, regularFile, symbolicLink, other }
}
