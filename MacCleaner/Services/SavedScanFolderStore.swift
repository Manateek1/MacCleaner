import Foundation

struct SavedScanFolder: Identifiable, Equatable, Sendable {
    let path: String

    var id: String { path }
    var name: String { URL(fileURLWithPath: path, isDirectory: true).lastPathComponent }
}

struct SavedScanFolderResolution: Sendable {
    let url: URL
    let isStale: Bool
}

enum SavedScanFolderError: LocalizedError, Equatable {
    case diskRoot
    case notDirectory

    var errorDescription: String? {
        switch self {
        case .diskRoot: "Scan This Mac already covers the disk root, so it cannot be added as a folder shortcut."
        case .notDirectory: "Choose a folder that still exists on this Mac."
        }
    }
}

struct SavedScanFolderStore {
    typealias BookmarkResolver = (Data) throws -> SavedScanFolderResolution

    private let key: String
    private let defaults: UserDefaults
    private let createBookmark: (URL) throws -> Data
    private let resolveBookmark: BookmarkResolver

    init(
        defaults: UserDefaults = .standard,
        key: String = "MacCleaner.savedScanFolders.v1",
        createBookmark: @escaping (URL) throws -> Data = { url in
            try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolveBookmark: @escaping BookmarkResolver = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return SavedScanFolderResolution(url: url, isStale: isStale)
        }
    ) {
        self.defaults = defaults
        self.key = key
        self.createBookmark = createBookmark
        self.resolveBookmark = resolveBookmark
    }

    var folders: [SavedScanFolder] {
        bookmarkMap.keys
            .map { SavedScanFolder(path: $0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func add(_ folderURL: URL) throws -> [SavedScanFolder] {
        let folder = folderURL.standardizedFileURL
        guard folder.path != "/" else { throw SavedScanFolderError.diskRoot }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SavedScanFolderError.notDirectory
        }

        var map = bookmarkMap
        map[folder.path] = try createBookmark(folderURL).base64EncodedString()
        defaults.set(map, forKey: key)
        return folders
    }

    func resolve(_ path: String) throws -> SavedScanFolderResolution? {
        guard let encoded = bookmarkMap[path], let data = Data(base64Encoded: encoded) else { return nil }
        let resolution = try resolveBookmark(data)
        let folder = resolution.url.standardizedFileURL
        guard folder.path != "/" else { throw SavedScanFolderError.diskRoot }
        return SavedScanFolderResolution(url: folder, isStale: resolution.isStale || folder.path != path)
    }

    func refresh(_ oldPath: String, with folderURL: URL) throws -> [SavedScanFolder] {
        let folder = folderURL.standardizedFileURL
        guard folder.path != "/" else { throw SavedScanFolderError.diskRoot }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SavedScanFolderError.notDirectory
        }
        var map = bookmarkMap
        map.removeValue(forKey: oldPath)
        map[folder.path] = try createBookmark(folderURL).base64EncodedString()
        defaults.set(map, forKey: key)
        return folders
    }

    func remove(_ path: String) -> [SavedScanFolder] {
        var map = bookmarkMap
        map.removeValue(forKey: path)
        defaults.set(map, forKey: key)
        return folders
    }

    private var bookmarkMap: [String: String] {
        (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
}
