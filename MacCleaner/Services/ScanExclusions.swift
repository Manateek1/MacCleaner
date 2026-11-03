import Foundation

enum ScanExclusionError: Error, Equatable {
    case cannotExcludeDiskRoot
}

enum ScanExclusionPolicy {
    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    static func normalized(_ paths: some Sequence<String>) -> [String] {
        let candidates = Set(paths.map(standardizedPath).filter { $0 != "/" })
            .sorted {
                if $0.count != $1.count { return $0.count < $1.count }
                return $0.localizedStandardCompare($1) == .orderedAscending
            }
        var result: [String] = []
        for candidate in candidates {
            guard !result.contains(where: { contains(candidate, root: $0) }) else { continue }
            result.append(candidate)
        }
        return result.sorted()
    }

    static func matchingExclusion(for path: String, in exclusions: some Sequence<String>) -> String? {
        matchingNormalizedExclusion(for: path, in: normalized(exclusions))
    }

    static func matchingNormalizedExclusion(for path: String, in normalizedExclusions: [String]) -> String? {
        let candidate = standardizedPath(path)
        return normalizedExclusions.first { contains(candidate, root: $0) }
    }

    private static func contains(_ path: String, root: String) -> Bool {
        path == root || SafeFilePolicy.isInside(path, root: root)
    }
}

struct ScanExclusionStore {
    private let key = "MacCleaner.scanExclusions.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var paths: [String] {
        ScanExclusionPolicy.normalized(defaults.stringArray(forKey: key) ?? [])
    }

    func add(_ folderURL: URL) throws -> [String] {
        let path = folderURL.standardizedFileURL.path
        guard path != "/" else { throw ScanExclusionError.cannotExcludeDiskRoot }
        let updated = ScanExclusionPolicy.normalized(paths + [path])
        defaults.set(updated, forKey: key)
        return updated
    }

    func remove(_ path: String) -> [String] {
        let normalizedPath = ScanExclusionPolicy.standardizedPath(path)
        let updated = paths.filter { $0 != normalizedPath }
        defaults.set(updated, forKey: key)
        return updated
    }
}
