import Darwin
import Foundation

struct SpaceLensFile: Identifiable, Equatable, Sendable {
    let path: String
    let size: Int64
    let modifiedAt: Date

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
    var fileType: SpaceFileType { SpaceFileType.classify(fileExtension: url.pathExtension) }
}

struct SpaceLensDirectoryContents: Equatable, Sendable {
    let files: [SpaceLensFile]
    let entriesVisited: Int
    let skippedItems: Int
    let wasTruncated: Bool
}

enum SpaceLensDirectoryError: Error, Equatable {
    case outsideScannedLocation
    case cannotReadFolder
}

enum SpaceLensDirectoryReader {
    static let defaultEntryLimit = 50_000

    /// Reads direct-file metadata only. Folder traversal is constrained to the
    /// scan root and opens every path component without following symlinks.
    static func readFiles(
        in folderURL: URL,
        within rootURL: URL,
        maximumEntries: Int = defaultEntryLimit
    ) throws -> SpaceLensDirectoryContents {
        let folderPath = folderURL.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        guard folderPath == rootPath || SafeFilePolicy.isInside(folderPath, root: rootPath),
              !SafeFilePolicy.containsProtectedPathComponent(folderPath),
              !SafeFilePolicy.isEssentialSystemLocation(folderPath) else {
            throw SpaceLensDirectoryError.outsideScannedLocation
        }

        let rootDescriptor = rootPath.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { throw SpaceLensDirectoryError.cannotReadFolder }

        var directoryDescriptor = rootDescriptor
        let relativePath: String
        if folderPath == rootPath {
            relativePath = ""
        } else {
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard folderPath.hasPrefix(prefix) else {
                Darwin.close(rootDescriptor)
                throw SpaceLensDirectoryError.outsideScannedLocation
            }
            relativePath = String(folderPath.dropFirst(prefix.count))
        }

        for component in relativePath.split(separator: "/") {
            let nextDescriptor = component.withCString {
                Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard nextDescriptor >= 0 else {
                Darwin.close(directoryDescriptor)
                throw SpaceLensDirectoryError.cannotReadFolder
            }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        guard let directoryHandle = Darwin.fdopendir(directoryDescriptor) else {
            Darwin.close(directoryDescriptor)
            throw SpaceLensDirectoryError.cannotReadFolder
        }
        defer { Darwin.closedir(directoryHandle) }

        let entryLimit = max(0, maximumEntries)
        var entriesVisited = 0
        var skippedItems = 0
        var wasTruncated = false
        var files: [SpaceLensFile] = []

        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(directoryHandle) else {
                if errno != 0 { skippedItems += 1 }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            guard entriesVisited < entryLimit else {
                wasTruncated = true
                break
            }
            entriesVisited += 1

            let itemPath = URL(fileURLWithPath: folderPath, isDirectory: true)
                .appendingPathComponent(name)
                .standardizedFileURL.path
            guard URL(fileURLWithPath: itemPath).deletingLastPathComponent().standardizedFileURL.path == folderPath,
                  SafeFilePolicy.isInside(itemPath, root: rootPath),
                  !SafeFilePolicy.containsProtectedPathComponent(itemPath),
                  !SafeFilePolicy.isEssentialSystemLocation(itemPath) else {
                skippedItems += 1
                continue
            }

            var info = Darwin.stat()
            let status = name.withCString {
                Darwin.fstatat(Darwin.dirfd(directoryHandle), $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                skippedItems += 1
                continue
            }

            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFLNK) {
                skippedItems += 1
                continue
            }
            guard type == mode_t(S_IFREG) else { continue }

            files.append(SpaceLensFile(
                path: itemPath,
                size: max(0, Int64(info.st_size)),
                modifiedAt: Date(
                    timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                )
            ))
        }

        files.sort {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return SpaceLensDirectoryContents(
            files: files,
            entriesVisited: entriesVisited,
            skippedItems: skippedItems,
            wasTruncated: wasTruncated
        )
    }
}
