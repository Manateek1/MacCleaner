import Darwin
import Foundation

struct LocalAIModelRemovalFailure: Equatable, Sendable {
    let modelID: String
    let modelName: String
    let reason: String
}

struct LocalAIModelRemovalResult: Sendable {
    let movedModelIDs: [String]
    let filesMoved: Int
    let failures: [LocalAIModelRemovalFailure]
    let bytesMoved: Int64
    let sharedModelDataRetained: Bool
}

struct LocalAIModelRemovalService: Sendable {
    private let homeDirectory: URL
    private let maximumEntries: Int
    private let maximumManifestBytes: Int64 = 1_000_000
    private let trashOperation: @Sendable (URL) throws -> Void

    init(
        homeDirectory: URL = SafeFilePolicy.accountHome,
        maximumEntries: Int = 100_000,
        trashOperation: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.trashOperation = trashOperation
    }

    func moveToTrash(_ models: [LocalAIModel]) -> LocalAIModelRemovalResult {
        let selectedModels = Dictionary(grouping: models, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.id < $1.id }
        var directPlans: [ModelMovePlan] = []
        var ollamaCandidates: [ValidatedOllamaModel] = []
        var failures: [LocalAIModelRemovalFailure] = []

        for model in selectedModels {
            guard let target = model.removalTarget else {
                failures.append(failure(model, "This model does not have a supported cleanup action."))
                continue
            }

            do {
                switch target {
                case .modelFiles(let snapshots):
                    directPlans.append(try prepareCustomModel(model, snapshots: snapshots))
                case .huggingFaceRepository(let root, let modelFiles):
                    directPlans.append(try prepareHuggingFaceModel(model, root: root, modelFiles: modelFiles))
                case .lmStudioDirectory(let root, let files):
                    directPlans.append(try prepareLMStudioModel(model, root: root, files: files))
                case .ollamaManifest(let manifest, let blobs):
                    ollamaCandidates.append(try prepareOllamaModel(model, manifest: manifest, blobs: blobs))
                }
            } catch {
                failures.append(failure(model, error.localizedDescription))
            }
        }

        var movedModelIDs: Set<String> = []
        var filesMoved = 0
        var bytesMoved: Int64 = 0
        var sharedModelDataRetained = false

        for plan in directPlans {
            var movedAny = false
            for item in plan.items {
                guard isCurrent(item.snapshot, rootedAt: homeDirectory),
                      item.additionalSnapshots.allSatisfy({ isCurrent($0, rootedAt: homeDirectory) }) else {
                    failures.append(failure(plan.model, "This model changed after the scan. Refresh and review it again."))
                    continue
                }
                if let allowInternalFileSymlinks = item.allowInternalFileSymlinks {
                    do {
                        _ = try inspectManagedDirectory(
                            URL(fileURLWithPath: item.snapshot.path),
                            expectedRootIdentity: item.snapshot.identity,
                            allowInternalFileSymlinks: allowInternalFileSymlinks
                        )
                    } catch {
                        failures.append(failure(plan.model, error.localizedDescription))
                        continue
                    }
                }
                do {
                    try trashOperation(URL(fileURLWithPath: item.snapshot.path))
                    movedAny = true
                    filesMoved += 1
                    bytesMoved = Self.saturatingAdd(bytesMoved, item.bytes)
                } catch {
                    failures.append(failure(plan.model, "macOS could not move this model item to Trash."))
                }
            }
            if movedAny { movedModelIDs.insert(plan.model.id) }
        }

        let successfullyRemovedOllama = moveOllamaManifests(
            ollamaCandidates,
            failures: &failures,
            movedModelIDs: &movedModelIDs,
            filesMoved: &filesMoved
        )
        if !successfullyRemovedOllama.isEmpty {
            let blobMove = moveUnreferencedOllamaBlobs(successfullyRemovedOllama, failures: &failures)
            filesMoved += blobMove.filesMoved
            bytesMoved = Self.saturatingAdd(bytesMoved, blobMove.bytesMoved)
            sharedModelDataRetained = blobMove.sharedDataRetained
        }

        return LocalAIModelRemovalResult(
            movedModelIDs: movedModelIDs.sorted(),
            filesMoved: filesMoved,
            failures: failures,
            bytesMoved: bytesMoved,
            sharedModelDataRetained: sharedModelDataRetained
        )
    }

    private func prepareCustomModel(
        _ model: LocalAIModel,
        snapshots: [LocalAIModelTargetSnapshot]
    ) throws -> ModelMovePlan {
        guard model.provider == .other, !snapshots.isEmpty else { throw RemovalError.unsupportedLocation }
        guard snapshots.count == model.fileCount else { throw RemovalError.changed }
        let normalizedPaths = snapshots.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        guard Set(normalizedPaths).count == normalizedPaths.count else { throw RemovalError.changed }
        if snapshots.count == 1 {
            guard normalizedPaths[0] == URL(fileURLWithPath: model.path).standardizedFileURL.path else {
                throw RemovalError.unsupportedLocation
            }
        } else {
            guard snapshots.allSatisfy({ URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL.path == model.path }) else {
                throw RemovalError.unsupportedLocation
            }
        }

        var items: [PlannedTrashItem] = []
        for snapshot in snapshots {
            let path = URL(fileURLWithPath: snapshot.path).standardizedFileURL.path
            guard SafeFilePolicy.isInside(path, root: homeDirectory.path),
                  LocalAIModelInventoryService.modelWeightExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                  !SafeFilePolicy.isEssentialSystemLocation(path),
                  !SafeFilePolicy.containsProtectedModelInventoryPathComponent(path),
                  !SafeFilePolicy.isInsideDevelopmentRepository(path, homeDirectory: homeDirectory),
                  snapshot.identity.type == .regularFile,
                  snapshot.identity.linkCount == 1,
                  isCurrent(snapshot, rootedAt: homeDirectory) else { throw RemovalError.protectedLocation }
            items.append(PlannedTrashItem(snapshot: snapshot, bytes: snapshot.identity.size))
        }
        guard items.reduce(Int64(0), { Self.saturatingAdd($0, $1.bytes) }) == model.sizeBytes else {
            throw RemovalError.changed
        }
        return ModelMovePlan(model: model, items: items)
    }

    private func prepareHuggingFaceModel(
        _ model: LocalAIModel,
        root snapshot: LocalAIModelTargetSnapshot,
        modelFiles: [LocalAIModelTargetSnapshot]
    ) throws -> ModelMovePlan {
        guard model.provider == .huggingFace, !modelFiles.isEmpty else { throw RemovalError.unsupportedLocation }
        let hubRoot = LocalAIModelProvider.huggingFace.defaultDirectory(home: homeDirectory).standardizedFileURL
        let path = URL(fileURLWithPath: snapshot.path).standardizedFileURL
        guard Self.canonicalPath(path.deletingLastPathComponent()) == Self.canonicalPath(hubRoot),
              path.lastPathComponent.hasPrefix("models--"),
              Self.canonicalPath(URL(fileURLWithPath: model.path)) == Self.canonicalPath(path) else {
            throw RemovalError.unsupportedLocation
        }
        guard snapshot.identity.type == .directory, isCurrent(snapshot, rootedAt: homeDirectory) else {
            throw RemovalError.changed
        }

        let expectedBytes = try validateModelFiles(modelFiles, within: path, expectedCount: model.fileCount)
        guard expectedBytes == model.sizeBytes else { throw RemovalError.changed }
        _ = try inspectManagedDirectory(path, expectedRootIdentity: snapshot.identity, allowInternalFileSymlinks: true)
        return ModelMovePlan(model: model, items: [PlannedTrashItem(
            snapshot: snapshot,
            bytes: expectedBytes,
            additionalSnapshots: modelFiles,
            allowInternalFileSymlinks: true
        )])
    }

    private func prepareLMStudioModel(
        _ model: LocalAIModel,
        root snapshot: LocalAIModelTargetSnapshot,
        files: [LocalAIModelTargetSnapshot]
    ) throws -> ModelMovePlan {
        guard model.provider == .lmStudio, !files.isEmpty else { throw RemovalError.unsupportedLocation }
        let modelsRoot = LocalAIModelProvider.lmStudio.defaultDirectory(home: homeDirectory).standardizedFileURL
        let path = URL(fileURLWithPath: snapshot.path).standardizedFileURL
        let publisherPath = path.deletingLastPathComponent()
        guard Self.canonicalPath(publisherPath.deletingLastPathComponent()) == Self.canonicalPath(modelsRoot),
              Self.canonicalPath(publisherPath) != Self.canonicalPath(modelsRoot),
              Self.canonicalPath(URL(fileURLWithPath: model.path)) == Self.canonicalPath(path) else {
            throw RemovalError.unsupportedLocation
        }
        guard snapshot.identity.type == .directory, isCurrent(snapshot, rootedAt: homeDirectory) else {
            throw RemovalError.changed
        }

        let expectedBytes = try validateModelFiles(files, within: path, expectedCount: model.fileCount)
        guard expectedBytes == model.sizeBytes else { throw RemovalError.changed }
        let contents = try inspectManagedDirectory(path, expectedRootIdentity: snapshot.identity, allowInternalFileSymlinks: false)
        guard contents.containsModelWeight else { throw RemovalError.unsupportedLocation }
        return ModelMovePlan(model: model, items: [PlannedTrashItem(
            snapshot: snapshot,
            bytes: expectedBytes,
            additionalSnapshots: files,
            allowInternalFileSymlinks: false
        )])
    }

    private func validateModelFiles(
        _ snapshots: [LocalAIModelTargetSnapshot],
        within root: URL,
        expectedCount: Int
    ) throws -> Int64 {
        guard snapshots.count == expectedCount,
              Set(snapshots.map(\.path)).count == snapshots.count else { throw RemovalError.changed }
        var total: Int64 = 0
        for snapshot in snapshots {
            let path = URL(fileURLWithPath: snapshot.path).standardizedFileURL.path
            guard SafeFilePolicy.isInside(path, root: root.path),
                  snapshot.identity.type == .regularFile,
                  snapshot.identity.linkCount == 1,
                  !SafeFilePolicy.containsProtectedModelInventoryPathComponent(path),
                  isCurrent(snapshot, rootedAt: root),
                  !SafeFilePolicy.isInsideDevelopmentRepository(path, homeDirectory: homeDirectory) else {
                throw RemovalError.protectedLocation
            }
            total = Self.saturatingAdd(total, snapshot.identity.size)
        }
        return total
    }

    private func inspectManagedDirectory(
        _ root: URL,
        expectedRootIdentity: LocalAIModelNodeIdentity,
        allowInternalFileSymlinks: Bool
    ) throws -> DirectoryInspection {
        guard isCurrent(LocalAIModelTargetSnapshot(path: root.path, identity: expectedRootIdentity), rootedAt: homeDirectory) else {
            throw RemovalError.changed
        }
        var directories = [root]
        var entriesVisited = 0
        var uniqueFiles: Set<FileKey> = []
        var containsModelWeight = false

        while let directory = directories.popLast() {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            } catch {
                throw RemovalError.inaccessible
            }
            for child in children {
                entriesVisited += 1
                guard entriesVisited <= maximumEntries else { throw RemovalError.tooLargeToCheck }
                let path = child.standardizedFileURL.path
                guard SafeFilePolicy.isInside(path, root: root.path),
                      !SafeFilePolicy.containsProtectedModelInventoryPathComponent(path),
                      let identity = Self.identity(at: path) else { throw RemovalError.protectedLocation }

                switch identity.type {
                case .directory:
                    directories.append(child)
                case .regularFile:
                    guard identity.linkCount == 1 else { throw RemovalError.sharedFile }
                    uniqueFiles.insert(FileKey(device: identity.device, inode: identity.inode, size: identity.size))
                    if LocalAIModelInventoryService.modelWeightExtensions.contains(child.pathExtension.lowercased()) {
                        containsModelWeight = true
                    }
                case .symbolicLink:
                    guard allowInternalFileSymlinks,
                          Self.safeInternalFileSymlink(child, root: root),
                          let targetIdentity = Self.identity(at: child.resolvingSymlinksInPath().standardizedFileURL.path),
                          targetIdentity.type == .regularFile,
                          targetIdentity.linkCount == 1 else { throw RemovalError.unsafeSymbolicLink }
                    uniqueFiles.insert(FileKey(device: targetIdentity.device, inode: targetIdentity.inode, size: targetIdentity.size))
                    if LocalAIModelInventoryService.modelWeightExtensions.contains(child.pathExtension.lowercased()) {
                        containsModelWeight = true
                    }
                case .other:
                    throw RemovalError.unsupportedFileType
                }
            }
        }

        guard isCurrent(LocalAIModelTargetSnapshot(path: root.path, identity: expectedRootIdentity), rootedAt: homeDirectory) else {
            throw RemovalError.changed
        }
        let sizeBytes = uniqueFiles.reduce(Int64(0)) { Self.saturatingAdd($0, $1.size) }
        return DirectoryInspection(sizeBytes: sizeBytes, fileCount: uniqueFiles.count, containsModelWeight: containsModelWeight)
    }

    private func prepareOllamaModel(
        _ model: LocalAIModel,
        manifest: LocalAIModelTargetSnapshot,
        blobs: [LocalAIModelTargetSnapshot]
    ) throws -> ValidatedOllamaModel {
        guard model.provider == .ollama, model.path == manifest.path,
              manifest.identity.type == .regularFile,
              manifest.identity.linkCount == 1 else { throw RemovalError.unsupportedLocation }
        let modelsRoot = LocalAIModelProvider.ollama.defaultDirectory(home: homeDirectory).standardizedFileURL
        let manifestRoot = modelsRoot.appendingPathComponent("manifests", isDirectory: true)
        let blobRoot = modelsRoot.appendingPathComponent("blobs", isDirectory: true)
        let manifestPath = URL(fileURLWithPath: manifest.path).standardizedFileURL
        guard SafeFilePolicy.isInside(manifestPath.path, root: manifestRoot.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: manifestPath.path, root: homeDirectory.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: blobRoot.path, root: homeDirectory.path),
              isCurrent(manifest, rootedAt: homeDirectory) else { throw RemovalError.protectedLocation }

        let parsed = try parseOllamaManifest(manifestPath, relativeTo: manifestRoot)
        guard parsed.name == model.name else { throw RemovalError.changed }
        let blobSnapshots = Dictionary(grouping: blobs, by: \.path).compactMapValues(\.first)
        guard Set(blobSnapshots.keys).count == parsed.blobNames.count,
              Set(blobSnapshots.keys.map { URL(fileURLWithPath: $0).lastPathComponent }) == parsed.blobNames else {
            throw RemovalError.changed
        }
        for snapshot in blobSnapshots.values {
            let path = URL(fileURLWithPath: snapshot.path).standardizedFileURL
            guard path.deletingLastPathComponent().path == blobRoot.path,
                  snapshot.identity.type == .regularFile,
                  snapshot.identity.linkCount == 1,
                  SafeFilePolicy.hasNoSymlinkedParent(path: path.path, root: homeDirectory.path),
                  isCurrent(snapshot, rootedAt: homeDirectory) else { throw RemovalError.changed }
        }
        let expectedBytes = blobSnapshots.values.reduce(Int64(0)) { Self.saturatingAdd($0, $1.identity.size) }
        guard expectedBytes == model.sizeBytes else { throw RemovalError.changed }
        return ValidatedOllamaModel(model: model, manifest: manifest, blobs: Array(blobSnapshots.values))
    }

    private func moveOllamaManifests(
        _ candidates: [ValidatedOllamaModel],
        failures: inout [LocalAIModelRemovalFailure],
        movedModelIDs: inout Set<String>,
        filesMoved: inout Int
    ) -> [ValidatedOllamaModel] {
        var moved: [ValidatedOllamaModel] = []
        for candidate in candidates {
            guard isCurrent(candidate.manifest, rootedAt: homeDirectory) else {
                failures.append(failure(candidate.model, "This model changed after the scan. Refresh and review it again."))
                continue
            }
            do {
                try trashOperation(URL(fileURLWithPath: candidate.manifest.path))
                moved.append(candidate)
                movedModelIDs.insert(candidate.model.id)
                filesMoved += 1
            } catch {
                failures.append(failure(candidate.model, "macOS could not move this model entry to Trash."))
            }
        }
        return moved
    }

    private func moveUnreferencedOllamaBlobs(
        _ models: [ValidatedOllamaModel],
        failures: inout [LocalAIModelRemovalFailure]
    ) -> (filesMoved: Int, bytesMoved: Int64, sharedDataRetained: Bool) {
        let selectedBlobNames = Set(models.flatMap { $0.blobs.map { URL(fileURLWithPath: $0.path).lastPathComponent } })
        guard !selectedBlobNames.isEmpty else { return (0, 0, false) }
        guard let remainingReferences = remainingOllamaBlobReferences() else {
            return (0, 0, true)
        }

        let retainedNames = selectedBlobNames.intersection(remainingReferences)
        var snapshotsByName: [String: LocalAIModelTargetSnapshot] = [:]
        for snapshot in models.flatMap(\.blobs) {
            let name = URL(fileURLWithPath: snapshot.path).lastPathComponent
            snapshotsByName[name] = snapshot
        }

        var filesMoved = 0
        var bytesMoved: Int64 = 0
        for name in selectedBlobNames.subtracting(remainingReferences).sorted() {
            guard let snapshot = snapshotsByName[name], isCurrent(snapshot, rootedAt: homeDirectory) else {
                for model in models where model.blobs.contains(where: { URL(fileURLWithPath: $0.path).lastPathComponent == name }) {
                    failures.append(failure(model.model, "A shared model file changed after the scan and was left in place."))
                }
                continue
            }
            do {
                try trashOperation(URL(fileURLWithPath: snapshot.path))
                filesMoved += 1
                bytesMoved = Self.saturatingAdd(bytesMoved, snapshot.identity.size)
            } catch {
                for model in models where model.blobs.contains(where: { URL(fileURLWithPath: $0.path).lastPathComponent == name }) {
                    failures.append(failure(model.model, "macOS could not move some model data to Trash."))
                }
            }
        }
        return (filesMoved, bytesMoved, !retainedNames.isEmpty)
    }

    private func remainingOllamaBlobReferences() -> Set<String>? {
        let manifestRoot = LocalAIModelProvider.ollama.defaultDirectory(home: homeDirectory)
            .appendingPathComponent("manifests", isDirectory: true)
        guard SafeFilePolicy.hasNoSymlinkedParent(path: manifestRoot.path, root: homeDirectory.path),
              let rootIdentity = Self.identity(at: manifestRoot.path), rootIdentity.type == .directory else { return nil }
        var directories = [manifestRoot]
        var visited = 0
        var references: Set<String> = []

        while let directory = directories.popLast() {
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else {
                return nil
            }
            for child in children {
                visited += 1
                guard visited <= maximumEntries, let identity = Self.identity(at: child.path) else { return nil }
                switch identity.type {
                case .directory:
                    directories.append(child)
                case .regularFile:
                    guard identity.size <= maximumManifestBytes,
                          let manifest = try? parseOllamaManifest(child, relativeTo: manifestRoot) else { return nil }
                    references.formUnion(manifest.blobNames)
                case .symbolicLink, .other:
                    return nil
                }
            }
        }
        return references
    }

    private func parseOllamaManifest(_ url: URL, relativeTo root: URL) throws -> ParsedOllamaManifest {
        guard let identity = Self.identity(at: url.path), identity.type == .regularFile,
              identity.size <= maximumManifestBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = object["layers"] as? [[String: Any]], !layers.isEmpty else { throw RemovalError.invalidManifest }
        let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 3, let tag = components.last else { throw RemovalError.invalidManifest }
        var modelComponents = Array(components.dropFirst().dropLast())
        if modelComponents.first == "library" { modelComponents.removeFirst() }
        guard !modelComponents.isEmpty else { throw RemovalError.invalidManifest }

        var names: Set<String> = []
        for layer in layers {
            guard let digest = layer["digest"] as? String,
                  let name = ollamaBlobName(for: digest) else { throw RemovalError.invalidManifest }
            names.insert(name)
        }
        guard !names.isEmpty else { throw RemovalError.invalidManifest }
        return ParsedOllamaManifest(name: "\(modelComponents.joined(separator: "/")):\(tag)", blobNames: names)
    }

    private func ollamaBlobName(for digest: String) -> String? {
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "sha256", parts[1].count == 64,
              parts[1].allSatisfy(\.isHexDigit) else { return nil }
        return "sha256-\(parts[1].lowercased())"
    }

    private func isCurrent(_ snapshot: LocalAIModelTargetSnapshot, rootedAt root: URL) -> Bool {
        let path = URL(fileURLWithPath: snapshot.path).standardizedFileURL.path
        guard SafeFilePolicy.isInside(path, root: root.standardizedFileURL.path),
              SafeFilePolicy.hasNoSymlinkedParent(path: path, root: root.standardizedFileURL.path),
              let current = Self.identity(at: path) else { return false }
        return current == snapshot.identity
    }

    private static func safeInternalFileSymlink(_ link: URL, root: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        return isInsideOrEqual(target.path, root: root.path)
            && isInsideOrEqual(resolved.path, root: root.path)
    }

    private static func identity(at path: String) -> LocalAIModelNodeIdentity? {
        var info = Darwin.stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        let type = info.st_mode & mode_t(S_IFMT)
        let nodeType: LocalAIModelNodeType
        if type == mode_t(S_IFREG) { nodeType = .regularFile }
        else if type == mode_t(S_IFDIR) { nodeType = .directory }
        else if type == mode_t(S_IFLNK) { nodeType = .symbolicLink }
        else { nodeType = .other }
        return LocalAIModelNodeIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: max(0, Int64(info.st_size)),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            linkCount: UInt32(info.st_nlink),
            type: nodeType
        )
    }

    private static func isInsideOrEqual(_ candidate: String, root: String) -> Bool {
        let normalizedCandidate = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        return normalizedCandidate == normalizedRoot || SafeFilePolicy.isInside(normalizedCandidate, root: normalizedRoot)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func failure(_ model: LocalAIModel, _ reason: String) -> LocalAIModelRemovalFailure {
        LocalAIModelRemovalFailure(modelID: model.id, modelName: model.name, reason: reason)
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private struct ModelMovePlan {
        let model: LocalAIModel
        let items: [PlannedTrashItem]
    }

    private struct PlannedTrashItem {
        let snapshot: LocalAIModelTargetSnapshot
        let bytes: Int64
        var additionalSnapshots: [LocalAIModelTargetSnapshot] = []
        var allowInternalFileSymlinks: Bool? = nil
    }

    private struct ValidatedOllamaModel {
        let model: LocalAIModel
        let manifest: LocalAIModelTargetSnapshot
        let blobs: [LocalAIModelTargetSnapshot]
    }

    private struct ParsedOllamaManifest {
        let name: String
        let blobNames: Set<String>
    }

    private struct DirectoryInspection {
        let sizeBytes: Int64
        let fileCount: Int
        let containsModelWeight: Bool
    }

    private struct FileKey: Hashable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
    }

    private enum RemovalError: Error, LocalizedError {
        case unsupportedLocation
        case protectedLocation
        case changed
        case inaccessible
        case tooLargeToCheck
        case sharedFile
        case unsafeSymbolicLink
        case unsupportedFileType
        case invalidManifest

        var errorDescription: String? {
            switch self {
            case .unsupportedLocation:
                "This model is outside a supported local model folder."
            case .protectedLocation:
                "This location may contain private data or is outside the approved model folder."
            case .changed:
                "This model changed after the scan. Refresh and review it again."
            case .inaccessible:
                "macOS could not read every part of this model folder, so it was left in place."
            case .tooLargeToCheck:
                "This model folder is too large to verify safely, so it was left in place."
            case .sharedFile:
                "A model file is shared with another file, so it was left in place."
            case .unsafeSymbolicLink:
                "This model folder contains a link to a file outside the model, so it was left in place."
            case .unsupportedFileType:
                "This model folder contains an item that cannot be checked safely."
            case .invalidManifest:
                "The model manager's local model record could not be verified."
            }
        }
    }
}
