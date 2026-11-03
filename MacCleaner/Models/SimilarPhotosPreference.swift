import Foundation

enum SimilarPhotosPreference {
    static let storageKey = "MacCleaner.similarPhotos.matchTolerance.v1"
    static let defaultValue = 6.0
    static let allowedRange = 0.0...12.0

    static func normalizedTolerance(_ value: Double) -> Int {
        guard value.isFinite else { return Int(defaultValue) }
        return Int(min(max(value, allowedRange.lowerBound), allowedRange.upperBound).rounded())
    }

    static func label(for value: Double) -> String {
        let tolerance = normalizedTolerance(value)
        if tolerance < 4 { return "Strict" }
        if tolerance < 9 { return "Balanced" }
        return "More matches"
    }
}
