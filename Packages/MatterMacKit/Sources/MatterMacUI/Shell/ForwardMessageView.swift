import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

@Observable
final class ForwardMessageModel: Identifiable, ComposerViewControllerDelegate {
    let id = UUID()
    let context: MessageForwardContext
    let composer: ComposerViewController
    let key: DraftKey
    private let environment: AppEnvironment
    private weak var session: SessionViewModel?
    var query = "" {
        didSet { if query != oldValue { selection = nil; search() } }
    }
    var selection: QuickSwitchItem.Kind?
    private(set) var results: [QuickSwitchItem] = []
    private(set) var isSearching = false
    private(set) var isSending = false
    var error: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    private var isClosed = false

    init(session: SessionViewModel, context: MessageForwardContext) throws {
        guard let environment = session.app?.environment else { throw UserFacingError.authenticationRequired }
        self.session = session
        self.environment = environment
        self.context = context
        key = DraftKey(scope: session.scope, channelID: context.channelID, rootID: nil, forwardingPostID: context.postID)
        composer = ComposerViewController(budget: environment.budget, diagnostics: environment.diagnostics)
        composer.placeholder = String(localized: "Add a comment (optional)")
        composer.sendBehavior = .commandReturnSends
        composer.isSendAllowed = false
        composer.isAttachmentSelectionAllowed = false
        composer.maximumMessageCharacters = max(0, context.maximumPostCharacters - context.permalink.absoluteString.unicodeScalars.count - 1)
        let saved = environment.drafts.draft(for: key)?.text ?? ""
        // The last line is our permalink. A DM's team context can change between
        // presentations; keep its comment when the newly generated link differs.
        let comment = saved.lastIndex(of: "\n").map { String(saved[..<$0]) } ?? ""
        try environment.drafts.save(Draft(text: context.message(comment: comment)), for: key)
        composer.load(draft: Draft(text: comment))
        composer.delegate = self
        if context.isPrivate { selection = .channel(context.channelID) }
    }

    deinit { searchTask?.cancel(); sendTask?.cancel() }

    var canForward: Bool { selection != nil && !isSending && !isClosed }

    func search() {
        guard !context.isPrivate, !isClosed else { return }
        searchTask?.cancel()
        let term = query
        isSearching = true
        searchTask = Task { [weak self] in
            if !term.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, let self, let session else { return }
            let found = await session.quickSwitcherResults(term)
            guard !Task.isCancelled, !isClosed else { return }
            results = found.filter { !$0.isArchived }
            isSearching = false
        }
    }

    func saveDraft() throws {
        guard !isClosed, !isSending else { return }
        try environment.drafts.save(Draft(text: context.message(comment: composer.text)), for: key)
    }

    func forward() {
        guard canForward, let selection, let session, !session.isDetached, !session.requiresAuthentication else { return }
        do { try saveDraft() }
        catch { self.error = "The draft limit has been reached. Your comment has been kept."; return }
        let comment = composer.text
        isSending = true
        composer.textView.isEditable = false
        error = nil
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer { isSending = false; composer.textView.isEditable = !isClosed; sendTask = nil }
            do {
                let channel: ChannelID
                switch selection {
                case .channel(let id): channel = id
                case .user(let id): channel = try await session.session.conversation(with: [id])
                }
                guard !Task.isCancelled, !isClosed, !session.isDetached, !session.requiresAuthentication else { return }
                let reservation = try environment.drafts.takeForSending(key)
                do {
                    try await session.session.enqueueForward(context.postID, to: channel, comment: comment, reservation: reservation)
                    environment.drafts.finishSending(key, reservation: reservation, accepted: true)
                } catch {
                    environment.drafts.finishSending(key, reservation: reservation, accepted: false)
                    throw error
                }
                if !isClosed, !session.isDetached, !session.requiresAuthentication {
                    close(discard: false)
                    session.select(channel: channel)
                }
            } catch {
                guard !isClosed else { return }
                self.error = (error as? UserFacingError).map(UserFacingErrorText.describe)
                    ?? (error as? ServerSession.SendRejection).map(ConversationController.sendRejectionText)
                    ?? "The message could not be forwarded. Your comment has been kept."
            }
        }
    }

    /// Cancel explicitly discards this forwarding draft. Forced dismissal keeps it
    /// available to reopen or copy through Unsent Recovery.
    func close(discard: Bool) {
        guard !isClosed else { return }
        if !isSending { try? saveDraft() }
        isClosed = true
        searchTask?.cancel()
        sendTask?.cancel()
        composer.textView.isEditable = false
        composer.dismissTransientUI()
        if discard { environment.drafts.clear(key) }
        if session?.forwardMessage === self { session?.forwardMessage = nil }
    }

    func composerDraftDidChange() { composerUserDidType() }
    func composerUserDidType() {
        do { try saveDraft() }
        catch { self.error = "The draft limit has been reached. Your comment has been kept." }
    }
    func composerRemainingDraftBytes() -> Int {
        environment.drafts.remainingBytes(for: key) - composer.draftByteCount
            - context.permalink.absoluteString.utf8.count - 1
    }
    func composerDidRefuseInput(_ refusal: ComposerRefusal) { error = "Input exceeds a message or session memory limit. Your comment has been kept." }
    func composerDidRequestSend(text: String) { forward() }
    func composerDidPressEscape() { if !isSending { close(discard: true) } }
    func composerDidRequestCancelMode() {}
    func composerRequestsEditLastMessage() {}
    func composerDidPasteImage(data: Data, typeIdentifier: String) -> Bool { false }
    func composerDidReceiveFiles(_ urls: [URL]) {}
    func composerRequestsFileSelection() {}
    func composerDidRemoveAttachment(id: String) {}
}

struct ForwardMessageView: View {
    @Bindable var model: ForwardMessageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forward Message").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: model.context.channelName).font(.headline)
                Text(verbatim: model.context.preview.isEmpty ? String(localized: "Message with attachments") : model.context.preview)
                    .lineLimit(4).foregroundStyle(.secondary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if model.context.isPrivate {
                Label("This message is from a private conversation and can only be shared in its original conversation.", systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Search channels or people", text: Binding(get: { model.query }, set: { model.query = String($0.prefix(64)) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Forward to channel or person")
                    .disabled(model.isSending)
                List(selection: $model.selection) {
                    ForEach(model.results) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.title)
                                if !item.subtitle.isEmpty { Text(verbatim: item.subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: {
                            Image(systemName: item.channelType == .open ? "number" : item.channelType == .private ? "lock" : "person")
                        }.tag(item.kind)
                    }
                }
                .frame(height: 180)
                .overlay {
                    if model.results.isEmpty {
                        if model.isSearching { ProgressView("Finding conversations…") }
                        else { Text("No conversations found. Try another channel or person.").foregroundStyle(.secondary).padding() }
                    }
                }
                .disabled(model.isSending)
            }
            ComposerView(controller: model.composer)
            if let error = model.error { Text(verbatim: error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Shares a link to the original message. Access to the original is required to view it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.isSending { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.close(discard: true) }.keyboardShortcut(.cancelAction).disabled(model.isSending)
                Button("Forward") { model.forward() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canForward)
            }
        }
        .padding(20).frame(width: 520)
        .interactiveDismissDisabled(model.isSending)
        .onAppear { model.search() }
        .onDisappear { model.close(discard: false) }
    }
}
