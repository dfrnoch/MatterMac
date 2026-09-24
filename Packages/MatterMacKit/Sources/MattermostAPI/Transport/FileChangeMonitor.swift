import Darwin
import Foundation
import os

/// A read-only descriptor for a user-selected upload source plus the identity and
/// size observed when it was opened. Nothing is copied or staged.
struct FileSnapshot: Sendable {
    let descriptor: Int32
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int

    static func open(_ url: URL) throws(APIError) -> FileSnapshot {
        guard url.isFileURL else { throw .localFileUnavailable }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw .localFileUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw .localFileUnavailable
        }
        return FileSnapshot(descriptor: fd, device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                            modificationSeconds: info.st_mtimespec.tv_sec, modificationNanoseconds: info.st_mtimespec.tv_nsec)
    }

    var revision: String { "\(device):\(inode):\(size):\(modificationSeconds):\(modificationNanoseconds)" }

    func close() { Darwin.close(descriptor) }

    private func matches(_ info: stat) -> Bool {
        Int64(info.st_dev) == device && UInt64(info.st_ino) == inode && Int64(info.st_size) == size
            && info.st_mtimespec.tv_sec == modificationSeconds && info.st_mtimespec.tv_nsec == modificationNanoseconds
    }

    /// Whether both the pinned descriptor and the file currently at `path` are still
    /// the same, unmodified file.
    func isUnchanged(atPath path: String) -> Bool {
        var viaDescriptor = stat()
        guard fstat(descriptor, &viaDescriptor) == 0, matches(viaDescriptor) else { return false }
        var viaPath = stat()
        guard stat(path, &viaPath) == 0 else { return false }
        return matches(viaPath)
    }
}

/// Watches an upload source for writes, growth, deletion, rename or revocation while
/// Foundation streams it, so a changing file fails promptly (`.localFileUnavailable`)
/// instead of stalling until a timeout (measured: truncating the file mid-upload
/// otherwise ends in a -1001 timeout) or silently sending mixed content.
///
/// Owns the snapshot's descriptor: it is closed by the dispatch source's cancel
/// handler, as Dispatch requires.
final class FileChangeMonitor: Sendable {
    private let source: OSAllocatedUnfairLock<(any DispatchSourceFileSystemObject)?>

    init(snapshot: FileSnapshot, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: snapshot.descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        let fired = OSAllocatedUnfairLock(initialState: false)
        source.setEventHandler {
            let first = fired.withLock { value -> Bool in
                defer { value = true }
                return !value
            }
            if first { onChange() }
        }
        let descriptor = snapshot.descriptor
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = OSAllocatedUnfairLock(initialState: source)
    }

    /// Stops monitoring and closes the descriptor. Idempotent.
    func cancel() {
        let source = self.source.withLock { current -> (any DispatchSourceFileSystemObject)? in
            defer { current = nil }
            return current
        }
        source?.cancel()
    }

    deinit { cancel() }
}
