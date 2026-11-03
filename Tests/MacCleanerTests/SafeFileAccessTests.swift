import Darwin
import Foundation
import XCTest
@testable import MacCleaner

final class SafeFileAccessTests: XCTestCase {
    func testCanonicalDirectoryPathMatchesTheOpenedDescriptorPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let canonicalPath = try XCTUnwrap(SafeFileAccess.canonicalDirectoryPath(directory.path))
        let descriptor = SafeFileAccess.openDirectoryDescriptor(canonicalPath)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "the temporary test directory should be openable")
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        XCTAssertEqual(SafeFileAccess.descriptorPath(descriptor), canonicalPath)
    }

    func testFileOpenRejectsAPathWhoseParentWasReplacedByASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actualDirectory = root.appendingPathComponent("actual", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
        let actualFile = actualDirectory.appendingPathComponent("sample.txt")
        try Data("sample".utf8).write(to: actualFile)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: actualDirectory)

        XCTAssertNil(SafeFileAccess.openRegularFileDescriptor(aliasDirectory.appendingPathComponent("sample.txt").path))

        let descriptor = try XCTUnwrap(SafeFileAccess.openRegularFileDescriptor(actualFile.path))
        Darwin.close(descriptor)
    }

    func testDirectoryOpenRejectsAPathWhoseParentWasReplacedByASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actualDirectory = root.appendingPathComponent("actual", isDirectory: true)
        let childDirectory = actualDirectory.appendingPathComponent("child", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: actualDirectory)

        XCTAssertEqual(SafeFileAccess.openDirectoryDescriptor(aliasDirectory.appendingPathComponent("child").path), -1)

        let descriptor = SafeFileAccess.openDirectoryDescriptor(childDirectory.path)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        Darwin.close(descriptor)
    }
}
