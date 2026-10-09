import Foundation
import Darwin

/// OS-owned advisory lease. Never unlink lock files: that would create a second inode.
final class SharedLibraryLease: Sendable {
    private let descriptor: Int32

    init(at url: URL, wait: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let operation = LOCK_EX | LOCK_NB
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while flock(fd, operation) != 0 {
            let code = errno
            if code == EINTR { continue }
            if wait, code == EWOULDBLOCK, ContinuousClock.now < deadline {
                usleep(10_000)
                continue
            }
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
