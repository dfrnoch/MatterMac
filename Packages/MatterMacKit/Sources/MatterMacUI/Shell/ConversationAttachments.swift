import AppKit
import MatterMacModels
import MatterMacCore
import MattermostAPI

extension ConversationController {
    func refreshAttachmentChips() {
        composer.attachments = selectedFiles.map {
            ComposerAttachment(id: $0.id, name: $0.fileName,
                               byteCount: $0.expectedSize, status: .waiting)
        }
    }

    func composerRequestsFileSelection() {
        guard composer.isAttachmentSelectionAllowed, filePanel == nil, let window = view.window else { return }
        let expectedKey = key
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Files upload when you send the message. Selected files stay in this session only."
        filePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            filePanel = nil
            guard response == .OK, key == expectedKey, model?.isDetached == false else { return }
            composerDidReceiveFiles(panel.urls)
        }
    }

    func composerDidReceiveFiles(_ urls: [URL]) {
        guard composer.isAttachmentSelectionAllowed, selectionTask == nil, let model, !model.isDetached else { return }
        let limit = environment.budget.attachmentsPerPost
        guard urls.count <= limit - selectedFiles.count else {
            model.inlineError = "A message can contain at most \(limit) attachments. Existing selections were kept."
            return
        }
        let expectedKey = key
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { selectionTask = nil; updateComposerAvailability() }
            do {
                let sources = try await UploadSource.selected(urls, budget: environment.budget)
                guard !Task.isCancelled, key == expectedKey, !model.isDetached else { return }
                let previous = selectedFiles
                var combined = previous
                for source in sources where !combined.contains(where: { $0.id == source.id }) { combined.append(source) }
                try await model.session.validateSend(text: composer.text, channel: expectedKey.channelID, attachments: combined)
                guard !Task.isCancelled, key == expectedKey, !model.isDetached, selectedFiles == previous else { return }
                var draft = composer.currentDraft()
                draft.attachments = combined
                try environment.drafts.save(draft, for: expectedKey)
                selectedFiles = combined
                refreshAttachmentChips()
            } catch {
                guard !Task.isCancelled, key == expectedKey, !model.isDetached else { return }
                model.inlineError = (error as? ServerSession.SendRejection).map(Self.sendRejectionText)
                    ?? "The files could not be attached or a draft count or memory limit was reached. Existing text and attachments were kept."
            }
        }
        updateComposerAvailability()
    }

    func composerDidPasteImage(data: Data, typeIdentifier: String) -> Bool {
        guard composer.isAttachmentSelectionAllowed, let model, !model.isDetached else { return false }
        guard selectedFiles.count < environment.budget.attachmentsPerPost else {
            model.inlineError = "The attachment count limit has been reached. Existing attachments were kept."
            return false
        }
        do {
            let source = try environment.unsentLedger.pastedImage(data, typeIdentifier: typeIdentifier)
            var draft = composer.currentDraft()
            draft.attachments = selectedFiles + [source]
            // No suspension or second paste can occur before global admission.
            try environment.drafts.save(draft, for: key)
            selectedFiles = draft.attachments
            refreshAttachmentChips()
            return true
        } catch {
            model.inlineError = "The image format, draft count, or shared memory limit prevented this paste. Existing text and attachments were kept."
            return false
        }
    }

    func composerDidRemoveAttachment(id: String) {
        guard !environment.drafts.isSubmitting(key), model?.isDetached == false else { return }
        selectedFiles.removeAll { $0.id == id }
        refreshAttachmentChips()
        saveDraft()
    }

    func cancelFileWork() {
        // A save sheet may be attached to the image viewer: dismiss it before closing it.
        filePanel?.cancel(nil)
        filePanel = nil
        clearImages()
        selectionTask?.cancel()
        downloadTask?.cancel()
    }

    /// `presentingWindow` hosts the save sheet (e.g. the image viewer); defaults to the pane's window.
    func saveAttachment(_ file: FileInfo, in presentingWindow: NSWindow? = nil) {
        guard downloadTask == nil, filePanel == nil, let window = presentingWindow ?? view.window,
              let model, !model.isDetached else { return }
        let expectedKey = key
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.safeDownloadName(file.name)
        panel.prompt = "Save Attachment"
        panel.message = "This explicitly saves a file outside MatterMac’s session memory. Cancelling removes partial output and keeps any existing file."
        filePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            filePanel = nil
            guard response == .OK, let destination = panel.url, key == expectedKey, !model.isDetached else { return }
            downloadTask = Task { [weak self] in
                await self?.performDownload(file.id, to: destination, model: model, expectedKey: expectedKey)
            }
            downloadBar.isHidden = false
        }
    }

    private func performDownload(_ file: FileID, to destination: URL, model: SessionViewModel, expectedKey: DraftKey) async {
        defer { downloadTask = nil; downloadBar.isHidden = true }
        do { try await model.session.downloadAttachment(file, channel: expectedKey.channelID, to: destination) }
        catch {
            guard !Task.isCancelled, key == expectedKey, !model.isDetached else { return }
            model.inlineError = UserFacingErrorText.describe(error)
        }
    }

    @objc func cancelDownload(_ sender: Any?) { downloadTask?.cancel() }

    static func safeDownloadName(_ raw: String) -> String {
        let component = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let clean = String(String.UnicodeScalarView(component.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
        }).prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "attachment" : clean
    }

    static func sendRejectionText(_ error: ServerSession.SendRejection) -> String {
        switch error {
        case .empty: "Add text or an attachment before sending."
        case .tooLong(let limit): "The message exceeds the server’s \(limit)-character limit. Your draft was kept."
        case .tooManyAttachments(let limit): "A message can contain at most \(limit) attachments."
        case .attachmentTooLarge(let limit): "An attachment exceeds the server’s \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) file limit."
        case .channelUnavailable: "You no longer have access to this channel. Your draft was kept."
        case .attachmentsUnavailable: "The server has not confirmed that file attachments are available. Your draft was kept."
        case .attachmentsDisabled: "File attachments are disabled on this server."
        case .channelArchived: "This channel is archived. Your draft was kept."
        case .sessionClosed: "This session has ended."
        case .budget: "The limit for drafts or pending messages has been reached. Your draft was kept."
        }
    }
}
