import Darwin
import Foundation

enum LocalAIModelProvider: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case huggingFace
    case lmStudio
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: "Ollama"
        case .huggingFace: "Hugging Face cache"
        case .lmStudio: "LM Studio"
        case .other: "Other model file"
        }
    }

    var symbol: String {
        switch self {
        case .ollama: "shippingbox"
        case .huggingFace: "face.smiling"
        case .lmStudio: "cpu"
        case .other: "doc.zipper"
        }
    }

    func defaultDirectory(home: URL) -> URL {
        switch self {
        case .ollama:
            home.appendingPathComponent(".ollama/models", isDirectory: true)
        case .huggingFace:
            home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        case .lmStudio:
            home.appendingPathComponent(".lmstudio/models", isDirectory: true)
        case .other:
            home
        }
    }
}

enum LocalAIModelNodeType: Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

struct LocalAIModelNodeIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedAt: TimeInterval
    let linkCount: UInt32
    let type: LocalAIModelNodeType
}

struct LocalAIModelTargetSnapshot: Equatable, Sendable {
    let path: String
    let identity: LocalAIModelNodeIdentity
}

enum LocalAIModelRemovalTarget: Equatable, Sendable {
    case ollamaManifest(manifest: LocalAIModelTargetSnapshot, blobs: [LocalAIModelTargetSnapshot])
    case huggingFaceRepository(root: LocalAIModelTargetSnapshot, modelFiles: [LocalAIModelTargetSnapshot])
    case lmStudioDirectory(root: LocalAIModelTargetSnapshot, files: [LocalAIModelTargetSnapshot])
    case modelFiles([LocalAIModelTargetSnapshot])
}

struct LocalAIModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let provider: LocalAIModelProvider
    let path: String
    let sizeBytes: Int64
    let fileCount: Int
    let modifiedAt: Date?
    let removalTarget: LocalAIModelRemovalTarget?

    var url: URL { URL(fileURLWithPath: path) }
}

struct LocalAIModelInventory: Sendable {
    let models: [LocalAIModel]
    let checkedLocations: [String]
    let uniqueBytes: Int64
    let skippedLocations: Int
    let wasLimited: Bool
    let wasCancelled: Bool
}

struct LocalAIModelInventoryService: Sendable {
    private let homeDirectory: URL
    private let maximumEntries: Int
    private let maximumManifestBytes: Int64 = 1_000_000

    static let modelWeightExtensions: Set<String> = [
        "gguf", "ggml", "safetensors", "bin", "pt", "pth", "onnx", "model"
    ]
    private static let definiteModelExtensions: Set<String> = ["gguf", "ggml", "safetensors"]

    init(homeDirectory: URL = SafeFilePolicy.accountHome, maximumEntries: Int = 100_000) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
    }

    func scan() -> LocalAIModelInventory {
        let counters = Counters(maximumEntries: maximumEntries)
        var models: [LocalAIModel] = []
        var checkedLocations: [String] = []
        var uniqueFiles: [String: Int64] = [:]

        for provider in LocalAIModelProvider.allCases where provider != .other {
            guard counters.canContinue else { break }
            let root = provider.defaultDirectory(home: homeDirectory).standardizedFileURL
            guard isSafeDirectory(root, boundedBy: homeDirectory) else { continue }
            checkedLocations.append(root.path)

            switch provider {
            case .ollama:
                models += scanOllama(at: root, counters: counters, uniqueFiles: &uniqueFiles)
            case .huggingFace:
                models += scanHuggingFace(at: root, counters: counters, uniqueFiles: &uniqueFiles)
            case .lmStudio:
                models += scanLMStudio(at: root, counters: counters, uniqueFiles: &uniqueFiles)
            case .other:
                continue
            }
        }
        models += scanOtherModelFiles(under: homeDirectory, counters: counters, uniqueFiles: &uniqueFiles)
        if isSafeDirectory(homeDirectory, boundedBy: homeDirectory) {
            checkedLocations.append(homeDirectory.path)
        }

        return LocalAIModelInventory(
            models: models.sorted {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            checkedLocations: checkedLocations,
            uniqueBytes: uniqueFiles.values.reduce(0, Self.saturatingAdd),
            skippedLocations: counters.skippedLocations,
            wasLimited: counters.wasLimited,
            wasCancelled: counters.wasCancelled
        )
    }

    private func scanOllama(
        at modelsRoot: URL,
        counters: Counters,
        uniqueFiles: inout [String: Int64]
    ) -> [LocalAIModel] {
        let manifestRoot = modelsRoot.appendingPathComponent("manifests", isDirectory: true)
        let blobRoot = modelsRoot.appendingPathComponent("blobs", isDirectory: true)
        guard isSafeDirectory(manifestRoot, boundedBy: modelsRoot),
              isSafeDirectory(blobRoot, boundedBy: modelsRoot) else { return [] }

        let manifests = regularFiles(under: manifestRoot, boundedBy: manifestRoot, counters: counters)
        var result: [LocalAIModel] = []

        for manifest in manifests {
            guard counters.canContinue else { break }
            guard let manifestInfo = fileInfo(manifest), manifestInfo.size <= maximumManifestBytes,
                  let data = try? Data(contentsOf: manifest, options: [.mappedIfSafe]),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = object["layers"] as? [[String: Any]],
                  let name = ollamaModelName(manifest, relativeTo: manifestRoot) else {
                counters.skip()
                continue
            }

            var modelFiles: [String: Int64] = [:]
            var modelBlobs: [String: LocalAIModelTargetSnapshot] = [:]
            var modifiedAt: Date?
            for layer in layers {
                guard counters.canContinue else { break }
                guard let digest = layer["digest"] as? String,
                      let blobName = ollamaBlobName(for: digest) else {
                    counters.skip()
                    continue
                }
                let blob = blobRoot.appendingPathComponent(blobName, isDirectory: false)
                guard let info = fileInfo(blob), isInside(blob.path, root: blobRoot.path) else {
                    counters.skip()
                    continue
                }
                modelFiles[identityKey(info), default: info.size] = info.size
                modelBlobs[blob.path] = LocalAIModelTargetSnapshot(path: blob.path, identity: info.nodeIdentity)
                modifiedAt = max(modifiedAt ?? info.modifiedAt, info.modifiedAt)
                uniqueFiles[identityKey(info), default: info.size] = info.size
            }
            guard !modelFiles.isEmpty else { continue }
            result.append(LocalAIModel(
                id: "ollama:\(name)",
                name: name,
                provider: .ollama,
                path: manifest.path,
                sizeBytes: modelFiles.values.reduce(0, Self.saturatingAdd),
                fileCount: modelFiles.count,
                modifiedAt: modifiedAt,
                removalTarget: .ollamaManifest(
                    manifest: LocalAIModelTargetSnapshot(path: manifest.path, identity: manifestInfo.nodeIdentity),
                    blobs: modelBlobs.values.sorted { $0.path < $1.path }
                )
            ))
        }
        return result
    }

    private func scanHuggingFace(
        at hubRoot: URL,
        counters: Counters,
        uniqueFiles: inout [String: Int64]
    ) -> [LocalAIModel] {
        guard let repositories = directoryChildren(under: hubRoot, counters: counters) else { return [] }
        var result: [LocalAIModel] = []

        for repository in repositories where repository.lastPathComponent.hasPrefix("models--") {
            guard counters.canContinue,
                  isSafeDirectory(repository, boundedBy: hubRoot) else { continue }
            let modelName = String(repository.lastPathComponent.dropFirst("models--".count))
                .replacingOccurrences(of: "--", with: "/")
            guard !modelName.isEmpty else { counters.skip(); continue }

            var modelFiles: [String: Int64] = [:]
            var modelFileSnapshots: [String: LocalAIModelTargetSnapshot] = [:]
            var modifiedAt: Date?
            let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
            if isSafeDirectory(blobs, boundedBy: repository),
               let entries = directoryChildren(under: blobs, counters: counters, allowFileSymlinks: true, symlinkBoundary: hubRoot) {
                for entry in entries {
                    guard counters.canContinue else { break }
                    guard let info = fileInfoFollowingSafeLink(entry, boundedBy: hubRoot) else {
                        counters.skip()
                        continue
                    }
                    let key = identityKey(info)
                    modelFiles[key] = info.size
                    let contentURL = entry.resolvingSymlinksInPath().standardizedFileURL
                    modelFileSnapshots[key] = LocalAIModelTargetSnapshot(path: contentURL.path, identity: info.nodeIdentity)
                    uniqueFiles[key] = info.size
                    modifiedAt = max(modifiedAt ?? info.modifiedAt, info.modifiedAt)
                }
            }

            // Older cache layouts may store regular files in snapshots instead of blob symlinks.
            let snapshots = repository.appendingPathComponent("snapshots", isDirectory: true)
            if isSafeDirectory(snapshots, boundedBy: repository) {
                for file in regularFiles(under: snapshots, boundedBy: repository, counters: counters) {
                    guard counters.canContinue, let info = fileInfo(file) else { continue }
                    let key = identityKey(info)
                    modelFiles[key] = info.size
                    modelFileSnapshots[key] = LocalAIModelTargetSnapshot(path: file.path, identity: info.nodeIdentity)
                    uniqueFiles[key] = info.size
                    modifiedAt = max(modifiedAt ?? info.modifiedAt, info.modifiedAt)
                }
            }

            guard !modelFiles.isEmpty else { continue }
            guard let repositoryInfo = lstatInfo(repository), repositoryInfo.isDirectory, !repositoryInfo.isSymbolicLink else {
                counters.skip()
                continue
            }
            result.append(LocalAIModel(
                id: "huggingface:\(repository.path)",
                name: modelName,
                provider: .huggingFace,
                path: repository.path,
                sizeBytes: modelFiles.values.reduce(0, Self.saturatingAdd),
                fileCount: modelFiles.count,
                modifiedAt: modifiedAt,
                removalTarget: .huggingFaceRepository(
                    root: LocalAIModelTargetSnapshot(path: repository.path, identity: repositoryInfo.nodeIdentity),
                    modelFiles: modelFileSnapshots.values.sorted { $0.path < $1.path }
                )
            ))
        }
        return result
    }

    private func scanLMStudio(
        at modelsRoot: URL,
        counters: Counters,
        uniqueFiles: inout [String: Int64]
    ) -> [LocalAIModel] {
        guard let topLevel = directoryChildren(under: modelsRoot, counters: counters) else { return [] }
        var result: [LocalAIModel] = []

        for publisher in topLevel where isSafeDirectory(publisher, boundedBy: modelsRoot) {
            guard counters.canContinue else { break }
            guard let modelDirectories = directoryChildren(under: publisher, counters: counters) else { continue }
            for modelDirectory in modelDirectories where isSafeDirectory(modelDirectory, boundedBy: modelsRoot) {
                guard counters.canContinue else { break }
                let files = regularFiles(under: modelDirectory, boundedBy: modelsRoot, counters: counters)
                let hasWeightFile = files.contains { Self.modelWeightExtensions.contains($0.pathExtension.lowercased()) }
                guard hasWeightFile else { continue }
                let summary = summarize(files, counters: counters, uniqueFiles: &uniqueFiles)
                guard summary.fileCount > 0 else { continue }
                guard let directoryInfo = lstatInfo(modelDirectory), directoryInfo.isDirectory, !directoryInfo.isSymbolicLink else {
                    counters.skip()
                    continue
                }
                result.append(LocalAIModel(
                    id: "lmstudio:\(modelDirectory.path)",
                    name: "\(publisher.lastPathComponent)/\(modelDirectory.lastPathComponent)",
                    provider: .lmStudio,
                    path: modelDirectory.path,
                    sizeBytes: summary.sizeBytes,
                    fileCount: summary.fileCount,
                    modifiedAt: summary.modifiedAt,
                    removalTarget: .lmStudioDirectory(
                        root: LocalAIModelTargetSnapshot(path: modelDirectory.path, identity: directoryInfo.nodeIdentity),
                        files: Dictionary(grouping: files.compactMap { file -> LocalAIModelTargetSnapshot? in
                            guard let info = fileInfo(file) else { return nil }
                            return LocalAIModelTargetSnapshot(path: file.path, identity: info.nodeIdentity)
                        }, by: { "\($0.identity.device):\($0.identity.inode)" })
                            .values.compactMap(\.first).sorted { $0.path < $1.path }
                    )
                ))
            }
        }

        return result
    }

    private func scanOtherModelFiles(
        under root: URL,
        counters: Counters,
        uniqueFiles: inout [String: Int64]
    ) -> [LocalAIModel] {
        guard isSafeDirectory(root, boundedBy: root) else { return [] }
        let excludedProviderRoots = Set(
            [LocalAIModelProvider.ollama, .huggingFace, .lmStudio]
                .map { $0.defaultDirectory(home: homeDirectory).standardizedFileURL.path }
        )
        var modelFilesByDirectory: [String: [(URL, FileInfo)]] = [:]
        var directoriesWithModelMetadata: Set<String> = []
        let metadataNames: Set<String> = [
            "config.json", "tokenizer.json", "generation_config.json",
            "model.safetensors.index.json", "pytorch_model.bin.index.json"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in counters.skip(); return true }
        ) else {
            counters.skip()
            return []
        }

        while let url = enumerator.nextObject() as? URL {
            guard counters.consume() else {
                enumerator.skipDescendants()
                break
            }
            let path = url.standardizedFileURL.path
            guard let info = lstatInfo(url) else {
                counters.skip()
                continue
            }
            if info.isSymbolicLink {
                counters.skip()
                enumerator.skipDescendants()
                continue
            }
            if info.isDirectory {
                let isExcludedProviderRoot = excludedProviderRoots.contains(path)
                let isPackage = Self.modelInventoryPackageExtensions.contains(url.pathExtension.lowercased())
                if isExcludedProviderRoot || isPackage
                    || SafeFilePolicy.isEssentialSystemLocation(path)
                    || SafeFilePolicy.shouldSkipModelInventoryDirectory(path, homeDirectory: homeDirectory)
                    || !isInside(path, root: root.path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard info.isRegularFile,
                  isInside(path, root: root.path),
                  !SafeFilePolicy.isEssentialSystemLocation(path),
                  !SafeFilePolicy.containsProtectedModelInventoryPathComponent(path) else { continue }

            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            let fileName = url.lastPathComponent.lowercased()
            if metadataNames.contains(fileName) {
                directoriesWithModelMetadata.insert(parentPath)
            }
            guard Self.modelWeightExtensions.contains(url.pathExtension.lowercased()) else { continue }
            modelFilesByDirectory[parentPath, default: []].append((url, info))
        }

        let modelDirectoryNames: Set<String> = ["model", "models", "weights", "checkpoints", "llm", "transformers"]
        var result: [LocalAIModel] = []

        for directoryPath in modelFilesByDirectory.keys.sorted() {
            guard counters.canContinue else { break }
            let entries = modelFilesByDirectory[directoryPath] ?? []
            let hasModelMetadata = directoriesWithModelMetadata.contains(directoryPath)
            let directoryIsNamedForModels = URL(fileURLWithPath: directoryPath)
                .pathComponents
                .map { $0.lowercased() }
                .contains(where: modelDirectoryNames.contains)
            let candidates = entries.filter { url, _ in
                Self.definiteModelExtensions.contains(url.pathExtension.lowercased())
                    || hasModelMetadata
                    || directoryIsNamedForModels
            }
            guard !candidates.isEmpty else { continue }

            let uniqueEntries = Dictionary(grouping: candidates, by: { identityKey($0.1) })
                .values
                .compactMap(\.first)
                .sorted { $0.0.path < $1.0.path }
            for (_, info) in uniqueEntries {
                uniqueFiles[identityKey(info), default: info.size] = info.size
            }
            let removalFiles = uniqueEntries.map { url, info in
                LocalAIModelTargetSnapshot(path: url.path, identity: info.nodeIdentity)
            }

            let shouldGroupFolder = uniqueEntries.count > 1
                && (hasModelMetadata || directoryIsNamedForModels)
            if shouldGroupFolder {
                result.append(LocalAIModel(
                    id: "other:\(directoryPath)",
                    name: URL(fileURLWithPath: directoryPath).lastPathComponent,
                    provider: .other,
                    path: directoryPath,
                    sizeBytes: uniqueEntries.reduce(Int64(0)) { Self.saturatingAdd($0, $1.1.size) },
                    fileCount: uniqueEntries.count,
                    modifiedAt: uniqueEntries.map { $0.1.modifiedAt }.max(),
                    removalTarget: .modelFiles(removalFiles)
                ))
            } else {
                for (url, info) in uniqueEntries {
                    result.append(LocalAIModel(
                        id: "other:\(url.path)",
                        name: url.lastPathComponent,
                        provider: .other,
                        path: url.path,
                        sizeBytes: info.size,
                        fileCount: 1,
                        modifiedAt: info.modifiedAt,
                        removalTarget: .modelFiles([
                            LocalAIModelTargetSnapshot(path: url.path, identity: info.nodeIdentity)
                        ])
                    ))
                }
            }
        }
        return result
    }

    private func summarize(
        _ files: [URL],
        counters: Counters,
        uniqueFiles: inout [String: Int64]
    ) -> (sizeBytes: Int64, fileCount: Int, modifiedAt: Date?) {
        var modelFiles: [String: Int64] = [:]
        var modifiedAt: Date?
        for file in files {
            guard counters.canContinue, let info = fileInfo(file) else { continue }
            let key = identityKey(info)
            modelFiles[key] = info.size
            uniqueFiles[key] = info.size
            modifiedAt = max(modifiedAt ?? info.modifiedAt, info.modifiedAt)
        }
        return (modelFiles.values.reduce(0, Self.saturatingAdd), modelFiles.count, modifiedAt)
    }

    private func directoryChildren(
        under directory: URL,
        counters: Counters,
        allowFileSymlinks: Bool = false,
        symlinkBoundary: URL? = nil
    ) -> [URL]? {
        guard isSafeDirectory(directory, boundedBy: homeDirectory) else { return nil }
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            return children.filter { child in
                guard counters.consume() else { return false }
                guard let info = lstatInfo(child) else { counters.skip(); return false }
                if info.isSymbolicLink {
                    guard allowFileSymlinks, !info.isDirectory,
                          fileInfoFollowingSafeLink(child, boundedBy: symlinkBoundary ?? homeDirectory) != nil else {
                        counters.skip()
                        return false
                    }
                }
                return info.isDirectory || info.isRegularFile || info.isSymbolicLink
            }
        } catch {
            counters.skip()
            return nil
        }
    }

    private func regularFiles(under directory: URL, boundedBy boundary: URL, counters: Counters) -> [URL] {
        guard isSafeDirectory(directory, boundedBy: boundary),
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in counters.skip(); return true }
              ) else { return [] }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard counters.consume() else { enumerator.skipDescendants(); break }
            guard let info = lstatInfo(url) else { counters.skip(); continue }
            if info.isSymbolicLink {
                enumerator.skipDescendants()
            } else if info.isRegularFile, isInside(url.path, root: boundary.path) {
                files.append(url)
            }
        }
        return files
    }

    private func fileInfo(_ url: URL) -> FileInfo? {
        guard let info = lstatInfo(url), info.isRegularFile else { return nil }
        return info
    }

    private func fileInfoFollowingSafeLink(_ url: URL, boundedBy boundary: URL) -> FileInfo? {
        guard let linkInfo = lstatInfo(url) else { return nil }
        if linkInfo.isRegularFile { return linkInfo }
        guard linkInfo.isSymbolicLink,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let target = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        guard isInside(target.path, root: boundary.path),
              let targetInfo = lstatInfo(target), targetInfo.isRegularFile else { return nil }
        return targetInfo
    }

    private func isSafeDirectory(_ url: URL, boundedBy boundary: URL) -> Bool {
        let directoryPath = canonicalPath(url.path)
        let rootPath = canonicalPath(boundary.path)
        guard isInside(directoryPath, root: rootPath),
              let directoryInfo = lstatInfo(url.standardizedFileURL), directoryInfo.isDirectory, !directoryInfo.isSymbolicLink,
              let rootInfo = lstatInfo(boundary.standardizedFileURL), rootInfo.isDirectory, !rootInfo.isSymbolicLink else { return false }
        let relative = directoryPath == rootPath
            ? ""
            : String(directoryPath.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
        var cursor = URL(fileURLWithPath: rootPath, isDirectory: true)
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            guard let info = lstatInfo(cursor), info.isDirectory, !info.isSymbolicLink else { return false }
        }
        return true
    }

    private static let modelInventoryPackageExtensions: Set<String> = ["app", "appex", "bundle", "framework", "pkg"]

    private func ollamaModelName(_ manifest: URL, relativeTo root: URL) -> String? {
        let manifestPath = canonicalPath(manifest.path)
        let rootPath = canonicalPath(root.path)
        guard isInside(manifestPath, root: rootPath) else { return nil }
        let relative = String(manifestPath.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard components.count >= 3 else { return nil }
        let tag = components.last!
        var modelComponents = Array(components.dropFirst().dropLast())
        if modelComponents.first == "library" { modelComponents.removeFirst() }
        guard !modelComponents.isEmpty else { return nil }
        return "\(modelComponents.joined(separator: "/")):\(tag)"
    }

    private func ollamaBlobName(for digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "sha256", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit }) else { return nil }
        return "sha256-\(parts[1].lowercased())"
    }

    private func isInside(_ candidate: String, root: String) -> Bool {
        let normalizedCandidate = canonicalPath(candidate)
        let normalizedRoot = canonicalPath(root)
        return normalizedCandidate == normalizedRoot
            || normalizedCandidate.hasPrefix(normalizedRoot == "/" ? "/" : normalizedRoot + "/")
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func identityKey(_ info: FileInfo) -> String {
        "\(info.device):\(info.inode)"
    }

    private func lstatInfo(_ url: URL) -> FileInfo? {
        var value = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0 else { return nil }
        let type = value.st_mode & S_IFMT
        return FileInfo(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: max(0, Int64(value.st_size)),
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                    + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            linkCount: UInt32(value.st_nlink),
            isDirectory: type == S_IFDIR,
            isRegularFile: type == S_IFREG,
            isSymbolicLink: type == S_IFLNK
        )
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private struct FileInfo {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedAt: Date
        let linkCount: UInt32
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymbolicLink: Bool

        var nodeIdentity: LocalAIModelNodeIdentity {
            let type: LocalAIModelNodeType
            if isRegularFile { type = .regularFile }
            else if isDirectory { type = .directory }
            else if isSymbolicLink { type = .symbolicLink }
            else { type = .other }
            return LocalAIModelNodeIdentity(
                device: device,
                inode: inode,
                size: size,
                modifiedAt: modifiedAt.timeIntervalSince1970,
                linkCount: linkCount,
                type: type
            )
        }
    }

    private final class Counters {
        private let maximumEntries: Int
        private(set) var entriesVisited = 0
        private(set) var skippedLocations = 0
        private(set) var wasLimited = false
        private(set) var wasCancelled = false

        init(maximumEntries: Int) { self.maximumEntries = maximumEntries }

        var canContinue: Bool {
            if Task.isCancelled { wasCancelled = true; return false }
            return !wasLimited
        }

        func consume() -> Bool {
            guard canContinue else { return false }
            guard entriesVisited < maximumEntries else { wasLimited = true; return false }
            entriesVisited += 1
            return true
        }

        func skip() { skippedLocations += 1 }
    }
}
