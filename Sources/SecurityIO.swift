import Foundation
import Darwin

enum SecurityIO {
    static func open(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw VaultError.message("Could not safely open the requested file.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw VaultError.message("Expected a regular file, without a symbolic link.")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let input = try open(url)
        defer { try? input.close() }
        guard try input.seekToEnd() <= UInt64(maximum) else { throw VaultError.message("The file exceeds its safe size limit.") }
        try input.seek(toOffset: 0)
        let bytes = try input.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw VaultError.message("The file exceeds its safe size limit.") }
        return bytes
    }
}
