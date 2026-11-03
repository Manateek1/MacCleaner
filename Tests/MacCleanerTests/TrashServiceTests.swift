import Foundation
import XCTest
@testable import MacCleaner

final class TrashServiceTests: XCTestCase {
    func testMovesReviewedFileToTrashAndVerifiesItsIdentity() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("candidate.bin")
        let contents = Data(repeating: 0x41, count: 1_024)
        try contents.write(to: file)
        let item = try await scannedItem(at: file, inside: root)
        let destinationFolder = root.appendingPathComponent("MockDestination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let service = TrashService { url in
            let destination = destinationFolder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let result = service.moveToTrash([item], allCandidates: [item], inside: root)

        XCTAssertEqual(result.moved, [item.path])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.bytesMoved, Int64(contents.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: destinationFolder.appendingPathComponent(file.lastPathComponent)), contents)
    }

    func testChangedFileIsNotSentToTrash() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("candidate.bin")
        try Data("before scan".utf8).write(to: file)
        let item = try await scannedItem(at: file, inside: root)
        try Data("changed after scan with a new size".utf8).write(to: file)
        let counter = CallCounter()

        let result = TrashService(trashOperation: { _ in
            counter.increment()
            throw CocoaError(.fileNoSuchFile)
        }).moveToTrash([item], allCandidates: [item], inside: root)

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDuplicateCleanupRequiresAnUnchangedCopyToRemain() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data("identical bytes".utf8).write(to: first)
        try Data("identical bytes".utf8).write(to: second)
        let result = try await FileScanner().scan(
            ScanRequest(root: root, kind: .duplicates, minimumFileSizeBytes: 1, oldFileAgeDays: 365),
            progress: { _ in }
        )
        let counter = CallCounter()

        let cleanup = TrashService(trashOperation: { _ in
            counter.increment()
            throw CocoaError(.fileNoSuchFile)
        }).moveToTrash(result.items, allCandidates: result.items, inside: root)

        XCTAssertTrue(cleanup.moved.isEmpty)
        XCTAssertEqual(cleanup.failures.count, 2)
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testMismatchedTrashResultIsReportedAsAFailure() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("candidate.bin")
        try Data("original reviewed content".utf8).write(to: file)
        let item = try await scannedItem(at: file, inside: root)
        let unrelated = root.appendingPathComponent("unrelated.bin")
        try Data("different file".utf8).write(to: unrelated)

        let result = TrashService(trashOperation: { _ in unrelated })
            .moveToTrash([item], allCandidates: [item], inside: root)

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func scannedItem(at file: URL, inside root: URL) async throws -> ScanItem {
        let result = try await FileScanner().scan(
            ScanRequest(root: root, kind: .largeAndOld, minimumFileSizeBytes: 1, oldFileAgeDays: 365),
            progress: { _ in }
        )
        XCTAssertEqual(result.items.count, 1)
        return try XCTUnwrap(result.items.first)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleanerTrashService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
