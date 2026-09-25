import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore
import MatterMacPlatform
import MattermostAPI

struct ConversationView: NSViewControllerRepresentable {
    let session: SessionViewModel
    let target: TimelineTarget
    let snapshot: TimelineSnapshot?

    func makeNSViewController(context: Context) -> ConversationController {
        ConversationController(session: session, target: target)
    }
    func updateNSViewController(_ controller: ConversationController, context: Context) {
        controller.update(target: target, snapshot: snapshot)
    }
    static func dismantleNSViewController(_ controller: ConversationController, coordinator: ()) {
        controller.saveDraft()
        controller.cancelFileWork()
        controller.timeline.removeAllContent()
        controller.composer.dismissTransientUI()
    }
}

/// One bounded pane per visible channel/thread. It reuses the two native controllers
/// and saves the old draft before changing the target.
final class ConversationController: NSViewController, DraftProviding, ComposerViewControllerDelegate,
                                    TimelineViewControllerDelegate {
    weak var model: SessionViewModel?
    let environment: AppEnvironment
    let timeline: TimelineViewController
    let composer: ComposerViewController
    private(set) var target: TimelineTarget
    private var commandTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var typingTask: Task<Void, Never>?
    private var editingPost: PostID?
    private var editingStateDiscarded = false
    var imageTasks: [TimelineImageRequest: Task<Void, Never>] = [:]
    var displayedImages: [TimelineImageRequest: (lease: ImagePipeline.Decoded, image: NSImage)] = [:]
    var imageGeneration: UInt64 = 0
    /// At most one explicitly opened image viewer per pane; closed with the pane's images.
    var imageViewer: ImageViewerWindowController?
    var selectedFiles: [UploadSource] = []
    var selectionTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    var filePanel: NSSavePanel?
    let downloadBar = NSStackView()
    private var composerHeight: NSLayoutConstraint?
    private var reactionPicker: NSPopover?
    private var pendingUserScroll = false

    let scope: AccountScope

    var key: DraftKey {
        DraftKey(scope: scope, channelID: target.channelID, rootID: root)
    }
    var root: PostID? {
        if case .thread(let root, _) = target { return root }
        return nil
    }

    init(session: SessionViewModel, target: TimelineTarget) {
        self.scope = session.scope
        self.model = session
        self.environment = session.app!.environment
        self.target = target
        self.timeline = TimelineViewController(budget: environment.budget,
                                               layoutCaches: session.app!.layoutCaches,
                                               diagnostics: environment.diagnostics)
        self.composer = ComposerViewController(budget: environment.budget, diagnostics: environment.diagnostics)
        super.init(nibName: nil, bundle: nil)
        timeline.delegate = self
        timeline.currentUsername = session.slot.user.username
        // System (Unicode) emoji only; custom emoji keep rendering as `:name:`.
        timeline.emojiLookup = { EmojiCatalog.system.glyph(for: $0) }
        composer.delegate = self
        loadDraft()
        attachDraftProvider()
        bindDisplaySettings()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    deinit { commandTask?.cancel(); sendTask?.cancel(); visibilityTask?.cancel(); typingTask?.cancel(); selectionTask?.cancel(); downloadTask?.cancel(); for task in imageTasks.values { task.cancel() } }

    override func loadView() {
        let drop = ConversationDropView()
        drop.canAcceptFiles = { [weak self] in self?.composer.isAttachmentSelectionAllowed == true }
        drop.onFiles = { [weak self] urls in self?.composerDidReceiveFiles(urls) }
        view = drop
        addChild(timeline)
        addChild(composer)
        let cancel = NSButton(title: "Cancel Download", target: self, action: #selector(cancelDownload(_:)))
        downloadBar.addArrangedSubview(NSTextField(labelWithString: "Saving attachment…"))
        downloadBar.addArrangedSubview(cancel)
        downloadBar.isHidden = true
        let stack = NSStackView(views: [timeline.view, downloadBar, composer.view])
        stack.detachesHiddenViews = true
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let height = composer.view.heightAnchor.constraint(equalToConstant: max(60, composer.preferredHeight))
        composerHeight = height
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor), height,
            // `.width` alignment only equalizes arranged views; pin the composer to the pane.
            composer.view.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        composer.onPreferredHeightChange = { [weak self] in self?.composerHeight?.constant = max(60, $0) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timeline.reloadDisplayedImages()
        // In the Threads view there is no channel pane; the thread pane reports instead.
        if root == nil || model?.isThreadsViewVisible == true {
            model?.updateAppState(isActive: NSApp.isActive, isWindowVisible: view.window?.isVisible == true)
        }
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        clearImages()
        if root == nil, model?.isThreadsViewVisible != true { model?.updateAppState(isActive: false, isWindowVisible: false) }
    }

    func attachDraftProvider() {
        if root == nil { model?.draftProvider = self } else { model?.threadDraftProvider = self }
    }
    func update(target: TimelineTarget, snapshot: TimelineSnapshot?) {
        if self.target != target {
            saveDraft()
            generation &+= 1
            commandTask?.cancel()
            cancelFileWork()
            reactionPicker?.close()
            self.target = target
            loadDraft()
            timeline.removeAllContent()
        }
        attachDraftProvider()
        composer.sendBehavior = environment.sendBehavior == .returnSends ? .returnSends : .commandReturnSends
        updateComposerAvailability()
        if let snapshot, snapshot.target == target { timeline.apply(snapshot) }
    }

    private func loadDraft() {
        guard model?.requiresAuthentication != true else { return }
        editingStateDiscarded = false
        let completionRoot: PostID?
        if case .thread(let root, _) = target { completionRoot = root } else { completionRoot = nil }
        composer.completionProvider = SessionCompletionProvider(model: model, channel: target.channelID, rootID: completionRoot)
        let draft = environment.drafts.draft(for: key) ?? Draft(text: "")
        selectedFiles = draft.attachments
        refreshAttachmentChips()
        editingPost = draft.editingPost
        composer.mode = draft.editingPost.map { .edit(postID: $0, original: "") } ?? .compose
        composer.load(draft: draft)
        updateComposerAvailability()
    }
    func updateComposerAvailability() {
        let busy = environment.drafts.isSubmitting(key)
        composer.textView.isEditable = !editingStateDiscarded && !busy && model?.isDetached == false && model?.requiresAuthentication == false
        composer.isSendAllowed = composer.textView.isEditable && sendTask == nil && selectionTask == nil && model?.header?.canPost != false
        composer.isAttachmentSelectionAllowed = composer.isSendAllowed && editingPost == nil && model?.header?.fileAttachmentsEnabled == true
    }
    func refreshDraft(for key: DraftKey) {
        if self.key == key, !editingStateDiscarded { loadDraft() }
    }
    func discardDraft(for key: DraftKey) {
        guard self.key == key, !editingStateDiscarded else { return }
        // Invalidate pre-admission sends and attachment selections before clearing.
        generation &+= 1
        commandTask?.cancel()
        sendTask?.cancel()
        selectionTask?.cancel()
        loadDraft()
    }
    func saveDraft() {
        guard !editingStateDiscarded, model?.isDetached == false, model?.requiresAuthentication == false, !environment.drafts.isSubmitting(key) else { return }
        var draft = composer.currentDraft()
        draft.editingPost = editingPost
        draft.attachments = selectedFiles
        do { try environment.drafts.save(draft, for: key) }
        catch { model?.inlineError = "The draft count or memory limit has been reached. Keep this conversation open and copy or send the text." }
    }
    func discardEditingState() {
        editingStateDiscarded = true
        generation &+= 1
        commandTask?.cancel()
        sendTask?.cancel()
        visibilityTask?.cancel()
        typingTask?.cancel()
        cancelFileWork()
        selectedFiles = []
        refreshAttachmentChips()
        composer.clear()
        composer.completionProvider = nil
        timeline.removeAllContent()
        editingPost = nil
        updateComposerAvailability()
    }
    func composerDraftDidChange() { saveDraft() }
    func composerRemainingDraftBytes() -> Int {
        guard model != nil else { return 0 }
        return environment.drafts.remainingBytes(for: key) - composer.draftByteCount - (editingPost?.rawValue.utf8.count ?? 0) - Draft(text: "", attachments: selectedFiles).attachmentByteCost
    }
    func composerDidRefuseInput(_ refusal: ComposerRefusal) {
        model?.inlineError = "Input exceeds a message, draft count, or session memory limit. Existing text has been kept."
    }
    func composerDidRequestSend(text: String) {
        guard sendTask == nil, selectionTask == nil, !environment.drafts.isSubmitting(key), let model else { return }
        let key = key, target = target, generation = generation
        let edit = editingPost
        let attachments = selectedFiles
        let isCommand = edit == nil && ServerSession.isSlashCommand(text)
        if isCommand, !attachments.isEmpty {
            model.inlineError = "Slash commands can’t include attachments. Remove the attachments, or start the message with a space to send it as text."
            return
        }
        saveDraft()
        guard environment.drafts.draft(for: key)?.text == text else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                sendTask = nil
                updateComposerAvailability()
            }
            do {
                if edit == nil, !isCommand {
                    try await model.session.validateSend(text: text, channel: target.channelID, attachments: attachments)
                }
                guard !Task.isCancelled, self.generation == generation,
                      composer.text == text, selectedFiles == attachments, await model.session.isActiveSessionAlive else { return }
                // No suspension between the final check and pinning the draft.
                guard !Task.isCancelled, self.generation == generation, composer.text == text, selectedFiles == attachments else { return }
                let reservation = try environment.drafts.takeForSending(key)
                updateComposerAvailability()
                defer {
                    refreshDraft(for: key)
                    model.refreshDraft(for: key)
                }
                do {
                    if let edit { try await model.session.edit(edit, text: text) }
                    else if isCommand {
                        let result = try await model.session.executeCommand(text, channel: target.channelID, rootID: key.rootID)
                        if !Task.isCancelled, self.generation == generation, !model.isDetached,
                           model.selectedChannel == target.channelID, result.isEphemeral, !result.text.isEmpty {
                            model.commandFeedback = result.text
                        }
                    } else {
                        try await model.session.enqueueSend(text: text, channel: target.channelID, rootID: key.rootID,
                                                            attachments: attachments, reservation: reservation)
                    }
                    environment.drafts.finishSending(key, reservation: reservation, accepted: true)
                    // Edits and commands never become pending sends.
                    if edit != nil || isCommand { environment.unsentLedger.release(reservation) }
                } catch {
                    environment.drafts.finishSending(key, reservation: reservation, accepted: false)
                    throw error
                }
            } catch {
                if !Task.isCancelled {
                    model.inlineError = (error as? ServerSession.SendRejection).map(Self.sendRejectionText)
                        ?? (error as? UserFacingError).map(UserFacingErrorText.describe)
                        ?? "The message could not be queued. Your text has been kept."
                }
            }
        }
        updateComposerAvailability()
    }
    func composerDidPressEscape() { composer.dismissTransientUI() }
    func composerDidRequestCancelMode() {
        guard !environment.drafts.isSubmitting(key) else { return }
        editingPost = nil
        composer.mode = .compose
        composer.clear()
        saveDraft()
    }
    func composerRequestsEditLastMessage() {
        run { [weak self] session in
            guard let self, composer.text.isEmpty, let post = await session.lastOwnPost(in: target), !Task.isCancelled else { return }
            beginEditing(post)
        }
    }
    private func beginEditing(_ post: Post) {
        // Only enter editing from an empty composer: a second unaccounted draft is
        // unnecessary. Existing unsent text remains in place.
        guard composer.text.isEmpty, selectedFiles.isEmpty, selectionTask == nil else { model?.inlineError = "Send or save your current draft before editing a message."; return }
        guard post.channelID == target.channelID, !environment.drafts.isSubmitting(key),
              post.message.utf8.count + post.id.rawValue.utf8.count <= composerRemainingDraftBytes() else { return }
        editingPost = post.id
        composer.mode = .edit(postID: post.id, original: post.message)
        composer.load(draft: Draft(text: post.message))
        saveDraft()
        composer.focus()
    }
    func composerUserDidType() {
        saveDraft() // Account immediately; the composer's other callback is coalesced.
        guard typingTask == nil, let session = model?.session else { return }
        let channel = target.channelID, root = root
        typingTask = Task { [weak self] in
            await session.userIsTyping(channel: channel, root: root)
            self?.typingTask = nil
        }
    }
    func timelineRequestsOlder() { run { [target] in await $0.loadOlder(target) } }
    func timelineRequestsNewer() { run { [target] in await $0.loadNewer(target) } }
    func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool) {
        timelineVisibleRangeDidChange(first: first, last: last, isAtLiveEdge: isAtLiveEdge, userScrolled: false)
    }
    func timelineVisibleRangeDidChange(first: PostID?, last: PostID?, isAtLiveEdge: Bool, userScrolled: Bool) {
        // A cancelled report must not lose the "user scrolled" signal.
        let scrolled = userScrolled || pendingUserScroll
        pendingUserScroll = scrolled
        visibilityTask?.cancel()
        guard let session = model?.session else { return }
        visibilityTask = Task { [weak self, target] in
            guard !Task.isCancelled else { return }
            await session.updateVisibility(target: target, first: first, last: last, atLiveEdge: isAtLiveEdge,
                                           userScrolled: scrolled)
            if !Task.isCancelled { self?.pendingUserScroll = false }
        }
    }
    func timeline(perform action: TimelineAction) {
        switch action {
        case .reply(let id), .openThread(let id): model?.openThread(root: id)
        case .openLink(let link):
            // Links into this server open inside MatterMac; everything else in the browser.
            if let model, let serverLink = MattermostLink(url: link.url, endpoint: model.session.endpoint) {
                model.open(serverLink)
            } else {
                ExternalLinks.open(link)
            }
        case .copyLink(let url): Pasteboard.copy(url)
        case .copyText(let id): run { session in if let post = await session.post(id), !Task.isCancelled { Pasteboard.copy(post.message) } }
        case .expand(let id): run { [target] in await $0.expand(id, in: target) }
        case .edit(let id): run { [weak self] session in if let post = await session.post(id), !Task.isCancelled { self?.beginEditing(post) } }
        case .delete(let id):
            if confirm("Delete this message?", detail: "This deletes the message on the Mattermost server.", button: "Delete") {
                run { try await $0.delete(id) }
            }
        case .toggleReaction(let id, let emoji): run { try await $0.toggleReaction(id, emojiName: emoji) }
        case .addReaction(let id):
            reactionPicker?.close()
            reactionPicker = ReactionPickerPresenter.present(for: id, in: timeline, model: model, channel: target.channelID) { [weak self] name in
                self?.run { try await $0.toggleReaction(id, emojiName: name) }
            }
        case .retrySend(let id):
            if confirm("Retry this message?", detail: "If the server received an earlier attempt, retrying may create a duplicate.", button: "Retry") {
                run { await $0.retrySend(id) }
            }
        case .discardSend(let id):
            if confirm("Discard this unsent message?", detail: "This stops any upload and discards the pending text. Files already uploaded may remain on the server.", button: "Discard") {
                run { _ = await $0.discardSend(id) }
            }
        case .retryGap(let direction): direction == .older ? timelineRequestsOlder() : timelineRequestsNewer()
        case .openFile(let file): saveAttachment(file)
        case .previewImage(let file): showImageViewer(for: file)
        case .showProfile(let user): showProfile(.id(user))
        case .mentionTapped(let name):
            // Special mentions (@here, @channel, @all) have no profile.
            if !["here", "channel", "all"].contains(name.lowercased()) { showProfile(.username(name)) }
        case .channelMentionTapped(let name): model?.openChannel(named: name)
        case .markUnread(let id): run { try await $0.markUnread(from: id) }
        case .setPinned(let id, let pinned): run { try await $0.setPinned(id, pinned) }
        case .setSaved(let id, let saved): run { try await $0.setSaved(id, saved) }
        }
    }
    private func showProfile(_ lookup: ProfileLookup) {
        guard let model, !model.isDetached, !model.requiresAuthentication else { return }
        let (anchor, rect) = popoverAnchor()
        ProfilePopover.show(session: model, lookup: lookup, relativeTo: rect, of: anchor)
    }
    /// The click location for mouse-initiated actions; otherwise the selected row.
    private func popoverAnchor() -> (NSView, NSRect) {
        let anchor = timeline.view
        if let event = NSApp.currentEvent, event.window === anchor.window,
           [.leftMouseUp, .leftMouseDown, .rightMouseUp, .rightMouseDown].contains(event.type) {
            let point = anchor.convert(event.locationInWindow, from: nil)
            if anchor.bounds.contains(point) { return (anchor, NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)) }
        }
        let table = timeline.tableView
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if row >= 0 {
            let rect = anchor.convert(table.rect(ofRow: row), from: table)
            if anchor.bounds.intersects(rect) {
                let visible = rect.intersection(anchor.bounds)
                return (anchor, NSRect(x: visible.minX + 40, y: visible.midY, width: 1, height: 1))
            }
        }
        return (anchor, NSRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1))
    }
    private func confirm(_ title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: button)
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func run(_ operation: @escaping @MainActor (ServerSession) async throws -> Void) {
        guard commandTask == nil, !editingStateDiscarded, let model,
              !model.isDetached, !model.requiresAuthentication else { return }
        let generation = generation
        commandTask = Task { [weak self] in
            defer { self?.commandTask = nil }
            guard !Task.isCancelled, self?.generation == generation,
                  !model.isDetached, !model.requiresAuthentication else { return }
            do { try await operation(model.session) }
            catch {
                guard !Task.isCancelled, self?.generation == generation,
                      !model.isDetached, !model.requiresAuthentication else { return }
                model.inlineError = (error as? UserFacingError).map(UserFacingErrorText.describe) ?? "The operation failed."
            }
        }
    }
}

/// The existing composer owns debounce, cancellation, keyboard handling and its
/// eight-row popup. This adapter only maps Core's scoped candidates.
private final class SessionCompletionProvider: ComposerCompletionProvider {
    weak var model: SessionViewModel?
    let channel: ChannelID
    let rootID: PostID?

    init(model: SessionViewModel?, channel: ChannelID, rootID: PostID?) {
        self.model = model
        self.channel = channel
        self.rootID = rootID
    }

    func completions(for trigger: CompletionTrigger, query: String) async -> [CompletionItem] {
        guard let model, !model.isDetached else { return [] }
        let candidates = await model.session.completions(trigger: trigger.character, query: query, channel: channel, rootID: rootID)
        guard !Task.isCancelled, !model.isDetached else { return [] }
        return candidates.map {
            // Emoji candidates carry the glyph as subtitle; show it in the leading slot.
            trigger == .emoji
                ? CompletionItem(id: $0.id, title: $0.title, insertionText: $0.insertion, leadingText: $0.subtitle)
                : CompletionItem(id: $0.id, title: $0.title, subtitle: $0.subtitle, insertionText: $0.insertion)
        }
    }
}
