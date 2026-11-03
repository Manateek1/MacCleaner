import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacCleaner

final class SimilarPhotoScannerTests: XCTestCase {
    func testIdenticalImagesMatchAndCorruptAndSymlinkAreSkipped() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = try imageData(inverted: false)
        try data.write(to: root.appendingPathComponent("one.png"))
        try data.write(to: root.appendingPathComponent("two.png"))
        try imageData(inverted: true).write(to: root.appendingPathComponent("different.png"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("corrupt.png"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: root.appendingPathComponent("one.png"))
        let result = try SimilarPhotoScanner().scan(root: root, maximumDistance: 2) { _ in }
        XCTAssertEqual(result.inspected, 4)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].photos.map(\.fileName)), Set(["one.png", "two.png"]))
        XCTAssertEqual(result.groups[0].matchKind, .exactCopies)
        XCTAssertTrue(result.groups[0].explanation.contains("identical contents"))
        XCTAssertFalse(result.truncated)
        let group = result.groups[0]
        let first = group.photos[0], keep = group.photos[1]
        XCTAssertTrue(SimilarPhotoSafety.hasUnchangedSurvivors(groups: [group], selected: [first.path], root: root))
        XCTAssertFalse(SimilarPhotoSafety.hasUnchangedSurvivors(groups: [group], selected: Set(group.photos.map(\.path)), root: root))
        try Data("changed".utf8).write(to: keep.url)
        XCTAssertFalse(SimilarPhotoSafety.hasUnchangedSurvivors(groups: [group], selected: [first.path], root: root))
    }

    func testLimitReturnsPartialResults() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = try imageData(inverted: false)
        for n in 0..<3 { try data.write(to: root.appendingPathComponent("\(n).png")) }
        let result = try SimilarPhotoScanner(maximumPhotos: 2).scan(root: root, maximumDistance: 0) { _ in }
        XCTAssertEqual(result.inspected, 2)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.groups.first?.photos.count, 2)
    }

    func testRecompressedImageIsRecognizedAsSimilar() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let png = try imageData(inverted: false)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        try png.write(to: root.appendingPathComponent("original.png"))
        try png.write(to: root.appendingPathComponent("original-copy.png"))
        try jpeg.write(to: root.appendingPathComponent("recompressed.jpg"))
        let result = try SimilarPhotoScanner().scan(root: root, maximumDistance: 6) { _ in }
        XCTAssertEqual(result.groups.first?.photos.count, 3)
        XCTAssertEqual(result.groups.first?.matchKind, .visualMatchesWithExactCopies)
    }

    func testExactCopyVerificationReportsItsReadBudget() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = try imageData(inverted: false)
        try data.write(to: root.appendingPathComponent("one.png"))
        try data.write(to: root.appendingPathComponent("two.png"))

        let result = try SimilarPhotoScanner(maximumExactHashBytes: 1).scan(root: root, maximumDistance: 0) { _ in }

        XCTAssertTrue(result.exactVerificationLimited)
        XCTAssertEqual(result.groups.first?.matchKind, .visualMatches)
        XCTAssertEqual(result.groups.first?.photos.count, 2)
    }

    func testOversizedImageIsSkippedWithoutReadingItsContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("oversized.png")
        let descriptor = image.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_RDWR, mode_t(0o600)) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(Darwin.ftruncate(descriptor, off_t(256 * 1024 * 1024 + 1)), 0)

        let result = try SimilarPhotoScanner().scan(root: root, maximumDistance: 0) { _ in }

        XCTAssertEqual(result.inspected, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testDiskScanPrioritizesPersonalFoldersAndSkipsLibrary() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("Users/alex", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let data = try imageData(inverted: false)
        for folder in ["Pictures", "Desktop", "Downloads", "Documents", "Library/Android"] {
            let directory = home.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("photo.png"))
        }
        let result = try SimilarPhotoScanner(maximumPhotos: 4, accountHome: home).scan(root: root, maximumDistance: 0, scanEntireDisk: true) { _ in }
        XCTAssertEqual(result.inspected, 4)
        let paths = Set(result.groups.flatMap(\.photos).map(\.path))
        XCTAssertEqual(paths.count, 4)
        XCTAssertEqual(Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }), Set(["Pictures", "Desktop", "Downloads", "Documents"]))
        XCTAssertFalse(paths.contains { $0.contains("/Library/") })
    }

    func testGroupingDoesNotChainAndExcludesHardLinks() throws {
        func photo(_ name: String, _ bits: UInt64, _ inode: UInt64, colorPixels: [UInt8] = []) -> SimilarPhoto {
            SimilarPhoto(path: "/tmp/\(name).png", identity: FileIdentity(device: 1, inode: inode, size: 1, modifiedAt: 1, linkCount: 1), width: 100, height: 100, hash: bits, average: 100, pixels: [UInt8](repeating: 100, count: 72), colorPixels: colorPixels, createdAt: nil)
        }
        let result = try SimilarPhotoScanner.group([photo("a", 0, 1), photo("b", 1, 2), photo("c", 3, 3), photo("d", 0, 1)], maximumDistance: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].photos.map(\.fileName), ["a.png", "b.png"])
    }

    func testColorSamplesRejectGrayscaleHashFalsePositivesAndAllowSmallColorChanges() throws {
        func photo(_ name: String, _ inode: UInt64, color: (UInt8, UInt8, UInt8)) -> SimilarPhoto {
            var colorPixels: [UInt8] = []
            colorPixels.reserveCapacity(72 * 3)
            for _ in 0..<72 {
                colorPixels.append(contentsOf: [color.0, color.1, color.2])
            }
            return SimilarPhoto(
                path: "/tmp/\(name).png",
                identity: FileIdentity(device: 1, inode: inode, size: 1, modifiedAt: 1, linkCount: 1),
                width: 100,
                height: 100,
                hash: 0,
                average: 100,
                pixels: [UInt8](repeating: 100, count: 72),
                colorPixels: colorPixels,
                createdAt: nil
            )
        }

        let unrelatedColors = try SimilarPhotoScanner.group([
            photo("red", 1, color: (220, 30, 20)),
            photo("blue", 2, color: (20, 30, 220))
        ], maximumDistance: 0)
        XCTAssertTrue(unrelatedColors.isEmpty)

        let mildColorShift = try SimilarPhotoScanner.group([
            photo("warm", 3, color: (220, 30, 20)),
            photo("warm-edited", 4, color: (212, 37, 28))
        ], maximumDistance: 0)
        XCTAssertEqual(mildColorShift.count, 1)
        XCTAssertEqual(mildColorShift[0].photos.count, 2)
    }

    func testPhotoExtensionsFollowAvailableImageIODecodersWithNonPhotoTypesExcluded() {
        let available = ImageIOPhotoTypePolicy.supportedExtensions
        XCTAssertTrue(Set(["jpg", "jpeg", "png"]).isSubset(of: available))

        let identifiers = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        let expected = Set(identifiers.flatMap { identifier -> [String] in
            guard !ImageIOPhotoTypePolicy.excludedTypeIdentifiers.contains(identifier),
                  let type = UTType(identifier), type.conforms(to: .image) else { return [] }
            return type.tags[.filenameExtension]?.map { $0.lowercased() } ?? []
        })
        XCTAssertEqual(available, expected)
        XCTAssertTrue(available.isDisjoint(with: ["pdf", "dcm", "dicom", "icns", "ico", "dds", "astc", "ktx", "pvr", "heics", "mpo"]))

        for identifier in ["com.adobe.photoshop-image", "com.truevision.tga-image", "com.apple.pict"] where identifiers.contains(identifier) {
            let extensions = Set(UTType(identifier)?.tags[.filenameExtension]?.map { $0.lowercased() } ?? [])
            XCTAssertFalse(available.isDisjoint(with: extensions), "Expected ImageIO's \(identifier) decoder to be considered.")
        }
    }

    func testAdditionalImageIOFormatCanBeComparedWhenItsDecoderIsAvailable() throws {
        guard ImageIOPhotoTypePolicy.supportedExtensions.contains("tga") else {
            throw XCTSkip("This macOS version does not register an ImageIO TGA decoder.")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = tgaImageData()
        try data.write(to: root.appendingPathComponent("first.tga"))
        try data.write(to: root.appendingPathComponent("second.tga"))

        let result = try SimilarPhotoScanner().scan(root: root, maximumDistance: 2) { _ in }

        XCTAssertEqual(result.inspected, 2)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.matchKind, .exactCopies)
    }

    func testRegisteredImageIOOutputFormatsCanBeCompared() async throws {
        let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let formats = writableTypes.compactMap { identifier -> (identifier: String, fileExtension: String)? in
            guard !ImageIOPhotoTypePolicy.excludedTypeIdentifiers.contains(identifier),
                  let type = UTType(identifier), type.conforms(to: .image),
                  let fileExtension = type.tags[.filenameExtension]?.map({ $0.lowercased() })
                    .filter({ ImageIOPhotoTypePolicy.supportedExtensions.contains($0) })
                    .sorted().first else { return nil }
            return (identifier, fileExtension)
        }.sorted { $0.identifier < $1.identifier }

        guard !formats.isEmpty else {
            throw XCTSkip("This macOS version does not expose a writable ImageIO photo format.")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (index, format) in formats.enumerated() {
            let folder = root.appendingPathComponent("format-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 32,
                pixelsHigh: 32,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            for y in 0..<32 {
                for x in 0..<32 {
                    let offset = y * bitmap.bytesPerRow + x * 4
                    pixels[offset] = UInt8((x * 17 + y * 3 + index * 61) & 0xff)
                    pixels[offset + 1] = UInt8((x * 5 + y * 19 + index * 97) & 0xff)
                    pixels[offset + 2] = UInt8((x * 11 + y * 7 + index * 137) & 0xff)
                    pixels[offset + 3] = 255
                }
            }

            let first = folder.appendingPathComponent("first.\(format.fileExtension)")
            let second = folder.appendingPathComponent("second.\(format.fileExtension)")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(first as CFURL, format.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination), "ImageIO could not write \(format.identifier).")
            try Data(contentsOf: first).write(to: second)
        }

        let result = try await Task.detached(priority: .utility) {
            try SimilarPhotoScanner().scan(root: root, maximumDistance: 0) { _ in }
        }.value

        XCTAssertEqual(result.inspected, formats.count * 2)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.groups.count, formats.count)
        XCTAssertTrue(result.groups.allSatisfy { $0.photos.count == 2 && $0.matchKind == .exactCopies })
    }

    func testFingerprintRetainsRenderedColorChannels() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<32 {
            for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = 240
                bytes[offset + 1] = 20
                bytes[offset + 2] = 10
                bytes[offset + 3] = 255
            }
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let fingerprint = try XCTUnwrap(VisualPhotoFingerprinting.make(image: image, identifier: "color-test"))

        XCTAssertEqual(fingerprint.colorPixels.count, 9 * 8 * 3)
        XCTAssertGreaterThan(fingerprint.colorPixels[0], 200)
        XCTAssertLessThan(fingerprint.colorPixels[1], 60)
        XCTAssertLessThan(fingerprint.colorPixels[2], 50)
    }

    func testBandIndexFindsMatchesAtMaximumVisualTolerance() throws {
        var hash: UInt64 = 0
        for bit in [0, 8, 16, 24, 1, 9, 17, 25, 32, 40, 48, 56] {
            hash |= UInt64(1) << bit
        }
        func photo(_ name: String, _ bits: UInt64, _ inode: UInt64) -> SimilarPhoto {
            SimilarPhoto(path: "/tmp/\(name).png", identity: FileIdentity(device: 1, inode: inode, size: 1, modifiedAt: 1, linkCount: 1), width: 100, height: 100, hash: bits, average: 100, pixels: [UInt8](repeating: 100, count: 72), createdAt: nil)
        }

        let result = try SimilarPhotoScanner.group([photo("a", 0, 1), photo("b", hash, 2)], maximumDistance: 12)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].photos.count, 2)
    }

    private func imageData(inverted: Bool) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<32 { for x in 0..<32 {
            let value = (x * 7 + y * 11) % 255
            let gray = UInt8(inverted ? 255 - value : value)
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset] = gray; bytes[offset + 1] = gray; bytes[offset + 2] = gray; bytes[offset + 3] = 255
        } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func tgaImageData() -> Data {
        let width = 32
        let height = 32
        var data = Data(repeating: 0, count: 18)
        data[2] = 2 // Uncompressed true-color image.
        data[12] = UInt8(width & 0xff)
        data[13] = UInt8(width >> 8)
        data[14] = UInt8(height & 0xff)
        data[15] = UInt8(height >> 8)
        data[16] = 24
        data[17] = 0x20 // Top-left origin.
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((x * 7 + y * 11) % 255)
                data.append(contentsOf: [value, value, value])
            }
        }
        return data
    }
}
