import AppKit
import MatterMacModels
import MatterMacCore
import MattermostAPI

extension ConversationController {
    func timelineImage(for request: TimelineImageRequest) -> NSImage? { displayedImages[request]?.image }

    func timelineNeedsImage(_ request: TimelineImageRequest) {
        guard imageTasks[request] == nil, displayedImages[request] == nil,
              imageTasks.count + displayedImages.count < environment.budget.outstandingImageRequests,
              let model, !model.isDetached, let pipeline = model.app?.images else { return }
        let resource: MattermostAPI.ImageResource
        let points: CGFloat
        switch request {
        case .avatar(let user, let revision): resource = .profileImage(user, revision: revision); points = TimelineMetrics.avatarSize
        case .thumbnail(let file): resource = .fileThumbnail(file); points = TimelineMetrics.maximumThumbnailSize.width
        case .preview(let file): resource = .filePreview(file); points = TimelineMetrics.maximumThumbnailSize.width
        case .linkPreview(let url):
            // Only rows built with `linkPreviewImages` (server proxy on) ask for these.
            resource = .proxiedImage(url: url); points = TimelineMetrics.maximumThumbnailSize.width
        }
        let pixels = Int((points * (view.window?.backingScaleFactor ?? 2)).rounded(.up))
        let generation = imageGeneration, channel = target.channelID, session = model.session
        imageTasks[request] = Task { [weak self, weak model] in
            let decoded = await session.timelineImage(resource, channel: channel, maxPixelSize: pixels, pipeline: pipeline)
            guard let self, imageGeneration == generation else { return }
            imageTasks[request] = nil
            if Task.isCancelled, timeline.imageDemand[request] != nil, model?.isDetached == false {
                timelineNeedsImage(request)
                return
            }
            guard !Task.isCancelled, model?.isDetached == false, timeline.imageDemand[request] != nil,
                  let decoded else { return }
            // NSImage wraps the existing CGImage; it does not decode another bitmap.
            displayedImages[request] = (decoded, NSImage(cgImage: decoded.image, size: .zero))
            timeline.imageDidBecomeAvailable(request)
        }
    }

    func timelineNoLongerNeedsImage(_ request: TimelineImageRequest) {
        imageTasks[request]?.cancel()
        displayedImages[request] = nil
    }

    /// Opens (or replaces) the in-memory viewer for an image attachment. The preview
    /// is fetched through the same bounded pipeline and membership checks as
    /// thumbnails; the lease is released when the viewer closes.
    func showImageViewer(for file: FileInfo) {
        guard file.isImage, let model, !model.isDetached, let pipeline = model.app?.images else { return }
        imageViewer?.close()
        let viewer = ImageViewerWindowController(file: file)
        viewer.onSave = { [weak self] file, window in self?.saveAttachment(file, in: window) }
        viewer.onClose = { [weak self, weak viewer] in
            guard let self, imageViewer === viewer else { return }
            imageViewer = nil
        }
        imageViewer = viewer
        let session = model.session, channel = target.channelID
        let resource: MattermostAPI.ImageResource = file.hasPreviewImage ? .filePreview(file.id) : .fileThumbnail(file.id)
        viewer.show(over: view.window, budget: environment.budget) { [weak model] pixels in
            guard model?.isDetached == false else { return nil }
            return await session.timelineImage(resource, channel: channel, maxPixelSize: pixels, pipeline: pipeline)
        }
    }

    func clearImages() {
        imageViewer?.close()
        imageGeneration &+= 1
        // Cells release their NSImage before the final budget lease is released.
        timeline.clearDisplayedImages()
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
        displayedImages.removeAll()
    }
}
