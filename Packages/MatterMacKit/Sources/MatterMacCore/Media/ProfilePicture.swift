public import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
public import MatterMacModels

/// Reads a user-selected source in place. The only retained result is a bounded PNG;
/// no staging file, bookmark or disk image cache is created.
public enum ProfilePicture {
    @concurrent public static func prepare(_ url: URL, budget: ResourceBudget = ResourceBudget()) async throws(UserFacingError) -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard !Task.isCancelled, url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0,
              size <= budget.profilePictureSourceBytes else { throw .fileUnavailable }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= budget.maximumSourceImagePixels / height else { throw .fileUnavailable }
        let edge = max(1, min(budget.profilePictureEdge, 512))
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw .fileUnavailable }
        let side = min(thumbnail.width, thumbnail.height)
        guard let square = thumbnail.cropping(to: CGRect(x: (thumbnail.width - side) / 2,
            y: (thumbnail.height - side) / 2, width: side, height: side)) else { throw .fileUnavailable }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        else { throw .fileUnavailable }
        CGImageDestinationAddImage(destination, square, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= budget.profilePictureUploadBytes,
              !Task.isCancelled else { throw .fileUnavailable }
        return encoded as Data
    }
}
