public import CoreGraphics
public import Foundation
import ImageIO
import os
public import MatterMacModels
public import MattermostAPI

/// Process-wide bounded image pipeline (SPEC §14 Image pipeline, §15).
///
/// - Fetches server thumbnails/previews/avatars into memory with a per-object
///   compressed-size limit; never writes to disk; never fetches third-party URLs.
/// - Checks source pixel dimensions from metadata *before* decoding, reserves the
///   downsampled output's conservative size against the decoded budget, and
///   downsamples with Image I/O to the requested display pixel size (orientation
///   applied; never upscaled).
/// - Retains decoded images in a strict cost-tracked LRU (cost = bytesPerRow × height)
///   and never keeps compressed bytes after decoding.
/// - At most `imageDecodesGlobal` decodes run at once and at most
///   `outstandingImageRequests` requests are in flight; beyond that, new requests
///   are refused (the cell shows its placeholder and may ask again later).
public actor ImagePipeline {
    public struct Key: Hashable, Sendable {
        public let scope: AccountScope
        public let resource: ImageResource
        /// Longest edge in device pixels.
        public let maxPixelSize: Int

        public init(scope: AccountScope, resource: ImageResource, maxPixelSize: Int) {
            self.scope = scope
            self.resource = resource
            self.maxPixelSize = maxPixelSize
        }
    }

    /// Cache entries, returned task results and displayed rows share this ownership.
    /// Evicting the cache cannot uncharge an image still held by a visible cell.
    public final class Decoded: Sendable {
        public let image: CGImage
        public let byteCost: Int
        private let release: @Sendable () -> Void
        init(_ image: CGImage, release: @escaping @Sendable () -> Void) {
            self.image = image
            byteCost = image.bytesPerRow * image.height
            self.release = release
        }
        deinit { release() }
    }
    private struct Flight {
        let task: Task<Decoded?, Never>
        var waiters: Set<UUID>
    }
    private var decoded: CostLRU<Key, Decoded>
    private var failures: CostLRU<Key, Bool>
    private var inflight: [Key: Flight] = [:]
    private let budget: ResourceBudget
    private let decodeGate: AsyncGate
    private let retainedBytes = OSAllocatedUnfairLock(initialState: 0)
    private let diagnostics: DiagnosticRing

    public init(budget: ResourceBudget, diagnostics: DiagnosticRing) {
        self.budget = budget
        self.decoded = CostLRU(countLimit: budget.decodedImageEntries, costLimit: budget.decodedImageBytes)
        self.failures = CostLRU(countLimit: budget.imageFailureEntries, costLimit: budget.imageFailureEntries)
        self.decodeGate = AsyncGate(limit: max(1, min(budget.imageDecodesGlobal,
            budget.compressedImageBytes / max(1, budget.compressedImagePerObjectBytes))),
            maximumWaiters: budget.outstandingImageRequests)
        self.diagnostics = diagnostics
    }

    public func cached(_ key: Key) -> Decoded? { decoded.value(for: key) }
    public var decodedBytes: Int { retainedBytes.withLock { $0 } }
    public var decodedCount: Int { decoded.count }
    public var inflightCount: Int { inflight.count }

    public func image(for key: Key, using service: any MattermostService) async -> Decoded? {
        guard !Task.isCancelled else { return nil }
        if let hit = decoded.value(for: key) { return hit }
        if failures.contains(key) { return nil }
        let waiter = UUID()
        let task: Task<Decoded?, Never>
        if var flight = inflight[key] {
            guard !flight.task.isCancelled, flight.waiters.count < budget.outstandingImageRequests else { return nil }
            task = flight.task
            flight.waiters.insert(waiter)
            inflight[key] = flight
        } else {
            guard inflight.count < budget.outstandingImageRequests else { return nil }
            task = Task { await fetch(key, using: service) }
            inflight[key] = Flight(task: task, waiters: [waiter])
        }
        let image = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { await self.cancelWaiter(waiter, key: key) }
        }
        if var flight = inflight[key] {
            flight.waiters.remove(waiter)
            inflight[key] = flight.waiters.isEmpty ? nil : flight
        }
        guard !Task.isCancelled, !task.isCancelled else { return nil }
        if let image { decoded.set(image, for: key, cost: image.byteCost) }
        return image
    }

    private func cancelWaiter(_ waiter: UUID, key: Key) {
        guard var flight = inflight[key] else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty { flight.task.cancel() }
        inflight[key] = flight
    }

    private func fetch(_ key: Key, using service: any MattermostService) async -> Decoded? {
        guard await decodeGate.enter() else { return nil }
        let result = await fetchAdmitted(key, using: service)
        await decodeGate.leave()
        return result
    }

    private func fetchAdmitted(_ key: Key, using service: any MattermostService) async -> Decoded? {
        guard !Task.isCancelled else { return nil }
        let maximumBytes = min(budget.compressedImagePerObjectBytes, budget.compressedImageBytes)
        guard let data = try? await service.imageData(key.resource, maximumBytes: maximumBytes), !Task.isCancelled else {
            if !Task.isCancelled { failures.set(true, for: key, cost: 1) }
            return nil
        }
        guard data.count <= maximumBytes else { failures.set(true, for: key, cost: 1); return nil }
        // Source metadata is read before anything is decoded; the reservation is the
        // conservative size of the downsampled output, never the source.
        let edge = min(key.maxPixelSize, budget.maximumImagePixelDimension)
        guard let plan = Self.decodePlan(data, maxPixelSize: edge, maximumSourcePixels: budget.maximumSourceImagePixels),
              plan.reservedBytes <= min(budget.maximumDecodedImageBytes, budget.decodedImageBytes) else {
            failures.set(true, for: key, cost: 1)
            return nil
        }
        let reservation = plan.reservedBytes
        // Keep displayed images charged while evicting unused cache entries to make room.
        while retainedBytes.withLock({ $0 + reservation > budget.decodedImageBytes }), !decoded.isEmpty {
            _ = decoded.removeLeastRecentlyUsed()
        }
        let admitted = retainedBytes.withLock { bytes in
            guard bytes + reservation <= budget.decodedImageBytes else { return false }
            bytes += reservation
            return true
        }
        guard admitted else { return nil } // Saturation is not a permanent failed resource.
        guard let image = await Self.downsample(data, maxPixelSize: plan.maxPixelSize,
                                                maximumSourcePixels: budget.maximumSourceImagePixels),
              !Task.isCancelled, image.bytesPerRow * image.height <= reservation else {
            retainedBytes.withLock { $0 -= reservation }
            if !Task.isCancelled { failures.set(true, for: key, cost: 1) }
            return nil
        }
        let cost = image.bytesPerRow * image.height
        retainedBytes.withLock { $0 -= reservation - cost }
        let counter = retainedBytes
        return Decoded(image) { counter.withLock { $0 -= cost } }
    }

    /// In-flight cancellation prevents late responses from repopulating the cache.
    public func purge(scope: AccountScope) {
        decoded.removeAll { key, _ in key.scope == scope }
        failures.removeAll { key, _ in key.scope == scope }
        for (key, flight) in inflight where key.scope == scope { flight.task.cancel() }
    }

    /// Memory pressure: discard decoded images first (SPEC §15 pressure policy).
    public func trim(toFraction fraction: Double) {
        decoded.trim(toCost: Int(Double(budget.decodedImageBytes) * max(0, min(1, fraction))))
    }

    /// What decoding `data` at `maxPixelSize` will produce, from source metadata only.
    public struct DecodePlan: Equatable, Sendable {
        /// Longest edge requested from Image I/O (never above the source's longest edge).
        public let maxPixelSize: Int
        /// Upper bound of the decoded bitmap: output pixels (plus one pixel of rounding
        /// per edge) at 4 bytes (8-bit sources) or 8 bytes (deeper sources) each, plus
        /// 64 bytes of row alignment per row.
        public let reservedBytes: Int
    }

    /// Reads only the source properties. `nil` for undecodable data, missing
    /// dimensions, or sources above `maximumSourcePixels`.
    public static func decodePlan(_ data: Data, maxPixelSize: Int, maximumSourcePixels: Int) -> DecodePlan? {
        guard maxPixelSize > 0, maximumSourcePixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow,
              width * height <= maximumSourcePixels
        else { return nil }
        let longest = max(width, height)
        let edge = min(maxPixelSize, longest)
        let scale = Double(edge) / Double(longest)
        let outWidth = Int((Double(width) * scale).rounded(.up)) + 1
        let outHeight = Int((Double(height) * scale).rounded(.up)) + 1
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let bytesPerPixel = depth > 8 ? 8 : 4
        // Orientation may swap the edges; alignment is charged for the longer one.
        let rows = max(outWidth, outHeight)
        return DecodePlan(maxPixelSize: edge, reservedBytes: outWidth * outHeight * bytesPerPixel + rows * 64)
    }

    /// Downsamples encoded image data to at most `maxPixelSize` on the longest edge,
    /// refusing sources larger than `maximumSourcePixels` before decoding.
    @concurrent
    public static func downsample(_ data: Data, maxPixelSize: Int, maximumSourcePixels: Int) async -> CGImage? {
        guard maxPixelSize > 0, maximumSourcePixels > 0 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, !width.multipliedReportingOverflow(by: height).overflow,
              width * height <= maximumSourcePixels
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        // Animated images: only the first frame is decoded (paused by default).
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// A counting gate with a bounded waiter queue. `enter()` returns `false` instead of
/// queueing when `maximumWaiters` are already waiting.
public actor AsyncGate {
    private let limit: Int
    private let maximumWaiters: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    public init(limit: Int, maximumWaiters: Int) {
        self.limit = max(1, limit)
        self.maximumWaiters = max(0, maximumWaiters)
    }

    public func enter() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            return true
        }
        guard waiters.count < maximumWaiters else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }

    public func leave() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot directly to the next waiter.
            waiters.removeFirst().1.resume(returning: true)
        }
    }

    public var activeCount: Int { active }
    public var waitingCount: Int { waiters.count }
}
