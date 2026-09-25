import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore
import MattermostAPI

struct FileSearchResults: View {
    let session: SessionViewModel
    @State private var actions = FileSearchActions()

    var body: some View {
        VStack(spacing: 0) {
            if let error = actions.error { Text(UserFacingErrorText.describe(error)).foregroundStyle(.red).padding() }
            if actions.saving {
                HStack { ProgressView().controlSize(.small); Text("Saving…"); Button("Cancel") { actions.cancel() } }.padding()
            }
            if let search = session.search, !search.files.isEmpty {
                List {
                    ForEach(search.files) { file in
                        HStack(alignment: .top, spacing: 10) {
                            FileSearchThumbnail(session: session, file: file)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: file.name).lineLimit(2).textSelection(.enabled)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let channel = file.channelID, let name = search.fileChannelNames[channel] {
                                    Text(name).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(file.createAt.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    if file.isImage { Button("Preview") { actions.preview(file, session: session) }.disabled(file.channelID == nil) }
                                    Button("Save…") { actions.save(file, session: session) }.disabled(actions.saving || file.channelID == nil)
                                    Button("Jump to Message") {
                                        if let channel = file.channelID, let post = file.postID { session.select(channel: channel, focusing: post) }
                                    }.disabled(file.channelID == nil || file.postID == nil)
                                }.buttonStyle(.borderless).font(.caption)
                            }
                        }.padding(.vertical, 5)
                    }
                    if search.canLoadMore { Button("Load More") { session.loadMoreSearchResults() } }
                    if search.isTruncated { Text("Result limit reached. Narrow your search.").font(.caption).foregroundStyle(.secondary) }
                }.listStyle(.inset)
            } else {
                ContentUnavailableView("No Files", systemImage: "doc", description: Text("Try different words or fewer filters."))
            }
        }
        .onChange(of: session.search?.files.map(\.id)) {
            actions.retainFiles(Set(session.search?.files.map(\.id) ?? []))
        }
        .onDisappear { actions.close() }
        .onChange(of: session.isDetached) { if session.isDetached { actions.close() } }
    }
}

private struct FileSearchThumbnail: View {
    let session: SessionViewModel
    let file: FileInfo
    @State private var decoded: ImagePipeline.Decoded?

    var body: some View {
        Group {
            if let decoded { Image(nsImage: NSImage(cgImage: decoded.image, size: .zero)).resizable().scaledToFit() }
            else { Image(systemName: file.isImage ? "photo" : "doc").font(.title2).foregroundStyle(.secondary) }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
        .task(id: file.id) {
            guard file.isImage, let channel = file.channelID, let pipeline = session.app?.images else { return }
            let image = await session.session.timelineImage(.fileThumbnail(file.id), channel: channel, maxPixelSize: 88, pipeline: pipeline)
            if !Task.isCancelled { decoded = image }
        }
        .onDisappear { decoded = nil }
    }
}

@MainActor @Observable
final class FileSearchActions {
    var saving = false
    var error: UserFacingError?
    private var task: Task<Void, Never>?
    private(set) var viewer: ImageViewerWindowController?
    private var panel: NSSavePanel?
    private var savingFile: FileID?

    func preview(_ file: FileInfo, session: SessionViewModel) {
        guard let channel = file.channelID, let app = session.app, !session.isDetached else { return }
        viewer?.close()
        let viewer = ImageViewerWindowController(file: file)
        self.viewer = viewer
        viewer.onSave = { [weak self, weak session] file, _ in
            guard let session else { return }
            self?.save(file, session: session)
        }
        viewer.show(over: NSApp.keyWindow, budget: app.environment.budget) { [weak session] pixels in
            guard let session, !session.isDetached else { return nil }
            return await session.session.timelineImage(file.hasPreviewImage ? .filePreview(file.id) : .fileThumbnail(file.id),
                channel: channel, maxPixelSize: pixels, pipeline: app.images)
        }
    }

    func save(_ file: FileInfo, session: SessionViewModel) {
        guard !saving, panel == nil, let channel = file.channelID, !session.isDetached else { return }
        let panel = NSSavePanel()
        self.panel = panel
        savingFile = file.id
        panel.nameFieldStringValue = file.name
        panel.begin { [weak self, weak session] response in
            guard let self else { return }
            self.panel = nil
            guard response == .OK, let url = panel.url, let session, !session.isDetached else { return }
            saving = true
            error = nil
            task = Task { [weak self] in
                defer { self?.saving = false; self?.task = nil }
                do throws(UserFacingError) { try await session.session.downloadAttachment(file.id, channel: channel, to: url) }
                catch { if error != .cancelled { self?.error = error } }
            }
        }
    }

    /// A revocation can remove one row while the results pane stays mounted.
    func retainFiles(_ ids: Set<FileID>) {
        if let viewer, !ids.contains(viewer.file.id) {
            viewer.close()
            self.viewer = nil
        }
        if let savingFile, !ids.contains(savingFile) {
            cancel()
            panel?.cancel(nil)
            panel = nil
            self.savingFile = nil
        }
    }

    func cancel() { task?.cancel() }
    func close() { cancel(); panel?.cancel(nil); panel = nil; viewer?.close(); viewer = nil }
}
