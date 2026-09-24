import Darwin
import Foundation

/// Partial-output handling for an explicit, user-chosen download destination
/// (SPEC §7 "Explicit user actions", §14 "Files").
///
/// Policy:
/// 1. Bytes are streamed into a new hidden sibling file
///    `.<name>.<random>.mattermac-partial` in the destination's directory, created
///    with `O_CREAT | O_EXCL | O_NOFOLLOW` and mode 0600.
/// 2. On success the file is set to mode 0644 and atomically `rename(2)`d onto the
///    destination (same directory, hence same volume; an existing destination the
///    user agreed to replace in the save panel is replaced atomically).
/// 3. On failure or cancellation the partial file is removed; the destination is
///    untouched.
/// 4. Fallback: if the sibling cannot be created because the directory is not
///    writable for us (`EACCES`/`EPERM`, e.g. a sandbox extension that covers only the
///    chosen file), a new destination may be created directly and removed on failure. An existing
///    destination is never truncated by this fallback; saving fails safely instead.
struct DownloadStaging: Sendable {
    let destination: URL
    let partialURL: URL
    let handle: FileHandle
    let writesInPlace: Bool

    static func prepare(destination: URL) throws(APIError) -> DownloadStaging {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else { throw .localFileUnavailable }
        let directory = destination.deletingLastPathComponent()
        let base = String(destination.lastPathComponent.prefix(180))
        let suffix = String(UInt64.random(in: UInt64.min...UInt64.max), radix: 16)
        let partial = directory.appendingPathComponent(".\(base).\(suffix).mattermac-partial", isDirectory: false)

        let fd = openFile(partial, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode: 0o600)
        if fd >= 0 {
            return DownloadStaging(destination: destination, partialURL: partial,
                                   handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), writesInPlace: false)
        }
        let reason = errno
        guard reason == EACCES || reason == EPERM else { throw .localFileUnavailable }
        let direct = openFile(destination, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode: 0o644)
        guard direct >= 0 else { throw .localFileUnavailable }
        return DownloadStaging(destination: destination, partialURL: destination,
                               handle: FileHandle(fileDescriptor: direct, closeOnDealloc: true), writesInPlace: true)
    }

    private static func openFile(_ url: URL, flags: Int32, mode: mode_t) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, flags, mode)
        }
    }

    /// Flushes, closes and moves the finished file into place.
    func commit() throws(APIError) {
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            discard()
            throw .localFileUnavailable
        }
        guard !writesInPlace else { return }
        let moved = partialURL.withUnsafeFileSystemRepresentation { from -> Bool in
            destination.withUnsafeFileSystemRepresentation { to -> Bool in
                guard let from, let to else { return false }
                _ = chmod(from, 0o644)
                return rename(from, to) == 0
            }
        }
        guard moved else {
            removePartial()
            throw .localFileUnavailable
        }
    }

    /// Closes and removes partial output. Safe to call more than once.
    func discard() {
        try? handle.close()
        removePartial()
    }

    private func removePartial() {
        partialURL.withUnsafeFileSystemRepresentation { path in
            if let path { _ = unlink(path) }
        }
    }
}
