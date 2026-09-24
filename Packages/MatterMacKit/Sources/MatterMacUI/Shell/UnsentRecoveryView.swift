import AppKit
import SwiftUI
import Observation
import MatterMacModels
import MatterMacCore
import MatterMacPlatform
import MattermostAPI

/// Snapshots share attachment ownership with Core; closing releases every snapshot.
@Observable
final class UnsentRecoveryModel {
    private weak var session: SessionViewModel?
    private(set) var draftItems: [DraftRecoveryItem] = []
    private(set) var sendItems: [PendingRecoveryItem] = []
    private(set) var isBusy = false
    var status: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var isClosed = false

    init(session: SessionViewModel) { self.session = session }

    func perform(_ action: @escaping @MainActor () async -> Void) {
        guard task == nil, !isClosed else { return }
        task = Task { [weak self] in
            defer { self?.task = nil }
            await action()
        }
    }

    func close() {
        isClosed = true
        task?.cancel()
        draftItems = []; sendItems = []
    }

    func refresh() async {
        guard !isBusy, !isClosed else { return }
        isBusy = true
        defer { isBusy = false }
        await load()
    }

    private func load() async {
        guard let session, !session.isDetached, !isClosed else { return }
        session.saveDrafts()
        let pending = await session.session.recoverySends()
        guard !Task.isCancelled, !session.isDetached, !isClosed else { return }
        draftItems = session.app?.environment.drafts.recoveryDrafts(for: session.scope) ?? []
        sendItems = pending
    }

    @discardableResult
    func discardDraft(_ item: DraftRecoveryItem) async -> Bool {
        guard !isBusy, !isClosed, let session, !session.isDetached else { return false }
        isBusy = true
        defer { isBusy = false }
        session.saveDrafts()
        let discarded = session.app?.environment.drafts.discardRecoveryDraft(item) == true
        if discarded { session.discardDraftEditingState(for: item.id) }
        status = discarded ? "Draft discarded." : "This item changed or is being sent. Review the refreshed list before discarding."
        await load()
        return discarded
    }

    @discardableResult
    func discardSend(_ item: PendingRecoveryItem) async -> Bool {
        guard !isBusy, !isClosed, let session, !session.isDetached else { return false }
        isBusy = true
        defer { isBusy = false }
        let discarded = await session.session.discardRecoverySend(item)
        status = discarded ? "Local unsent item discarded. This does not delete any message already received by the server."
            : "This item changed or is being sent. Review the refreshed list before discarding."
        await load()
        return discarded
    }

    @discardableResult
    func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !isClosed, session?.isDetached == false, !text.isEmpty else { return false }
        pasteboard.clearContents()
        let copied = pasteboard.setString(text, forType: .string)
        status = copied ? "Text copied. Check the server before resending an interrupted message."
            : "The text could not be copied. Your unsent work remains in this session."
        return copied
    }

    func copyDraft(_ item: DraftRecoveryItem) async {
        await refresh()
        guard let current = draftItems.first(where: { $0.id == item.id }), current.draft == item.draft else {
            status = "This draft changed. Review the refreshed list before copying."
            return
        }
        copy(current.draft.text)
    }

    func copySend(_ item: PendingRecoveryItem) async {
        await refresh()
        guard let current = sendItems.first(where: { $0.id == item.id }) else {
            status = "This send is no longer pending. Check the server for the message."
            return
        }
        copy(current.message)
    }

    func export(_ source: UploadSource) async {
        guard !isBusy, !isClosed, source.memoryBytes > 0 else { return }
        isBusy = true
        defer { isBusy = false }
        guard let destination = FilePanels.chooseDownloadDestination(suggestedName: source.fileName) else { return }
        await load()
        let isRetained = draftItems.contains { $0.draft.attachments.contains(source) }
            || sendItems.contains { $0.attachments.contains { $0.source == source } }
        guard !Task.isCancelled, !isClosed, session?.isDetached == false, isRetained else {
            status = "This attachment is no longer in the unsent list. No file was exported."
            return
        }
        do {
            try await source.exportPastedImage(to: destination)
            status = "Pasted image exported. The original remains with its unsent item."
        } catch {
            if !Task.isCancelled { status = "The image could not be exported. Your unsent work remains in this session." }
        }
    }
}

struct UnsentRecoveryView: View {
    let session: SessionViewModel
    @State private var model: UnsentRecoveryModel
    @Environment(\.dismiss) private var dismiss

    init(session: SessionViewModel) {
        self.session = session
        _model = State(initialValue: UnsentRecoveryModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unsent Work").font(.title2.weight(.semibold))
            Text("Drafts and unconfirmed sends stay in memory until you sign out or quit. Interrupted sends may already be on the server; check before resending.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                Section("Drafts") {
                    ForEach(model.draftItems) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title(channel: item.id.channelID, root: item.id.rootID, kind: item.draft.editingPost == nil ? "Draft" : "Edited message"))
                                .font(.headline)
                            summary(text: item.draft.text, attachments: item.draft.attachments.count)
                            if !item.canDiscard { Text("Being submitted — discard is unavailable.").font(.caption) }
                            HStack {
                                Button("Copy Text") { model.perform { await model.copyDraft(item) } }
                                    .disabled(item.draft.text.isEmpty)
                                    .accessibilityLabel("Copy text from " + title(channel: item.id.channelID, root: item.id.rootID, kind: "draft"))
                                Button("Discard…", role: .destructive) {
                                    guard confirmDiscard(isDraft: true) else { return }
                                    model.perform { await model.discardDraft(item) }
                                }.disabled(!item.canDiscard)
                            }
                            attachments(item.draft.attachments)
                        }.padding(.vertical, 6)
                    }
                    if model.draftItems.isEmpty { Text("No drafts.").foregroundStyle(.secondary) }
                }
                Section("Unconfirmed Sends") {
                    ForEach(model.sendItems) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title(channel: item.channelID, root: item.rootID, kind: "Send")).font(.headline)
                            Text(sendState(item.state)).font(.caption).foregroundStyle(.secondary)
                            summary(text: item.message, attachments: item.attachments.count)
                            HStack {
                                Button("Copy Text") { model.perform { await model.copySend(item) } }
                                    .disabled(item.message.isEmpty)
                                    .accessibilityLabel("Copy text from " + title(channel: item.channelID, root: item.rootID, kind: "unconfirmed send"))
                                Button("Discard…", role: .destructive) {
                                    guard confirmDiscard(isDraft: false) else { return }
                                    model.perform { await model.discardSend(item) }
                                }.disabled(!item.canDiscard)
                            }
                            attachments(item.attachments.map(\.source))
                        }.padding(.vertical, 6)
                    }
                    if model.sendItems.isEmpty { Text("No unconfirmed sends.").foregroundStyle(.secondary) }
                }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("unsentRecoveryList")
            if let status = model.status { Text(status).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Refresh") { model.perform { await model.refresh() } }.disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { await model.refresh() }
        .onDisappear { model.close() }
    }

    private func title(channel: ChannelID, root: PostID?, kind: String) -> String {
        let channelName = session.sidebar?.sections.lazy.flatMap(\.rows).first(where: { $0.channelID == channel })?.displayName
            ?? "Channel …" + channel.rawValue.suffix(8)
        return kind + " · " + channelName + (root.map { " · Thread …" + $0.rawValue.suffix(8) } ?? "")
    }

    private func summary(text: String, attachments: Int) -> some View {
        Text("\(text.count) characters · \(attachments) attachments").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func attachments(_ sources: [UploadSource]) -> some View {
        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
            if source.memoryBytes > 0 {
                Button("Export Pasted Image \(index + 1)…") { model.perform { await model.export(source) } }
            }
        }
        if sources.contains(where: { $0.memoryBytes == 0 }) {
            Text("Selected files remain at their original locations.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func confirmDiscard(isDraft: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isDraft ? "Discard this draft?" : "Discard this local unsent item?"
        alert.informativeText = "Its text and attachments will be removed from this session. Export anything you need first. This cannot undo a message or upload already received by the server."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func sendState(_ state: PendingSend.State) -> String {
        switch state {
        case .queued: "Queued"
        case .uploading: "Uploading — discard is unavailable"
        case .sending: "Sending — discard is unavailable"
        case .failed: "Failed — not confirmed by the server"
        case .outcomeUnknown: "Outcome unknown — may already be on the server"
        }
    }
}
