import Darwin
import Foundation

enum SafeFileAccess {
    static func canonicalDirectoryPath(_ path: String) -> String? {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        return descriptorPath(descriptor)
    }

    static func openDirectoryDescriptor(_ path: String) -> Int32 {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return -1 }
        guard descriptorPath(descriptor) == normalizedPath(path) else {
            Darwin.close(descriptor)
            errno = ELOOP
            return -1
        }
        return descriptor
    }

    static func openRegularFileDescriptor(_ path: String) -> Int32? {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              descriptorPath(descriptor) == normalizedPath(path) else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    static func identity(at path: String) -> FileIdentity? {
        guard let descriptor = openRegularFileDescriptor(path) else { return nil }
        defer { Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { return nil }
        return identity(from: info)
    }

    static func identity(from info: Darwin.stat) -> FileIdentity {
        FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedAt: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
            linkCount: UInt32(info.st_nlink)
        )
    }

    static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Int32(-1) }
            return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
        }
        guard result == 0 else { return nil }
        return normalizedPath(String(cString: buffer))
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
