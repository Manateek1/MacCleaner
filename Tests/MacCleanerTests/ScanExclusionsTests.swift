import Foundation
import XCTest
@testable import MacCleaner

final class ScanExclusionsTests: XCTestCase {
    func testStoreNormalizesDuplicateAndNestedExclusions() throws {
        let parent = try temporaryFolder()
        let child = parent.appendingPathComponent("large-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let defaults = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScanExclusionStore(defaults: defaults)

        XCTAssertEqual(try store.add(child), [child.path])
        XCTAssertEqual(try store.add(parent), [parent.path])
        XCTAssertEqual(try store.add(child), [parent.path])
        XCTAssertEqual(ScanExclusionStore(defaults: defaults).paths, [parent.path])
    }

    func testDiskRootCannotBeExcluded() {
        let defaults = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScanExclusionStore(defaults: defaults)

        XCTAssertThrowsError(try store.add(URL(fileURLWithPath: "/", isDirectory: true))) { error in
            XCTAssertEqual(error as? ScanExclusionError, .cannotExcludeDiskRoot)
        }
    }

    func testExclusionMatchingUsesPathComponentBoundaries() {
        let exclusion = "/Users/tester/Downloads/Movies"

        XCTAssertEqual(
            ScanExclusionPolicy.matchingNormalizedExclusion(for: "\(exclusion)/clip.mov", in: [exclusion]),
            exclusion
        )
        XCTAssertNil(ScanExclusionPolicy.matchingNormalizedExclusion(
            for: "/Users/tester/Downloads/Movies-old/clip.mov",
            in: [exclusion]
        ))
    }

    func testRemovePersistsUpdatedExclusions() throws {
        let folder = try temporaryFolder()
        let defaults = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScanExclusionStore(defaults: defaults)

        _ = try store.add(folder)
        XCTAssertTrue(store.remove(folder.path).isEmpty)
        XCTAssertTrue(ScanExclusionStore(defaults: defaults).paths.isEmpty)
    }

    private let suiteName = "MacCleaner.ScanExclusionsTests.\(UUID().uuidString)"

    private func testDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCleaner-Exclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
