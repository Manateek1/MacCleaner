import Foundation
import XCTest
@testable import MacCleaner

final class LocalAIModelInventoryTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testOllamaInventoryReadsManifestMetadataAndDeduplicatesSharedBlobs() throws {
        let home = try temporaryHome()
        let modelsRoot = home.appendingPathComponent(".ollama/models", isDirectory: true)
        let manifestRoot = modelsRoot.appendingPathComponent("manifests/registry.ollama.ai/library/tiny", isDirectory: true)
        let blobRoot = modelsRoot.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: blobRoot.appendingPathComponent("sha256-\(String(repeating: "a", count: 64))"))
        try Data(repeating: 0x42, count: 2).write(to: blobRoot.appendingPathComponent("sha256-\(String(repeating: "b", count: 64))"))

        for tag in ["7b", "latest"] {
            let manifest = manifestRoot.appendingPathComponent(tag)
            let json: [String: Any] = [
                "layers": [
                    ["mediaType": "application/vnd.ollama.image.model", "digest": "sha256:\(String(repeating: "a", count: 64))"],
                    ["mediaType": "application/vnd.ollama.image.template", "digest": "sha256:\(String(repeating: "b", count: 64))"]
                ]
            ]
            try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        }

        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()

        XCTAssertEqual(inventory.models.map(\.name), ["tiny:7b", "tiny:latest"])
        XCTAssertTrue(inventory.models.allSatisfy { $0.provider == .ollama && $0.sizeBytes == 12 && $0.fileCount == 2 })
        XCTAssertEqual(inventory.uniqueBytes, 12)
        XCTAssertEqual(inventory.checkedLocations, [modelsRoot.path, home.path])
    }

    func testHuggingFaceInventoryCountsBlobOnceAcrossSnapshotLinks() throws {
        let home = try temporaryHome()
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let repository = hub.appendingPathComponent("models--org--tiny-model", isDirectory: true)
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        let firstSnapshot = repository.appendingPathComponent("snapshots/rev-a", isDirectory: true)
        let secondSnapshot = repository.appendingPathComponent("snapshots/rev-b", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstSnapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSnapshot, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("model-blob")
        try Data(repeating: 0x41, count: 17).write(to: blob)
        try FileManager.default.createSymbolicLink(atPath: firstSnapshot.appendingPathComponent("weights.safetensors").path, withDestinationPath: "../../blobs/model-blob")
        try FileManager.default.createSymbolicLink(atPath: secondSnapshot.appendingPathComponent("weights.safetensors").path, withDestinationPath: "../../blobs/model-blob")

        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()

        let model = try XCTUnwrap(inventory.models.first)
        XCTAssertEqual(inventory.models.count, 1)
        XCTAssertEqual(model.name, "org/tiny-model")
        XCTAssertEqual(model.provider, .huggingFace)
        XCTAssertEqual(model.sizeBytes, 17)
        XCTAssertEqual(model.fileCount, 1)
        XCTAssertEqual(inventory.uniqueBytes, 17)
    }

    func testHuggingFaceSymlinksOutsideCacheAreNotCounted() throws {
        let home = try temporaryHome()
        let outside = try temporaryHome().appendingPathComponent("private-model.bin")
        try Data(repeating: 0x42, count: 11).write(to: outside)
        let repository = home.appendingPathComponent(".cache/huggingface/hub/models--org--external", isDirectory: true)
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: blobs.appendingPathComponent("external-blob").path, withDestinationPath: outside.path)

        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()

        XCTAssertTrue(inventory.models.isEmpty)
        XCTAssertEqual(inventory.uniqueBytes, 0)
        XCTAssertGreaterThan(inventory.skippedLocations, 0)
    }

    func testSymlinkedProviderRootIsNotTraversed() throws {
        let home = try temporaryHome()
        let external = try temporaryHome()
        let externalModel = external.appendingPathComponent("Acme/small-local", isDirectory: true)
        try FileManager.default.createDirectory(at: externalModel, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8).write(to: externalModel.appendingPathComponent("weights.gguf"))
        let parent = home.appendingPathComponent(".lmstudio", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: parent.appendingPathComponent("models", isDirectory: true).path,
            withDestinationPath: external.path
        )

        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()

        XCTAssertTrue(inventory.models.isEmpty)
        XCTAssertEqual(inventory.uniqueBytes, 0)
        XCTAssertFalse(inventory.checkedLocations.contains { $0.hasSuffix("/.lmstudio/models") })
    }

    func testLMStudioInventoryGroupsModelFilesAndSupportFilesByModelFolder() throws {
        let home = try temporaryHome()
        let modelDirectory = home.appendingPathComponent(".lmstudio/models/Acme/small-local", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 9).write(to: modelDirectory.appendingPathComponent("weights.gguf"))
        try Data("config".utf8).write(to: modelDirectory.appendingPathComponent("config.json"))
        let unrelated = home.appendingPathComponent(".lmstudio/models/notes.txt")
        try FileManager.default.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a model".utf8).write(to: unrelated)

        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()

        let model = try XCTUnwrap(inventory.models.first)
        XCTAssertEqual(inventory.models.count, 1)
        XCTAssertEqual(model.name, "Acme/small-local")
        XCTAssertEqual(model.provider, .lmStudio)
        XCTAssertEqual(model.sizeBytes, 15)
        XCTAssertEqual(model.fileCount, 2)
        XCTAssertEqual(
            URL(fileURLWithPath: model.path).standardizedFileURL.resolvingSymlinksInPath(),
            modelDirectory.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testFindsRecognizableModelFilesOutsideProviderFoldersInHomeFolder() throws {
        let home = try temporaryHome()
        let download = home.appendingPathComponent("Downloads/chat-model.gguf")
        try FileManager.default.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 13).write(to: download)

        let shardedModel = home.appendingPathComponent("Documents/Models/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: shardedModel, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8).write(to: shardedModel.appendingPathComponent("model-00001.safetensors"))
        try Data(repeating: 0x43, count: 5).write(to: shardedModel.appendingPathComponent("model-00002.safetensors"))
        try Data("{}".utf8).write(to: shardedModel.appendingPathComponent("config.json"))

        let unrelatedBinary = home.appendingPathComponent("Downloads/other.bin")
        try Data(repeating: 0x44, count: 7).write(to: unrelatedBinary)
        let secretModelLikeFile = home.appendingPathComponent(".ssh/private.gguf")
        try FileManager.default.createDirectory(at: secretModelLikeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x45, count: 11).write(to: secretModelLikeFile)

        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()

        let otherModels = inventory.models.filter { $0.provider == .other }
        XCTAssertEqual(otherModels.count, 2)
        XCTAssertEqual(inventory.uniqueBytes, 26)
        XCTAssertTrue(inventory.checkedLocations.contains(home.path))

        let looseModel = try XCTUnwrap(otherModels.first { $0.name == download.lastPathComponent })
        XCTAssertEqual(looseModel.name, "chat-model.gguf")
        XCTAssertEqual(looseModel.fileCount, 1)
        XCTAssertEqual(looseModel.sizeBytes, 13)

        let shardedModelEntry = try XCTUnwrap(otherModels.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL == shardedModel.standardizedFileURL
        })
        XCTAssertEqual(shardedModelEntry.fileCount, 2)
        XCTAssertEqual(shardedModelEntry.sizeBytes, 13)
    }

    func testCustomModelSearchDoesNotFollowSymlinksOrReportUnrelatedBinaryFiles() throws {
        let home = try temporaryHome()
        let external = try temporaryHome()
        let externalModel = external.appendingPathComponent("private.safetensors")
        try Data(repeating: 0x41, count: 16).write(to: externalModel)

        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: downloads.appendingPathComponent("linked.safetensors"),
            withDestinationURL: externalModel
        )
        try Data(repeating: 0x42, count: 9).write(to: downloads.appendingPathComponent("library.bin"))

        let inventory = LocalAIModelInventoryService(homeDirectory: home).scan()

        XCTAssertTrue(inventory.models.filter { $0.provider == .other }.isEmpty)
        XCTAssertEqual(inventory.uniqueBytes, 0)
        XCTAssertGreaterThan(inventory.skippedLocations, 0)
    }

    func testInventoryStopsAtConfiguredEntryLimit() throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent(".lmstudio/models", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("publisher/model", isDirectory: true), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4).write(to: root.appendingPathComponent("publisher/model/weights.gguf"))

        let inventory = LocalAIModelInventoryService(homeDirectory: home, maximumEntries: 1).scan()

        XCTAssertTrue(inventory.wasLimited)
    }

    private func temporaryHome() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerLocalModels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryDirectories.append(folder)
        return folder
    }
}
