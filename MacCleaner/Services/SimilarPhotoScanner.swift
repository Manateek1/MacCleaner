import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

struct SimilarPhoto: Identifiable, Sendable {
    let path: String
    let identity: FileIdentity
    let width: Int
    let height: Int
    let hash: UInt64
    let average: UInt8
    let pixels: [UInt8]
    var colorPixels: [UInt8] = []
    var byteDigest: String? = nil
    let createdAt: Date?
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var fileName: String { url.lastPathComponent }
    var scanItem: ScanItem {
        ScanItem(path: path, identity: identity, lastAccessedAt: nil, isCloudManaged: nil, categories: [.oldFile], reasons: ["Visually similar photo; review before removal."], safetyNote: "Personal photo", confidence: 0, duplicateGroupID: nil, duplicateGroupCount: 0, suggestedKeepPath: nil, cacheReviewDetails: nil)
    }
}

struct SimilarPhotoGroup: Identifiable, Sendable {
    let photos: [SimilarPhoto]
    var id: String { photos[0].path }
    var matchKind: SimilarPhotoMatchKind {
        let digests = photos.compactMap(\.byteDigest)
        if digests.count == photos.count, Set(digests).count == 1 { return .exactCopies }
        if Dictionary(grouping: digests, by: { $0 }).values.contains(where: { $0.count > 1 }) { return .visualMatchesWithExactCopies }
        return .visualMatches
    }
    var title: String {
        switch matchKind {
        case .exactCopies: "Byte-identical copies"
        case .visualMatches: "Visually similar photos"
        case .visualMatchesWithExactCopies: "Visually similar · includes exact copies"
        }
    }
    var explanation: String {
        switch matchKind {
        case .exactCopies: "These files have identical contents. Keep the copy you prefer."
        case .visualMatches: "These pictures look alike, but they may show different moments. Compare them before deciding."
        case .visualMatchesWithExactCopies: "Some files are byte-identical; the rest only look alike. Compare each photo before deciding."
        }
    }
    var suggestedKeep: String? {
        photos.sorted { lhs, rhs in
            let pixelsA = Int64(lhs.width) * Int64(lhs.height), pixelsB = Int64(rhs.width) * Int64(rhs.height)
            if pixelsA != pixelsB { return pixelsA > pixelsB }
            if lhs.identity.size != rhs.identity.size { return lhs.identity.size > rhs.identity.size }
            if lhs.identity.modifiedAt != rhs.identity.modifiedAt { return lhs.identity.modifiedAt < rhs.identity.modifiedAt }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }.first?.path
    }
}

enum SimilarPhotoMatchKind: Equatable, Sendable {
    case exactCopies
    case visualMatches
    case visualMatchesWithExactCopies
}

struct SimilarPhotoScanProgress: Sendable {
    let stage: String
    let photosInspected: Int
    let filesHashed: Int
    var bytesHashed: Int64 = 0
}

struct SimilarPhotoScanResult: Sendable {
    let groups: [SimilarPhotoGroup]
    let inspected: Int
    let skipped: Int
    let truncated: Bool
    let exactVerificationLimited: Bool

    init(groups: [SimilarPhotoGroup], inspected: Int, skipped: Int, truncated: Bool, exactVerificationLimited: Bool = false) {
        self.groups = groups
        self.inspected = inspected
        self.skipped = skipped
        self.truncated = truncated
        self.exactVerificationLimited = exactVerificationLimited
    }
}

enum SimilarPhotoSafety {
    static func hasUnchangedSurvivors(groups: [SimilarPhotoGroup], selected: Set<String>, root: URL) -> Bool {
        groups.allSatisfy { group in
            !group.photos.contains(where: { selected.contains($0.path) }) || group.photos.contains { photo in
                guard !selected.contains(photo.path) else { return false }
                if case .allowed = SafeFilePolicy.assess(photo.scanItem, inside: root) { return true }
                return false
            }
        }
    }
}

struct SimilarPhotoScanner: Sendable {
    private let extensions = ImageIOPhotoTypePolicy.supportedExtensions
    private let maximumImageDataBytes: Int64 = 256 * 1024 * 1024
    private let maximumExactHashBytes: Int64
    let maximumPhotos: Int
    let accountHome: URL
    init(maximumPhotos: Int = 10_000, accountHome: URL = SafeFilePolicy.accountHome, maximumExactHashBytes: Int64 = 4_000_000_000) {
        self.maximumPhotos = max(1, maximumPhotos)
        self.accountHome = accountHome.standardizedFileURL
        self.maximumExactHashBytes = max(0, maximumExactHashBytes)
    }

    func scan(root: URL, maximumDistance: Int, scanEntireDisk: Bool? = nil, progress: @escaping @Sendable (SimilarPhotoScanProgress) -> Void) throws -> SimilarPhotoScanResult {
        guard let canonicalRootPath = SafeFileAccess.canonicalDirectoryPath(root.standardizedFileURL.path) else {
            throw PhotoScanError.invalidFolder
        }
        let root = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
        let diskScan = scanEntireDisk ?? (root.path == "/")
        guard !SafeFilePolicy.isEssentialSystemLocation(root.path), !SafeFilePolicy.containsProtectedPathComponent(root.path), !SafeFilePolicy.isInsideDevelopmentRepository(root.path, homeDirectory: accountHome) else { throw PhotoScanError.protectedFolder }
        progress(SimilarPhotoScanProgress(stage: "Finding photos", photosInspected: 0, filesHashed: 0))
        var rootInfo = Darwin.stat()
        guard root.path.withCString({ Darwin.lstat($0, &rootInfo) }) == 0, rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PhotoScanError.invalidFolder }
        var skipped = 0
        let home = accountHome
        let cloudDesktopRoot = ICloudDesktopPolicy.iCloudDesktopRoot(accountHome: home)
        var didSkipCloudDesktop = false
        let roots: [URL]
        if diskScan {
            let preferred = ["Pictures", "Desktop", "Downloads", "Documents"].map { home.appendingPathComponent($0, isDirectory: true) }
            let systemRoots: Set<String> = ["System", "private", "dev", "Volumes", "Library", "Applications", "usr", "bin", "sbin", "opt"]
            let other = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { !systemRoots.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
            roots = preferred + [home] + other
        } else {
            roots = [root]
        }
        var photos: [SimilarPhoto] = []
        var inspected = 0
        var truncated = false
        var visitedDirectories = Set<String>()
        var visitedFiles = Set<String>()
        for scanRoot in roots {
            try Task.checkCancellation()
            if let cloudDesktopRoot, ICloudDesktopPolicy.contains(scanRoot, inside: cloudDesktopRoot) {
                if !didSkipCloudDesktop { skipped += 1; didSkipCloudDesktop = true }
                continue
            }
            var rootStat = Darwin.stat()
            guard scanRoot.path.withCString({ Darwin.lstat($0, &rootStat) }) == 0, rootStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
            guard SafeFilePolicy.isInside(scanRoot.path, root: root.path) || scanRoot.path == root.path else { continue }
            guard !SafeFilePolicy.shouldSkipDirectory(scanRoot.path, homeDirectory: home), !SafeFilePolicy.isInsideDevelopmentRepository(scanRoot.path, homeDirectory: home) else { continue }
            let rootKey = "\(rootStat.st_dev):\(rootStat.st_ino)"
            guard visitedDirectories.insert(rootKey).inserted else { continue }
            guard let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in skipped += 1; return true }) else { skipped += 1; continue }
            while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            var stat = Darwin.stat()
            guard url.path.withCString({ Darwin.lstat($0, &stat) }) == 0 else { skipped += 1; continue }
            let mode = stat.st_mode & mode_t(S_IFMT)
            if mode == mode_t(S_IFLNK) { enumerator.skipDescendants(); continue }
            if mode == mode_t(S_IFDIR) {
                let directoryKey = "\(stat.st_dev):\(stat.st_ino)"
                if let cloudDesktopRoot, ICloudDesktopPolicy.contains(url, inside: cloudDesktopRoot) {
                    if !didSkipCloudDesktop { skipped += 1; didSkipCloudDesktop = true }
                    enumerator.skipDescendants()
                } else if !visitedDirectories.insert(directoryKey).inserted || SafeFilePolicy.shouldSkipDirectory(url.path, homeDirectory: home) || (diskScan && url.standardizedFileURL.path == home.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard mode == mode_t(S_IFREG), extensions.contains(url.pathExtension.lowercased()), !SafeFilePolicy.containsProtectedPathComponent(url.path) else { continue }
            guard visitedFiles.insert("\(stat.st_dev):\(stat.st_ino)").inserted else { continue }
            if inspected >= maximumPhotos { truncated = true; break }
            inspected += 1
            if inspected.isMultiple(of: 32) {
                progress(SimilarPhotoScanProgress(stage: "Finding photos", photosInspected: inspected, filesHashed: 0))
            }
            let identity = FileIdentity(device: UInt64(stat.st_dev), inode: UInt64(stat.st_ino), size: Int64(stat.st_size), modifiedAt: TimeInterval(stat.st_mtimespec.tv_sec) + TimeInterval(stat.st_mtimespec.tv_nsec) / 1_000_000_000, linkCount: UInt32(stat.st_nlink))
            if let photo = autoreleasepool(invoking: { fingerprint(url: url, identity: identity) }) {
                var after = Darwin.stat()
                let unchanged = url.path.withCString { Darwin.lstat($0, &after) } == 0
                    && after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                    && UInt64(after.st_dev) == identity.device && UInt64(after.st_ino) == identity.inode
                    && Int64(after.st_size) == identity.size
                    && TimeInterval(after.st_mtimespec.tv_sec) + TimeInterval(after.st_mtimespec.tv_nsec) / 1_000_000_000 == identity.modifiedAt
                if unchanged { photos.append(photo) } else { skipped += 1 }
            } else { skipped += 1 }
            }
            if truncated { break }
        }
        try Task.checkCancellation()
        progress(SimilarPhotoScanProgress(stage: "Checking exact copies", photosInspected: inspected, filesHashed: 0))
        let exactHashes = try exactContentHashes(photos, progress: progress)
        for index in photos.indices { photos[index].byteDigest = exactHashes.digests[photos[index].path] }
        return SimilarPhotoScanResult(
            groups: try Self.group(photos, maximumDistance: maximumDistance),
            inspected: inspected,
            skipped: skipped + exactHashes.skipped,
            truncated: truncated,
            exactVerificationLimited: exactHashes.limited
        )
    }

    private func exactContentHashes(
        _ photos: [SimilarPhoto],
        progress: @escaping @Sendable (SimilarPhotoScanProgress) -> Void
    ) throws -> (digests: [String: String], limited: Bool, skipped: Int) {
        let sizeGroups = Dictionary(grouping: photos.indices, by: { photos[$0].identity.size })
        var partialGroups: [String: [Int]] = [:]
        var partialFilesChecked = 0
        var skipped = 0

        for indices in sizeGroups.values where indices.count > 1 {
            try Task.checkCancellation()
            for index in indices {
                try Task.checkCancellation()
                let photo = photos[index]
                guard currentIdentity(photo.path) == photo.identity,
                      let partial = try contentDigest(path: photo.path, expected: photo.identity, partial: true),
                      currentIdentity(photo.path) == photo.identity else {
                    skipped += 1
                    continue
                }
                partialGroups[partial, default: []].append(index)
                partialFilesChecked += 1
                if partialFilesChecked.isMultiple(of: 32) {
                    progress(SimilarPhotoScanProgress(
                        stage: "Finding exact-copy candidates",
                        photosInspected: photos.count,
                        filesHashed: 0
                    ))
                }
            }
        }

        var fullDigests: [String: String] = [:]
        var fullFilesChecked = 0
        var fullHashBytes: Int64 = 0
        var limited = false
        for indices in partialGroups.values where indices.count > 1 {
            try Task.checkCancellation()
            for index in indices {
                try Task.checkCancellation()
                let photo = photos[index]
                let size = photo.identity.size
                guard size > 0 else { continue }
                guard size <= maximumExactHashBytes - fullHashBytes else {
                    limited = true
                    continue
                }
                guard currentIdentity(photo.path) == photo.identity,
                      let digest = try contentDigest(path: photo.path, expected: photo.identity, partial: false, onProgress: { processed in
                          progress(SimilarPhotoScanProgress(
                              stage: "Verifying exact copies · \(processed.formattedByteCount)",
                              photosInspected: photos.count,
                              filesHashed: fullFilesChecked,
                              bytesHashed: fullHashBytes + processed
                          ))
                      }),
                      currentIdentity(photo.path) == photo.identity else {
                    skipped += 1
                    continue
                }
                fullDigests[photo.path] = digest
                fullHashBytes += size
                fullFilesChecked += 1
                progress(SimilarPhotoScanProgress(
                    stage: "Verifying exact copies",
                    photosInspected: photos.count,
                    filesHashed: fullFilesChecked,
                    bytesHashed: fullHashBytes
                ))
            }
        }
        return (fullDigests, limited, skipped)
    }

    private func contentDigest(
        path: String,
        expected: FileIdentity,
        partial: Bool,
        onProgress: ((Int64) -> Void)? = nil
    ) throws -> String? {
        guard let fileDescriptor = SafeFileAccess.openRegularFileDescriptor(path) else { return nil }
        var openedInfo = Darwin.stat()
        guard Darwin.fstat(fileDescriptor, &openedInfo) == 0,
              Self.fileIdentity(openedInfo) == expected else {
            Darwin.close(fileDescriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            let size = expected.size
            let sampleSize = 64 * 1024
            if partial {
                var payload = try handle.read(upToCount: sampleSize) ?? Data()
                if size > Int64(sampleSize * 2) {
                    try handle.seek(toOffset: UInt64(size - Int64(sampleSize)))
                    payload.append(try handle.read(upToCount: sampleSize) ?? Data())
                }
                try Task.checkCancellation()
                return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            }

            var hasher = SHA256()
            var processed: Int64 = 0
            var nextUpdate: Int64 = 64 * 1024 * 1024
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                processed += Int64(chunk.count)
                if processed >= nextUpdate {
                    onProgress?(processed)
                    nextUpdate = processed + 64 * 1024 * 1024
                }
            }
            try Task.checkCancellation()
            guard processed == size else { return nil }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func currentIdentity(_ path: String) -> FileIdentity? {
        SafeFileAccess.identity(at: path)
    }

    private static func fileIdentity(_ info: Darwin.stat) -> FileIdentity {
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            linkCount: UInt32(info.st_nlink)
        )
    }

    private func fingerprint(url: URL, identity: FileIdentity) -> SimilarPhoto? {
        guard identity.size > 0, identity.size <= maximumImageDataBytes,
              let descriptor = SafeFileAccess.openRegularFileDescriptor(url.path) else { return nil }
        defer { Darwin.close(descriptor) }
        guard let imageData = Self.readData(from: descriptor, size: identity.size) else { return nil }
        var openedInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              Self.fileIdentity(openedInfo) == identity,
              let source = CGImageSourceCreateWithData(imageData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) else { return nil }
        let creationDate = Date(timeIntervalSince1970: TimeInterval(openedInfo.st_birthtimespec.tv_sec) + TimeInterval(openedInfo.st_birthtimespec.tv_nsec) / 1_000_000_000)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsDimensions = (5...8).contains(orientation)
        guard let fingerprint = VisualPhotoFingerprinting.make(
            image: image,
            identifier: url.path,
            width: swapsDimensions ? height : width,
            height: swapsDimensions ? width : height,
            duplicateIdentity: "\(identity.device):\(identity.inode)",
            createdAt: creationDate
        ) else { return nil }
        return SimilarPhoto(
            path: url.path,
            identity: identity,
            width: fingerprint.width,
            height: fingerprint.height,
            hash: fingerprint.hash,
            average: fingerprint.average,
            pixels: fingerprint.pixels,
            colorPixels: fingerprint.colorPixels,
            createdAt: fingerprint.createdAt
        )
    }

    private static func readData(from descriptor: Int32, size: Int64) -> Data? {
        guard size > 0, size <= Int64(Int.max) else { return nil }
        let byteCount = Int(size)
        var data = Data(count: byteCount)
        let wasReadCompletely = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < byteCount {
                let amount = min(1_048_576, byteCount - offset)
                let count = Darwin.pread(descriptor, baseAddress.advanced(by: offset), amount, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            var extraByte: UInt8 = 0
            let extraCount = withUnsafeMutablePointer(to: &extraByte) {
                Darwin.pread(descriptor, $0, 1, off_t(byteCount))
            }
            return extraCount == 0
        }
        return wasReadCompletely ? data : nil
    }

    static func group(_ photos: [SimilarPhoto], maximumDistance: Int) throws -> [SimilarPhotoGroup] {
        let fingerprints = photos.map { photo in
            VisualPhotoFingerprint(
                identifier: photo.path,
                width: photo.width,
                height: photo.height,
                hash: photo.hash,
                average: photo.average,
                pixels: photo.pixels,
                colorPixels: photo.colorPixels,
                duplicateIdentity: "\(photo.identity.device):\(photo.identity.inode)",
                createdAt: photo.createdAt
            )
        }
        let byPath = Dictionary(uniqueKeysWithValues: photos.map { ($0.path, $0) })
        return try VisualPhotoMatcher.groups(fingerprints, maximumDistance: maximumDistance).map { group in
            SimilarPhotoGroup(photos: group.compactMap { byPath[$0.identifier] })
        }
    }
}

enum PhotoScanError: LocalizedError {
    case protectedFolder, invalidFolder, unreadableFolder
    var errorDescription: String? {
        switch self {
        case .protectedFolder: "This location is protected from scanning."
        case .invalidFolder: "The selected location is not an accessible folder."
        case .unreadableFolder: "The folder could not be read. Check access in System Settings."
        }
    }
}
