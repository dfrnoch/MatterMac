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
        case .customEmoji(let id): resource = .customEmoji(id: id); points = 32
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

    /// Opens (or replaces) the in-window viewer for an image attachment, with the
    /// message's other images. Previews are fetched through the same bounded pipeline
    /// and membership checks as thumbnails; the leases are released when it closes.
    func showImageViewer(for file: FileInfo) {
        guard file.isImage, let model, !model.isDetached, let pipeline = model.app?.images else { return }
        imageViewer?.close()
        let post = timeline.items.lazy.compactMap(\.post).first { $0.files.contains { $0.id == file.id } }
        let images = post?.files.filter(\.isImage) ?? [file]
        let content = MediaViewerContent(files: images.isEmpty ? [file] : images,
                                         index: images.firstIndex { $0.id == file.id } ?? 0,
                                         authorName: post.map { $0.author.displayName.isEmpty ? $0.author.username : $0.author.displayName },
                                         timestamp: post?.createdAt)
        let viewer = MediaViewerController(content: content)
        viewer.onSave = { [weak self] file in self?.saveAttachment(file) }
        viewer.onClose = { [weak self, weak viewer] in
            guard let self, imageViewer === viewer else { return }
            imageViewer = nil
        }
        // The timeline's thumbnail lease stays charged while it stands in.
        viewer.placeholder = { [weak self] file in self?.displayedImages[.attachment(file)]?.lease }
        imageViewer = viewer
        let session = model.session, channel = target.channelID
        let fetch: MediaViewerController.Fetch = { [weak model] file, pixels in
            guard model?.isDetached == false else { return nil }
            let resource: MattermostAPI.ImageResource = file.hasPreviewImage ? .filePreview(file.id) : .fileThumbnail(file.id)
            return await session.timelineImage(resource, channel: channel, maxPixelSize: pixels, pipeline: pipeline)
        }
        var avatar: (@MainActor (Int) async -> ImagePipeline.Decoded?)?
        if let author = post?.author {
            avatar = { [weak model] pixels in
                guard model?.isDetached == false else { return nil }
                return await session.profileImage(author.userID, revision: author.avatarRevision, maxPixelSize: pixels,
                                                  pipeline: pipeline)
            }
        }
        viewer.show(in: view.window, budget: environment.budget, fetch: fetch, avatar: avatar)
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
