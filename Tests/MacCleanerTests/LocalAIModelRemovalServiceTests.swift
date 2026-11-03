import Darwin
import Foundation
import XCTest
@testable import MacCleaner

final class LocalAIModelRemovalServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCustomModelFilesMoveToTrashButModelFolderSupportFilesStay() throws {
        let home = try temporaryHome()
        let modelFolder = home.appendingPathComponent("Documents/Models/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        let firstWeight = modelFolder.appendingPathComponent("model-00001.safetensors")
        let secondWeight = modelFolder.appendingPathComponent("model-00002.safetensors")
        let config = modelFolder.appendingPathComponent("config.json")
        try Data(repeating: 0x41, count: 9).write(to: firstWeight)
        try Data(repeating: 0x42, count: 5).write(to: secondWeight)
        try Data("{}".utf8).write(to: config)
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first)
        let recorder = TrashRecorder()
        let expectedTrashNames = Set([firstWeight.lastPathComponent, secondWeight.lastPathComponent])

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertEqual(result.movedModelIDs, [model.id])
        XCTAssertEqual(result.filesMoved, 2)
        XCTAssertEqual(result.bytesMoved, 14)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstWeight.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondWeight.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual(Set(recorder.paths.map { URL(fileURLWithPath: $0).lastPathComponent }), expectedTrashNames)
    }

    func testOllamaRemovalKeepsBlobsStillReferencedByAnotherModel() throws {
        let home = try temporaryHome()
        let modelsRoot = home.appendingPathComponent(".ollama/models", isDirectory: true)
        let manifestRoot = modelsRoot.appendingPathComponent("manifests/registry.ollama.ai/library", isDirectory: true)
        let blobRoot = modelsRoot.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: true)
        let sharedDigest = String(repeating: "a", count: 64)
        let selectedDigest = String(repeating: "b", count: 64)
        try Data(repeating: 0x41, count: 10).write(to: blobRoot.appendingPathComponent("sha256-\(sharedDigest)"))
        try Data(repeating: 0x42, count: 5).write(to: blobRoot.appendingPathComponent("sha256-\(selectedDigest)"))
        try writeOllamaManifest(root: manifestRoot, model: "tiny", tag: "7b", digests: [sharedDigest, selectedDigest])
        try writeOllamaManifest(root: manifestRoot, model: "other", tag: "latest", digests: [sharedDigest])
        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()
        let selected = try XCTUnwrap(inventory.models.first { $0.name == "tiny:7b" })
        let selectedManifest = URL(fileURLWithPath: selected.path)
        let sharedBlob = blobRoot.appendingPathComponent("sha256-\(sharedDigest)")
        let uniqueBlob = blobRoot.appendingPathComponent("sha256-\(selectedDigest)")
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([selected])

        XCTAssertEqual(result.movedModelIDs, [selected.id])
        XCTAssertEqual(result.filesMoved, 2)
        XCTAssertEqual(result.bytesMoved, 5)
        XCTAssertTrue(result.sharedModelDataRetained)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedBlob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: uniqueBlob.path))
    }

    func testOllamaRemovalOfAllSelectedModelsMovesSharedBlobOnlyOnce() throws {
        let home = try temporaryHome()
        let modelsRoot = home.appendingPathComponent(".ollama/models", isDirectory: true)
        let manifestRoot = modelsRoot.appendingPathComponent("manifests/registry.ollama.ai/library", isDirectory: true)
        let blobRoot = modelsRoot.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: true)
        let digest = String(repeating: "c", count: 64)
        try Data(repeating: 0x43, count: 12).write(to: blobRoot.appendingPathComponent("sha256-\(digest)"))
        try writeOllamaManifest(root: manifestRoot, model: "tiny", tag: "7b", digests: [digest])
        try writeOllamaManifest(root: manifestRoot, model: "small", tag: "latest", digests: [digest])
        let models = LocalAIModelInventoryService(homeDirectory: home).scan().models
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash(models)

        XCTAssertEqual(Set(result.movedModelIDs), Set(models.map(\.id)))
        XCTAssertEqual(result.filesMoved, 3)
        XCTAssertEqual(result.bytesMoved, 12)
        XCTAssertFalse(result.sharedModelDataRetained)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(recorder.paths.filter { URL(fileURLWithPath: $0).lastPathComponent == "sha256-\(digest)" }.count, 1)
    }

    func testChangedOllamaBlobPreventsTheModelRecordFromMoving() throws {
        let home = try temporaryHome()
        let modelsRoot = home.appendingPathComponent(".ollama/models", isDirectory: true)
        let manifestRoot = modelsRoot.appendingPathComponent("manifests/registry.ollama.ai/library", isDirectory: true)
        let blobRoot = modelsRoot.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: true)
        let digest = String(repeating: "d", count: 64)
        let blob = blobRoot.appendingPathComponent("sha256-\(digest)")
        try Data(repeating: 0x41, count: 8).write(to: blob)
        try writeOllamaManifest(root: manifestRoot, model: "tiny", tag: "7b", digests: [digest])
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first)
        try Data(repeating: 0x42, count: 64).write(to: blob)
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.movedModelIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testChangedCustomModelIsLeftInPlace() throws {
        let home = try temporaryHome()
        let modelPath = home.appendingPathComponent("Downloads/model.gguf")
        try FileManager.default.createDirectory(at: modelPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8).write(to: modelPath)
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first)
        try Data(repeating: 0x42, count: 64).write(to: modelPath)
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.movedModelIDs.isEmpty)
        XCTAssertEqual(result.filesMoved, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath.path))
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testHardLinkedCustomModelIsRefused() throws {
        let home = try temporaryHome()
        let modelPath = home.appendingPathComponent("Downloads/model.gguf")
        let secondLink = home.appendingPathComponent("Downloads/model-copy.gguf")
        try FileManager.default.createDirectory(at: modelPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8).write(to: modelPath)
        try FileManager.default.linkItem(at: modelPath, to: secondLink)
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first)
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.movedModelIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondLink.path))
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testCustomModelInCredentialFolderIsRefused() throws {
        let home = try temporaryHome()
        let secretPath = home.appendingPathComponent(".ssh/private.gguf")
        try FileManager.default.createDirectory(at: secretPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8).write(to: secretPath)
        let model = LocalAIModel(
            id: "other:\(secretPath.path)",
            name: secretPath.lastPathComponent,
            provider: .other,
            path: secretPath.path,
            sizeBytes: 8,
            fileCount: 1,
            modifiedAt: nil,
            removalTarget: .modelFiles([try snapshot(secretPath)])
        )
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.movedModelIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretPath.path))
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testHuggingFaceRepositoryWithInternalSnapshotSymlinkMovesToTrash() throws {
        let home = try temporaryHome()
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let repository = hub.appendingPathComponent("models--org--tiny-model", isDirectory: true)
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = repository.appendingPathComponent("snapshots/rev-a", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 17).write(to: blobs.appendingPathComponent("model-blob"))
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("weights.safetensors").path,
            withDestinationPath: "../../blobs/model-blob"
        )
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first)
        XCTAssertEqual(model.provider, .huggingFace)
        XCTAssertEqual(
            URL(fileURLWithPath: model.path).standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path,
            LocalAIModelProvider.huggingFace.defaultDirectory(home: home).standardizedFileURL.resolvingSymlinksInPath().path
        )
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.reason).joined(separator: "; "))
        XCTAssertEqual(result.movedModelIDs, [model.id])
        XCTAssertEqual(result.filesMoved, 1)
        XCTAssertEqual(result.bytesMoved, 17)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.path))
    }

    func testHuggingFaceRepositoryWithCrossModelSymlinkIsRefused() throws {
        let home = try temporaryHome()
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let selectedRepository = hub.appendingPathComponent("models--org--selected", isDirectory: true)
        let otherBlob = hub.appendingPathComponent("models--org--other/blobs/model-blob")
        let selectedBlobs = selectedRepository.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedBlobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherBlob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 17).write(to: otherBlob)
        try FileManager.default.createSymbolicLink(atPath: selectedBlobs.appendingPathComponent("external-blob").path, withDestinationPath: otherBlob.path)
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first { $0.name == "org/selected" })
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.movedModelIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedRepository.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherBlob.path))
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    func testLMStudioModelFolderMovesToTrashAfterVerification() throws {
        let home = try temporaryHome()
        let modelDirectory = home.appendingPathComponent(".lmstudio/models/Acme/small-local", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 9).write(to: modelDirectory.appendingPathComponent("weights.gguf"))
        try Data("config".utf8).write(to: modelDirectory.appendingPathComponent("config.json"))
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first)
        XCTAssertEqual(model.provider, .lmStudio)
        XCTAssertEqual(
            URL(fileURLWithPath: model.path).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path,
            LocalAIModelProvider.lmStudio.defaultDirectory(home: home).standardizedFileURL.resolvingSymlinksInPath().path
        )
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.reason).joined(separator: "; "))
        XCTAssertEqual(result.movedModelIDs, [model.id])
        XCTAssertEqual(result.filesMoved, 1)
        XCTAssertEqual(result.bytesMoved, 15)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    func testLMStudioModelWithExternalSymbolicLinkIsRefused() throws {
        let home = try temporaryHome()
        let outsideHome = try temporaryHome()
        let modelDirectory = home.appendingPathComponent(".lmstudio/models/Acme/small-local", isDirectory: true)
        let externalFile = outsideHome.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 9).write(to: modelDirectory.appendingPathComponent("weights.gguf"))
        try Data("private".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            atPath: modelDirectory.appendingPathComponent("external.txt").path,
            withDestinationPath: externalFile.path
        )
        let model = try XCTUnwrap(LocalAIModelInventoryService(homeDirectory: home).scan().models.first)
        let recorder = TrashRecorder()

        let result = LocalAIModelRemovalService(homeDirectory: home, trashOperation: { url in try recorder.move(url) }).moveToTrash([model])

        XCTAssertTrue(result.movedModelIDs.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))
        XCTAssertTrue(recorder.paths.isEmpty)
    }

    private func writeOllamaManifest(root: URL, model: String, tag: String, digests: [String]) throws {
        let directory = root.appendingPathComponent(model, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layers = digests.map { ["digest": "sha256:\($0)", "mediaType": "application/vnd.ollama.image.model"] }
        try JSONSerialization.data(withJSONObject: ["layers": layers]).write(to: directory.appendingPathComponent(tag))
    }

    private func snapshot(_ url: URL) throws -> LocalAIModelTargetSnapshot {
        var info = Darwin.stat()
        XCTAssertEqual(url.path.withCString { Darwin.lstat($0, &info) }, 0)
        return LocalAIModelTargetSnapshot(
            path: url.path,
            identity: LocalAIModelNodeIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                size: Int64(info.st_size),
                modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
                linkCount: UInt32(info.st_nlink),
                type: .regularFile
            )
        )
    }

    private func temporaryHome() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerLocalModelRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryDirectories.append(folder)
        return folder
    }
}

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedPaths
    }

    func move(_ url: URL) throws {
        lock.lock()
        storedPaths.append(url.path)
        lock.unlock()
        try FileManager.default.removeItem(at: url)
    }
}
