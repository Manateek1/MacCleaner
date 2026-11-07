import Darwin
import Foundation

enum FullDiskAccessProbe {
    static func hasAccess(
        homeDirectory: URL = SafeFilePolicy.accountHome,
        openDirectory: @Sendable (String) -> Bool = { canOpenDirectory($0) }
    ) -> Bool {
        let expectedPaths = ["Documents", "Downloads"].compactMap { name -> String? in
            let path = homeDirectory.appendingPathComponent(name, isDirectory: true).path
            var info = Darwin.stat()
            if path.withCString({ Darwin.lstat($0, &info) }) == 0 { return path }
            return errno == ENOENT || errno == ENOTDIR ? nil : path
        }

        return !expectedPaths.isEmpty && expectedPaths.allSatisfy { canOpenDirectory($0, openDirectory: openDirectory) }
    }

    static func canOpenDirectory(
        _ path: String,
        openDirectory: @Sendable (String) -> Bool = { path in
            let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard descriptor >= 0 else { return false }
            _ = Darwin.close(descriptor)
            return true
        }
    ) -> Bool {
        openDirectory(path)
    }
}
