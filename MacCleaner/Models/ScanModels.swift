import Foundation

enum ScanKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case smart
    case largeAndOld
    case duplicates
    case junk
    case aiClutter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: "Smart Scan"
        case .largeAndOld: "Large & Old Files"
        case .duplicates: "Exact Duplicates"
        case .junk: "System Junk"
        case .aiClutter: "AI Clutter"
        }
    }

    var subtitle: String {
        switch self {
        case .smart: "Find files worth reviewing. A full Mac scan also checks app signatures and startup items."
        case .largeAndOld: "Review files above your size threshold or older than your age threshold."
        case .duplicates: "Find identical files, choose which copy to keep, and review the rest."
        case .junk: "Find recognized user caches, app logs, crash reports, and Xcode DerivedData."
        case .aiClutter: "Review temporary files under recognized AI-tool folders. Chats, sign-in details, settings, and models are skipped."
        }
    }
}

enum SmartScanSecurityReviewPolicy {
    static func shouldRunAppSecurity(kind: ScanKind, root: URL) -> Bool {
        kind == .smart && root.standardizedFileURL.path == "/"
    }
}

enum DuplicateKeepPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case oldest
    case newest

    static let storageKey = "MacCleaner.duplicateKeepPreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oldest: "Oldest modified"
        case .newest: "Newest modified"
        }
    }

    func ranksBefore(_ lhsDate: TimeInterval, path lhsPath: String, _ rhsDate: TimeInterval, path rhsPath: String) -> Bool {
        if lhsDate != rhsDate {
            switch self {
            case .oldest: return lhsDate < rhsDate
            case .newest: return lhsDate > rhsDate
            }
        }
        return lhsPath.localizedStandardCompare(rhsPath) == .orderedAscending
    }
}

enum FindingCategory: String, CaseIterable, Hashable, Codable, Identifiable, Sendable {
    case largeFile
    case oldFile
    case exactDuplicate
    case cacheCandidate
    case aiCacheCandidate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largeFile: "Large file"
        case .oldFile: "Older file"
        case .exactDuplicate: "Exact duplicate"
        case .cacheCandidate: "Temporary or log file"
        case .aiCacheCandidate: "AI app temporary"
        }
    }
}

enum FindingLocation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case desktop
    case documents
    case downloads
    case pictures
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .pictures: "Pictures"
        case .other: "Other checked locations"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: "desktopcomputer"
        case .documents: "doc.text"
        case .downloads: "arrow.down.circle"
        case .pictures: "photo"
        case .other: "folder"
        }
    }

    static func classify(_ candidatePath: String, homeDirectory: URL) -> FindingLocation {
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        for location in [FindingLocation.desktop, .documents, .downloads, .pictures] {
            let root = homeDirectory.appendingPathComponent(location.rawValue.capitalized, isDirectory: true).standardizedFileURL.path
            if candidate == root || candidate.hasPrefix(root + "/") { return location }
        }
        return .other
    }

    func contains(_ candidatePath: String, homeDirectory: URL) -> Bool {
        Self.classify(candidatePath, homeDirectory: homeDirectory) == self
    }
}

struct FileIdentity: Equatable, Hashable, Codable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedAt: TimeInterval
    let linkCount: UInt32
}

struct CacheReviewDetails: Codable, Equatable, Hashable, Sendable {
    let sourceApplication: String
    let summary: String
    let consequence: String
    let reason: String
}

struct ScanItem: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let identity: FileIdentity
    let lastAccessedAt: Date?
    let isCloudManaged: Bool?
    let categories: [FindingCategory]
    let reasons: [String]
    let safetyNote: String
    let confidence: Double
    let duplicateGroupID: String?
    let duplicateGroupCount: Int
    let suggestedKeepPath: String?
    let cacheReviewDetails: CacheReviewDetails?

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var size: Int64 { identity.size }
    var modifiedAt: Date { Date(timeIntervalSince1970: identity.modifiedAt) }
    var fileTypeKey: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    var fileTypeTitle: String {
        fileTypeKey.isEmpty ? "Files without an extension" : "\(fileTypeKey.uppercased()) files"
    }
    var primaryCategory: FindingCategory { categories.first ?? .largeFile }
    var url: URL { URL(fileURLWithPath: path) }
    var sourceApplication: String {
        guard categories.contains(.aiCacheCandidate) else {
            return cacheReviewDetails?.sourceApplication ?? "Not reliably identified"
        }
        let components = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        if components.contains(where: { $0.contains("openai") || $0 == "codex" }) { return "OpenAI Codex" }
        if components.contains(where: { $0.contains("claude") || $0.contains("anthropic") }) { return "Claude" }
        if components.contains(where: { $0.contains("cursor") }) { return "Cursor" }
        if components.contains(where: { $0.contains("copilot") }) { return "GitHub Copilot" }
        if components.contains(where: { $0.contains("gemini") }) { return "Gemini CLI" }
        if components.contains(where: { $0.contains("ollama") }) { return "Ollama" }
        if components.contains(where: { $0.contains("lm studio") || $0.contains("lm-studio") }) { return "LM Studio" }
        return "AI tool not reliably identified"
    }
    var consequence: String {
        if isCloudManaged == true {
            return "This is a local copy of an iCloud Drive item. Mac Cleaner keeps cloud-managed files out of Trash because removal could sync to iCloud."
        }
        if categories.contains(.exactDuplicate) { return "These files have the same contents. The copy you choose stays; other accessible copies are checked for review." }
        if categories.contains(.aiCacheCandidate) { return "The app may recreate temporary files. Conversations, sign-in details, settings, and downloaded models are kept out of this scan." }
        if categories.contains(.cacheCandidate) {
            return cacheReviewDetails?.consequence ?? "An app may recreate cache files. Logs can contain useful troubleshooting history."
        }
        return "A large or older file is not necessarily junk. Open it and check what it is before deciding. Moving it to Trash is reversible."
    }
    var plainLanguageSummary: String {
        if isCloudManaged == true {
            if categories.contains(.exactDuplicate) {
                return "This local copy matches another file. It stays in iCloud Drive and is shown for review only."
            }
            var observations: [String] = []
            if categories.contains(.largeFile) { observations.append("larger than your size setting") }
            if categories.contains(.oldFile) { observations.append("not changed recently") }
            return "This local iCloud Drive file is \(observations.joined(separator: " and ")). It is shown for review only."
        }
        if categories.contains(.exactDuplicate) {
            return "These files have the same contents. Choose one copy to keep; the other accessible copies can be reviewed together."
        }
        if categories.contains(.aiCacheCandidate) {
            return "This looks like temporary data for \(sourceApplication). It may be recreated by that app."
        }
        if categories.contains(.cacheCandidate) {
            return cacheReviewDetails?.summary ?? "This is in a folder commonly used for temporary files or logs. It may still be useful."
        }
        var observations: [String] = []
        if categories.contains(.largeFile) { observations.append("larger than your size setting") }
        if categories.contains(.oldFile) { observations.append("not changed recently") }
        return "This file is \(observations.joined(separator: " and ")). Size and age alone do not mean it is junk."
    }
}

enum DuplicateKeepSelection {
    static func selectingAlternatives(
        in group: [ScanItem],
        keepingPath: String,
        from existingSelection: Set<String>,
        eligiblePaths: Set<String>
    ) -> Set<String> {
        guard group.contains(where: { $0.path == keepingPath }) else { return existingSelection }
        let groupPaths = Set(group.map(\.path))
        var selection = existingSelection.subtracting(groupPaths)
        for item in group where item.path != keepingPath && eligiblePaths.contains(item.path) {
            selection.insert(item.path)
        }
        return selection
    }
}

struct ScanProgress: Sendable {
    let stage: String
    let filesVisited: Int
    let bytesVisited: Int64
    var entriesVisited: Int = 0
}

enum SpaceFileType: String, CaseIterable, Codable, Hashable, Sendable {
    case photos
    case videos
    case audio
    case documents
    case archives
    case installers
    case code
    case other
    case noExtension

    var title: String {
        switch self {
        case .photos: "Photos & images"
        case .videos: "Videos"
        case .audio: "Music & audio"
        case .documents: "Documents"
        case .archives: "Compressed files"
        case .installers: "Apps & installers"
        case .code: "Code & project files"
        case .other: "Other files"
        case .noExtension: "Files without an extension"
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .videos: "video"
        case .audio: "waveform"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .installers: "shippingbox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        case .noExtension: "doc.questionmark"
        }
    }

    static func classify(fileExtension: String) -> SpaceFileType {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !ext.isEmpty else { return .noExtension }
        if ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "avif"].contains(ext) { return .photos }
        if ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mpeg", "mpg"].contains(ext) { return .videos }
        if ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg"].contains(ext) { return .audio }
        if ["pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "csv"].contains(ext) { return .documents }
        if ["zip", "tar", "gz", "bz2", "xz", "7z", "rar"].contains(ext) { return .archives }
        if ["dmg", "pkg", "xip", "iso"].contains(ext) { return .installers }
        if ["swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "json", "yaml", "yml", "toml", "sql", "sh", "rb", "go", "rs", "c", "h", "cpp", "java", "kt", "lock"].contains(ext) { return .code }
        return .other
    }
}

struct SpaceSnapshot: Codable, Sendable {
    let folderBytes: [String: Int64]
    let directFileBytes: [String: Int64]
    let directFileCounts: [String: Int]
    let fileTypeBytes: [String: [SpaceFileType: Int64]]
    let fileTypeCounts: [String: [SpaceFileType: Int]]
}

struct ScanResult: Codable, Sendable {
    let kind: ScanKind
    let rootPath: String
    let filesVisited: Int
    let entriesVisited: Int
    let entryLimit: Int
    let bytesVisited: Int64
    let skippedItems: Int
    let skippedLocations: [String]
    let cloudFilesNotLocallyAvailable: Int?
    let cloudFilesLocallyAvailable: Int?
    let cloudDesktopAccessUnavailable: Bool?
    let excludedLocations: [String]
    let items: [ScanItem]
    let finishedAt: Date
    let wasTruncated: Bool
    let space: SpaceSnapshot?
    let duplicateKeepPreference: DuplicateKeepPreference

    var displayedSkippedLocations: [String] {
        Array(skippedLocations.prefix(5))
    }

    var omittedSkippedLocationCount: Int {
        max(0, skippedItems - displayedSkippedLocations.count)
    }

    var potentialBytesToReview: Int64 {
        items.reduce(into: Int64(0)) { total, item in
            if item.isCloudManaged == true { return }
            if item.duplicateGroupID != nil && item.path == item.suggestedKeepPath { return }
            total += item.size
        }
    }

    func removingItems(at paths: Set<String>) -> ScanResult {
        let remaining = items.filter { !paths.contains($0.path) }
        let duplicateGroups = Dictionary(grouping: remaining.compactMap { item -> (String, ScanItem)? in
            guard let groupID = item.duplicateGroupID else { return nil }
            return (groupID, item)
        }, by: { $0.0 })
        let updatedItems = remaining.compactMap { item -> ScanItem? in
            var categories = item.categories
            if let groupID = item.duplicateGroupID,
               let members = duplicateGroups[groupID], members.count > 1 {
                let keepPath = members.map { $0.1 }.sorted(by: { lhs, rhs in
                    duplicateKeepPreference.ranksBefore(
                        lhs.identity.modifiedAt,
                        path: lhs.path,
                        rhs.identity.modifiedAt,
                        path: rhs.path
                    )
                }).first?.path
                if !categories.contains(.exactDuplicate) { categories.append(.exactDuplicate) }
                return ScanItem(
                    path: item.path,
                    identity: item.identity,
                    lastAccessedAt: item.lastAccessedAt,
                    isCloudManaged: item.isCloudManaged,
                    categories: categories,
                    reasons: item.reasons.filter { !$0.hasPrefix("Byte-for-byte match in a group of ") }
                        + ["Byte-for-byte match in a group of \(members.count). Suggested keep: \(keepPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "one copy")."],
                    safetyNote: item.safetyNote,
                    confidence: item.confidence,
                    duplicateGroupID: groupID,
                    duplicateGroupCount: members.count,
                    suggestedKeepPath: keepPath,
                    cacheReviewDetails: item.cacheReviewDetails
                )
            }

            categories.removeAll { $0 == .exactDuplicate }
            guard !categories.isEmpty else { return nil }
            let confidence: Double
            if categories.contains(.aiCacheCandidate) {
                confidence = 0.75
            } else if categories.contains(.cacheCandidate) {
                confidence = 0.60
            } else {
                confidence = 0.25
            }
            return ScanItem(
                path: item.path,
                identity: item.identity,
                lastAccessedAt: item.lastAccessedAt,
                isCloudManaged: item.isCloudManaged,
                categories: categories,
                reasons: item.reasons.filter { !$0.hasPrefix("Byte-for-byte match in a group of ") },
                safetyNote: item.safetyNote,
                confidence: confidence,
                duplicateGroupID: nil,
                duplicateGroupCount: 0,
                suggestedKeepPath: nil,
                cacheReviewDetails: item.cacheReviewDetails
            )
        }
        return ScanResult(
            kind: kind,
            rootPath: rootPath,
            filesVisited: filesVisited,
            entriesVisited: entriesVisited,
            entryLimit: entryLimit,
            bytesVisited: bytesVisited,
            skippedItems: skippedItems,
            skippedLocations: skippedLocations,
            cloudFilesNotLocallyAvailable: cloudFilesNotLocallyAvailable,
            cloudFilesLocallyAvailable: cloudFilesLocallyAvailable,
            cloudDesktopAccessUnavailable: cloudDesktopAccessUnavailable,
            excludedLocations: excludedLocations,
            items: updatedItems,
            finishedAt: finishedAt,
            wasTruncated: wasTruncated,
            space: paths.isEmpty ? space : nil,
            duplicateKeepPreference: duplicateKeepPreference
        )
    }
}

/// Stores the latest full-disk review locally so a long scan remains available
/// after Mac Cleaner closes or updates. The file contains paths and scan
/// metadata only; it never contains file contents.
struct ScanResultStore: Sendable {
    static let maximumFileSize = 256 * 1_024 * 1_024

    private let directoryURL: URL
    private let fileURL: URL
    private let legacyFileURL: URL?

    init(directoryURL: URL? = nil, legacyFileURL: URL? = nil) {
        let usesDefaultDirectory = directoryURL == nil
        let appSupportURL = directoryURL ?? (FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("com.manateek1.MacCleaner", isDirectory: true)
        self.directoryURL = appSupportURL
        self.fileURL = appSupportURL.appendingPathComponent("latest-full-disk-review.plist")
        self.legacyFileURL = legacyFileURL ?? (usesDefaultDirectory
            ? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Containers/com.manateek1.MacCleaner/Data/Library/Application Support/com.manateek1.MacCleaner/latest-full-disk-review.plist")
            : nil)
    }

    var hasSavedResult: Bool {
        readableFileURL != nil
    }

    func load() throws -> ScanResult? {
        guard let sourceURL = readableFileURL else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let storedSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard storedSize > 0, storedSize <= Self.maximumFileSize else {
            throw ScanResultStoreError.invalidFileSize
        }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumFileSize else {
            throw ScanResultStoreError.invalidFileSize
        }
        let envelope = try PropertyListDecoder().decode(SavedScanResultEnvelope.self, from: data)
        guard envelope.version == SavedScanResultEnvelope.currentVersion,
              envelope.result.rootPath == "/" else {
            throw ScanResultStoreError.unsupportedSavedResult
        }
        return envelope.result
    }

    func save(_ result: ScanResult) throws {
        guard result.rootPath == "/" else { throw ScanResultStoreError.fullDiskResultsOnly }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(SavedScanResultEnvelope(version: SavedScanResultEnvelope.currentVersion, result: result))
        guard data.count <= Self.maximumFileSize else { throw ScanResultStoreError.resultTooLarge }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() throws {
        for url in [fileURL, legacyFileURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private var readableFileURL: URL? {
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        guard let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) else { return nil }
        return legacyFileURL
    }
}

private struct SavedScanResultEnvelope: Codable {
    static let currentVersion = 1
    let version: Int
    let result: ScanResult
}

enum ScanResultStoreError: LocalizedError {
    case fullDiskResultsOnly
    case invalidFileSize
    case resultTooLarge
    case unsupportedSavedResult

    var errorDescription: String? {
        switch self {
        case .fullDiskResultsOnly:
            "Only full-disk scan reviews can be saved as the latest Mac review."
        case .invalidFileSize:
            "The saved scan review is empty or larger than Mac Cleaner supports."
        case .resultTooLarge:
            "This scan found too many items to keep in one saved review. It is still available until Mac Cleaner closes."
        case .unsupportedSavedResult:
            "The saved scan review is from an unsupported format or scope."
        }
    }
}

struct ScanRequest: Sendable {
    let root: URL
    let kind: ScanKind
    let minimumFileSizeBytes: Int64
    let oldFileAgeDays: Int
    let scanEntireDisk: Bool
    let excludedPaths: Set<String>
    let duplicateKeepPreference: DuplicateKeepPreference

    init(
        root: URL,
        kind: ScanKind,
        minimumFileSizeBytes: Int64,
        oldFileAgeDays: Int,
        scanEntireDisk: Bool = false,
        excludedPaths: Set<String> = [],
        duplicateKeepPreference: DuplicateKeepPreference = .oldest
    ) {
        self.root = root
        self.kind = kind
        self.minimumFileSizeBytes = minimumFileSizeBytes
        self.oldFileAgeDays = oldFileAgeDays
        self.scanEntireDisk = scanEntireDisk
        self.excludedPaths = excludedPaths
        self.duplicateKeepPreference = duplicateKeepPreference
    }
}

enum ActivityKind: String, Codable, Sendable {
    case scan
    case cleanup
    case updateCheck
    case securityCheck
    case other

    static func inferredLegacyKind(from title: String) -> ActivityKind {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "scan completed" || normalized.hasSuffix(" scan completed") {
            return .scan
        }
        if normalized == "cleanup reviewed"
            || normalized == "similar photos reviewed"
            || normalized == "photos reviewed"
            || normalized.contains("moved to trash") {
            return .cleanup
        }
        if normalized == "app update source checked" {
            return .updateCheck
        }
        if normalized.hasPrefix("app security check") {
            return .securityCheck
        }
        return .other
    }
}

struct ActivityEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let filesReviewed: Int
    let bytesAffected: Int64
    let note: String
    let kind: ActivityKind

    var itemCountLabel: String {
        if kind == .securityCheck {
            return "\(filesReviewed.formatted()) \(filesReviewed == 1 ? "app" : "apps") checked"
        }
        return "\(filesReviewed.formatted()) \(filesReviewed == 1 ? "item" : "items")"
    }

    init(
        id: UUID,
        date: Date,
        title: String,
        filesReviewed: Int,
        bytesAffected: Int64,
        note: String,
        kind: ActivityKind = .other
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.filesReviewed = filesReviewed
        self.bytesAffected = bytesAffected
        self.note = note
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, title, filesReviewed, bytesAffected, note, kind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        title = try values.decode(String.self, forKey: .title)
        filesReviewed = try values.decode(Int.self, forKey: .filesReviewed)
        bytesAffected = try values.decode(Int64.self, forKey: .bytesAffected)
        note = try values.decode(String.self, forKey: .note)
        kind = try values.decodeIfPresent(ActivityKind.self, forKey: .kind)
            ?? ActivityKind.inferredLegacyKind(from: title)
    }
}

extension Int64 {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
