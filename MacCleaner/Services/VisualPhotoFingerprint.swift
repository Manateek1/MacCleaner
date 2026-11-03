import CoreGraphics
import Foundation

struct VisualPhotoFingerprint: Sendable {
    let identifier: String
    let width: Int
    let height: Int
    let hash: UInt64
    let average: UInt8
    let pixels: [UInt8]
    let colorPixels: [UInt8]
    let duplicateIdentity: String?
    let createdAt: Date?

    init(
        identifier: String,
        width: Int,
        height: Int,
        hash: UInt64,
        average: UInt8,
        pixels: [UInt8],
        colorPixels: [UInt8] = [],
        duplicateIdentity: String?,
        createdAt: Date?
    ) {
        self.identifier = identifier
        self.width = width
        self.height = height
        self.hash = hash
        self.average = average
        self.pixels = pixels
        self.colorPixels = colorPixels
        self.duplicateIdentity = duplicateIdentity
        self.createdAt = createdAt
    }
}

enum VisualPhotoFingerprinting {
    static func make(
        image: CGImage,
        identifier: String,
        width: Int? = nil,
        height: Int? = nil,
        duplicateIdentity: String? = nil,
        createdAt: Date? = nil
    ) -> VisualPhotoFingerprint? {
        var pixels = [UInt8](repeating: 0, count: 72)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 9,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 9,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            context.flush()
            return true
        }
        guard success else { return nil }

        // Keep a compact RGB sample beside the grayscale perceptual hash. The
        // hash is good at finding similar shapes, but by itself can confuse
        // unrelated images with similar light and dark patterns.
        var colorBytes = [UInt8](repeating: 0, count: 9 * 8 * 4)
        let colorSuccess = colorBytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 9,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 9 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            context.flush()
            return true
        }
        guard colorSuccess else { return nil }
        var colorPixels = [UInt8](repeating: 0, count: 9 * 8 * 3)
        for pixel in 0..<(9 * 8) {
            colorPixels[pixel * 3] = colorBytes[pixel * 4]
            colorPixels[pixel * 3 + 1] = colorBytes[pixel * 4 + 1]
            colorPixels[pixel * 3 + 2] = colorBytes[pixel * 4 + 2]
        }

        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                hash = (hash << 1) | (pixels[y * 9 + x] > pixels[y * 9 + x + 1] ? 1 : 0)
            }
        }
        let average = UInt8(pixels.reduce(0) { $0 + Int($1) } / pixels.count)
        return VisualPhotoFingerprint(
            identifier: identifier,
            width: width ?? image.width,
            height: height ?? image.height,
            hash: hash,
            average: average,
            pixels: pixels,
            colorPixels: colorPixels,
            duplicateIdentity: duplicateIdentity,
            createdAt: createdAt
        )
    }
}

enum VisualPhotoMatcher {
    static func groups(_ photos: [VisualPhotoFingerprint], maximumDistance: Int) throws -> [[VisualPhotoFingerprint]] {
        let ordered = photos.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
        let threshold = min(64, max(0, maximumDistance))
        var buckets: [UInt16: [Int]] = [:]
        for index in ordered.indices {
            for band in 0..<8 {
                let byte = UInt8((ordered[index].hash >> UInt64(band * 8)) & 0xff)
                buckets[bucketKey(band: band, byte: byte), default: []].append(index)
            }
        }

        var assigned = Set<Int>()
        var groups: [[VisualPhotoFingerprint]] = []
        for index in ordered.indices {
            try Task.checkCancellation()
            guard !assigned.contains(index) else { continue }
            var members = [ordered[index]]
            var possibleMatches = Set<Int>()
            if threshold <= 12 {
                for band in 0..<8 {
                    let byte = UInt8((ordered[index].hash >> UInt64(band * 8)) & 0xff)
                    if let matches = buckets[bucketKey(band: band, byte: byte)] {
                        possibleMatches.formUnion(matches)
                    }
                    for bit in 0..<8 {
                        let neighbor = byte ^ UInt8(1 << bit)
                        if let matches = buckets[bucketKey(band: band, byte: neighbor)] {
                            possibleMatches.formUnion(matches)
                        }
                    }
                }
            } else {
                possibleMatches.formUnion(ordered.indices.filter { $0 > index })
            }

            for candidate in possibleMatches.sorted() where candidate > index && !assigned.contains(candidate) {
                try Task.checkCancellation()
                let left = ordered[index]
                let right = ordered[candidate]
                if let identity = left.duplicateIdentity, identity == right.duplicateIdentity { continue }
                let ratioLeft = Double(left.width) / Double(max(1, left.height))
                let ratioRight = Double(right.width) / Double(max(1, right.height))
                guard abs(log(ratioLeft / ratioRight)) < 0.12,
                      abs(Int(left.average) - Int(right.average)) <= 20,
                      (left.hash ^ right.hash).nonzeroBitCount <= threshold,
                      left.pixels.count == 72,
                      right.pixels.count == 72 else { continue }
                let difference = zip(left.pixels, right.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                guard difference <= 72 * 15 else { continue }
                if left.colorPixels.count == 72 * 3, right.colorPixels.count == 72 * 3 {
                    let colorDifference = zip(left.colorPixels, right.colorPixels).reduce(0) {
                        $0 + abs(Int($1.0) - Int($1.1))
                    }
                    guard colorDifference <= 72 * 3 * 36 else { continue }
                }
                assigned.insert(candidate)
                members.append(right)
            }
            if members.count > 1 {
                assigned.insert(index)
                groups.append(members)
            }
        }
        return groups
    }

    private static func bucketKey(band: Int, byte: UInt8) -> UInt16 {
        UInt16(band << 8) | UInt16(byte)
    }
}
