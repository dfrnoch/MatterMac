public import Foundation

extension UploadSource {
    /// Explicit export of an already budgeted pasted image. The caller obtains a
    /// destination from a save panel; the source remains owned until the write ends.
    /// Uses the download replacement policy: failure keeps any existing file intact.
    @concurrent
    public func exportPastedImage(to destination: URL) async throws(APIError) {
        guard case .memory(let memory) = content else { throw .localFileUnavailable }
        defer { withExtendedLifetime(memory) {} }
        guard !Task.isCancelled else { throw .cancelled }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let staging = try DownloadStaging.prepare(destination: destination)
        do {
            try staging.handle.write(contentsOf: memory.data)
            guard !Task.isCancelled else { throw APIError.cancelled }
            try staging.commit()
        } catch {
            staging.discard()
            throw (error as? APIError) ?? .localFileUnavailable
        }
    }
}
