// KronosCore/Secrets/AtomicSecretFile: replaces a user-only file so that no reader ever sees an
// empty or half-written one.
//
// The bridge process reads the bearer token and the endpoint file while the app may be rewriting
// them (a token regeneration, a port change). Truncating the target and then writing leaves a
// window in which a reader gets an empty token and fails closed, or a torn JSON. Here the bytes
// go into a fresh 0600 file in the same folder (created O_EXCL, mode set before any byte is
// written), are flushed, and replace the target with one rename(2), which is atomic on the same
// volume. A failure at any step removes the temp file and leaves the previous file untouched.
import Foundation

enum AtomicSecretFile {

    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        // Dot-prefixed so the fixed secret names (letters, digits, `_`, `-`) can never collide.
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        func closeOnce() { if !closed { close(fd); closed = true } }

        do {
            // The umask can only remove bits from the mode above; fchmod makes 0600 exact.
            guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            closeOnce()
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            closeOnce()
            unlink(temp.path)
            throw error
        }
    }
}
