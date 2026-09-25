public import Foundation
public import MatterMacModels
public import MattermostAPI

extension ServerSession {
    public enum SendRejection: Error, Sendable, Hashable {
        case empty
        case tooLong(limitCharacters: Int)
        case tooManyAttachments(limit: Int)
        case attachmentTooLarge(limitBytes: Int64)
        case channelArchived
        case sessionClosed
        case attachmentsDisabled
        case attachmentsUnavailable
        case channelUnavailable
        case budget(UnsentWorkLedger.Refusal)
    }


    /// Validates a send against server limits before the composer clears. Throws
    /// without side effects; the text stays in the composer.
    public func validateSend(text: String, channel: ChannelID, attachments: [UploadSource]) throws(SendRejection) {
        guard isActiveSessionAlive else { throw .sessionClosed }
        guard directory.memberships[channel] != nil else { throw .channelUnavailable }
        if !attachments.isEmpty {
            guard let enabled = capabilities.fileAttachmentsEnabled else { throw .attachmentsUnavailable }
            guard enabled else { throw .attachmentsDisabled }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { throw .empty }
        // The server counts runes (Unicode scalars); default maximum 16,383.
        let limit = capabilities.maximumPostCharacters ?? 16_383
        if text.unicodeScalars.count > limit { throw .tooLong(limitCharacters: limit) }
        if attachments.count > deps.budget.attachmentsPerPost { throw .tooManyAttachments(limit: deps.budget.attachmentsPerPost) }
        if let maxFile = capabilities.maximumFileSize, let big = attachments.first(where: { $0.expectedSize > maxFile }) {
            _ = big
            throw .attachmentTooLarge(limitBytes: maxFile)
        }
        if directory.channels[channel]?.isArchived == true { throw .channelArchived }
    }

    /// Enqueues a logical send. The caller has already moved the draft's bytes into
    /// `reservation` (so the composer may clear); from here the text lives in the
    /// pending queue until confirmed or explicitly discarded.
    @discardableResult
    public func enqueueSend(text: String, channel: ChannelID, rootID: PostID?, attachments: [UploadSource],
                            reservation: UnsentWorkLedger.Reservation) throws(SendRejection) -> PendingPostID {
        guard isActiveSessionAlive else { throw .sessionClosed }
        try validateSend(text: text, channel: channel, attachments: attachments)
        let pendingID = pending.makePendingID(user: me.id, now: now())
        let send = PendingSend(
            pendingID: pendingID, channelID: channel, rootID: rootID, message: text,
            attachments: attachments.enumerated().map { index, source in
                PendingSend.Attachment(clientID: "\(pendingID.rawValue)-\(index)", source: source)
            },
            createdAt: now(), reservation: reservation)
        pending.append(send)
        deps.diagnostics.record(.send, .info, "send queued")
        markDirty(rootID == nil ? .timeline : [.thread, .timeline])
        processSendQueue()
        return pendingID
    }

    /// Starts the sender if idle. Sends are processed one at a time, FIFO, so posts
    /// arrive in the order the user sent them; failed items are parked, not blocking.
    func processSendQueue() {
        guard isActiveSessionAlive, !isRunning(.sender), pending.nextQueued != nil else { return }
        run(.sender) { session in
            while let next = session.pending.nextQueued, !Task.isCancelled {
                await session.attempt(next.pendingID)
            }
        }
    }

    func attempt(_ id: PendingPostID) async {
        guard var send = pending.item(id) else { return }
        activeSendID = id
        defer { if activeSendID == id { activeSendID = nil } }
        let epoch = epoch
        // 1. Uploads (files attach only once the post is created).
        let needsUpload = send.attachments.filter { $0.uploadedFileID == nil }
        if !needsUpload.isEmpty {
            let total = send.attachments.count
            for attachment in needsUpload {
                let done = pending.item(id)?.attachments.filter { $0.uploadedFileID != nil }.count ?? 0
                pending.update(id) { $0.state = .uploading(completed: done, total: total) }
                markDirty(targetFlags(send))
                do {
                    let info = try await service.upload(attachment.source, channel: send.channelID,
                                                        clientID: attachment.clientID, progress: { _ in })
                    guard self.epoch == epoch, !Task.isCancelled, directory.memberships[send.channelID] != nil, pending.item(id) != nil else { return }
                    pending.update(id) { item in
                        if let index = item.attachments.firstIndex(where: { $0.clientID == attachment.clientID }) {
                            item.attachments[index].uploadedFileID = info.id
                        }
                    }
                } catch {
                    guard self.epoch == epoch, !Task.isCancelled else { return }
                    let failure = error
                    let userError: UserFacingError = switch failure {
                    case .payloadTooLarge: .payloadTooLarge(limitBytes: Int(capabilities.maximumFileSize ?? 0))
                    case .localFileUnavailable: .fileUnavailable
                    default: Self.userFacing(failure)
                    }
                    // Uploaded-but-unposted files remain orphaned on the server until its
                    // own cleanup; MatterMac does not invent a cleanup endpoint.
                    pending.update(id) {
                        switch failure {
                        case .outcomeUnknown, .malformedResponse, .responseTooLarge, .server: $0.state = .outcomeUnknown
                        default: $0.state = .failed(userError)
                        }
                    }
                    handleAuthenticationFailureIfNeeded(failure)
                    markDirty(targetFlags(send))
                    return
                }
            }
            guard let refreshed = pending.item(id) else { return }
            send = refreshed
        }
        guard isActiveSessionAlive, !Task.isCancelled, directory.memberships[send.channelID] != nil else { return }
        // 2. POST with the stable pending id.
        pending.update(id) { item in
            item.state = .sending
            if item.firstPostAttemptAt == nil { item.firstPostAttemptAt = self.now() }
            item.postAttempts += 1
        }
        markDirty(targetFlags(send))
        let outgoing = OutgoingPost(channelID: send.channelID, rootID: send.rootID, message: send.message,
                                    fileIDs: send.attachments.compactMap(\.uploadedFileID), pendingPostID: send.pendingID)
        do {
            let post = try await service.createPost(outgoing)
            guard self.epoch == epoch, !Task.isCancelled else { return }
            // The echo may already have confirmed it; confirmSend is idempotent.
            confirmSend(id, with: post)
        } catch {
            guard self.epoch == epoch, !Task.isCancelled, directory.memberships[send.channelID] != nil, let current = pending.item(id) else { return }
            let failure = error
            let decision = SendFailurePolicy.decide(
                error: failure, firstAttemptAt: current.firstPostAttemptAt ?? now(), now: now(),
                automaticRetriesUsed: current.automaticRetriesUsed,
                serverDeduplicationTrusted: serverDeduplicationTrusted)
            switch decision {
            case .retry(let delay):
                pending.update(id) { item in
                    item.automaticRetriesUsed += 1
                    item.state = failure.isOutcomeUnknown ? .outcomeUnknown : .sending
                }
                markDirty(targetFlags(current))
                scheduleAutomaticRetry(id, afterMilliseconds: delay)
            case .fail(var userError):
                if case .messageTooLong = userError { userError = .messageTooLong(limitCharacters: capabilities.maximumPostCharacters ?? 16_383) }
                pending.update(id) { $0.state = .failed(userError) }
                if userError == .authenticationRequired { handleAuthenticationFailureIfNeeded(failure) }
                markDirty(targetFlags(current))
            case .unknown:
                pending.update(id) { $0.state = .outcomeUnknown }
                deps.diagnostics.record(.send, .warning, "send outcome unknown")
                markDirty(targetFlags(current))
            }
        }
    }

    func scheduleAutomaticRetry(_ id: PendingPostID, afterMilliseconds delay: Int64) {
        run(.sendRetry(id)) { session in
            try? await session.deps.clock.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let item = session.pending.item(id) else { return }
            switch item.state {
            case .outcomeUnknown, .sending:
                session.pending.update(id) { $0.state = .queued }
                session.processSendQueue()
            default:
                return
            }
        }
    }

    /// Canonical confirmation from the REST response or the WebSocket echo. Removes
    /// the pending item, releases its reservation, and inserts the server post.
    func confirmSend(_ id: PendingPostID, with post: Post) {
        guard isActiveSessionAlive, directory.memberships[post.channelID] != nil else { return }
        guard let send = pending.remove(id) else {
            // Already confirmed by the other path: merge any newer data.
            store.upsert(post, insertIfMissing: false)
            return
        }
        deps.unsent.release(send.reservation)
        tasks[.sendRetry(id)]?.cancel()
        var canonical = post
        canonical.pendingPostID = id
        // Sending in a channel marked unread is the user acting there again.
        if manualUnreadHold == post.channelID { manualUnreadHold = nil }
        insertLive(canonical)
        deps.diagnostics.record(.send, .info, "send confirmed")
        markDirty([.timeline, .thread, .sidebar])
        evaluateReadState()
    }

    /// User-initiated retry of a failed or outcome-unknown send. For an unknown
    /// outcome this may create a duplicate; the UI explains that before calling.
    public func retrySend(_ id: PendingPostID) {
        guard let item = pending.item(id), !item.isInFlight,
              (try? validateSend(text: item.message, channel: item.channelID, attachments: item.attachments.map(\.source))) != nil else { return }
        // A previous automatic retry must not requeue this item while the explicit
        // retry's POST is in flight (which would also make discard look safe).
        tasks[.sendRetry(id)]?.cancel()
        // firstPostAttemptAt is kept: if the dedup window still applies, the retry
        // cannot duplicate; otherwise the UI has warned the user that it might.
        pending.update(id) { item in
            item.state = .queued
            item.automaticRetriesUsed = 0
        }
        markDirty(targetFlags(item))
        processSendQueue()
    }

    /// Discards an unsent item after explicit user confirmation. Returns its text so
    /// the UI can offer to copy it.
    @discardableResult
    public func discardSend(_ id: PendingPostID) -> String? {
        guard let item = pending.item(id) else { return nil }
        if case .sending = item.state { return nil } // A POST in flight may already have created a message.
        if case .uploading = item.state, activeSendID == id { tasks[.sender]?.cancel() }
        pending.remove(id)
        tasks[.sendRetry(id)]?.cancel()
        deps.unsent.release(item.reservation)
        markDirty(targetFlags(item))
        return item.message
    }

    public func timelineImage(_ resource: ImageResource, channel: ChannelID, maxPixelSize: Int,
                              pipeline: ImagePipeline) async -> ImagePipeline.Decoded? {
        guard isActiveSessionAlive, directory.memberships[channel] != nil else { return nil }
        let epoch = epoch
        let image = await pipeline.image(for: ImagePipeline.Key(scope: scope, resource: resource, maxPixelSize: maxPixelSize),
                                         using: service)
        guard isActiveSessionAlive, self.epoch == epoch, directory.memberships[channel] != nil, !Task.isCancelled else { return nil }
        return image
    }

    public func downloadAttachment(_ file: FileID, channel: ChannelID, to destination: URL) async throws(UserFacingError) {
        guard isActiveSessionAlive, directory.memberships[channel] != nil else { throw .permissionDenied }
        guard downloads.count < deps.budget.attachmentTransfersGlobal else { throw .budgetExceeded(.attachmentCount) }
        let id = UUID(), service = service
        let task = Task { try await service.download(file, to: destination, progress: { _ in }) }
        downloads[id] = (channel, task)
        defer { downloads[id] = nil }
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { handleAuthenticationFailureIfNeeded(error); throw Self.userFacing(error) }
    }

    public func pendingText(_ id: PendingPostID) -> String? { pending.item(id)?.message }

    /// When the socket reconnects, retry items that failed only because the network
    /// was unavailable (once), never items with an unknown outcome.
    func resumeQueuedSends() {
        var resumed = false
        for item in pending.items {
            if case .failed(let error) = item.state, error == .offline || error == .serverUnreachable || error == .timedOut,
               item.automaticRetriesUsed < SendFailurePolicy.maximumAutomaticRetries {
                pending.update(item.pendingID) { $0.state = .queued; $0.automaticRetriesUsed += 1 }
                resumed = true
            }
        }
        if resumed {
            markDirty([.timeline, .thread])
            processSendQueue()
        }
    }

    func targetFlags(_ send: PendingSend) -> DirtyFlags {
        send.rootID == nil ? .timeline : [.thread, .timeline]
    }

    // MARK: - Edit, delete, reactions

    /// Edits a post. On failure the attempted text is returned inside the error so the
    /// UI can keep it (SPEC §11: preserve a failed edit in session memory).
    public func edit(_ id: PostID, text: String) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let limit = capabilities.maximumPostCharacters ?? 16_383
        guard text.unicodeScalars.count <= limit else { throw .messageTooLong(limitCharacters: limit) }
        let epoch = epoch
        do throws(APIError) {
            let post = try await service.editPost(id, message: text)
            guard self.epoch == epoch, !Task.isCancelled else { throw APIError.cancelled }
            journal.append(.upsert(post))
            store.upsert(post, insertIfMissing: false)
            markDirty([.timeline, .thread, .search])
        } catch {
            if case .badRequest(let info) = error, info.id == ServerErrorID.editTimeLimit {
                throw .permissionDenied
            }
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    public func delete(_ id: PostID) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let epoch = epoch
        do {
            try await service.deletePost(id)
            guard self.epoch == epoch, !Task.isCancelled else { return }
            if let post = store.post(id) { handleDeleted(post) }
        } catch {
            if case .notFound = error {
                // Already deleted elsewhere.
                if let post = store.post(id) { handleDeleted(post) }
                return
            }
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    public func toggleReaction(_ post: PostID, emojiName: String) async throws(UserFacingError) {
        guard isActiveSessionAlive else { throw .authenticationRequired }
        let name = emojiName.lowercased()
        guard Reaction.isValidEmojiName(name), let stored = store.post(post) else { throw .unknown }
        let mine = stored.reactions.contains { $0.userID == me.id && $0.emojiName == name }
        let epoch = epoch
        do {
            if mine {
                try await service.removeReaction(post: post, emojiName: name, me: me.id)
                guard self.epoch == epoch, !Task.isCancelled else { return }
                let reaction = Reaction(userID: me.id, postID: post, emojiName: name)
                journal.append(.reaction(reaction, added: false))
                store.applyReaction(reaction, added: false)
            } else {
                let reaction = try await service.addReaction(post: post, emojiName: name, me: me.id)
                guard self.epoch == epoch, !Task.isCancelled else { return }
                journal.append(.reaction(reaction, added: true))
                store.applyReaction(reaction, added: true)
                directory.noteReaction(name)
                scheduleCacheWrite(directory: true)
            }
            markDirty([.timeline, .thread])
        } catch {
            if case .badRequest(let info) = error, info.id == ServerErrorID.tooManyReactions {
                throw .budgetExceeded(.attachmentCount)
            }
            handleAuthenticationFailureIfNeeded(error)
            throw Self.userFacing(error)
        }
    }

    /// The user's most recent own, editable root post in a target (Up-arrow editing).
    public func lastOwnPost(in target: TimelineTarget) -> Post? {
        guard let window = windows[target] else { return nil }
        for entry in window.entries.reversed() {
            if let post = store.post(entry.id), post.userID == me.id, !post.isDeleted, !post.type.isSystem {
                return post
            }
        }
        return nil
    }

    public func post(_ id: PostID) -> Post? { store.post(id) }

    // MARK: - Typing & activity

    public func userIsTyping(channel: ChannelID, root: PostID?) async {
        guard typingEnabled, isActiveSessionAlive else { return }
        await realtime.sendTyping(channel: channel, parent: root)
    }

    public func reportUserActivity(isActive: Bool) async {
        guard isActiveSessionAlive else { return }
        await realtime.reportUserActivity(isActive: isActive)
    }
}

extension APIError {
    var isOutcomeUnknown: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }
}
