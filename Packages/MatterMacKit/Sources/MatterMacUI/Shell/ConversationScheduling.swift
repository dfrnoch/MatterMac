import AppKit
import MatterMacModels
import MatterMacCore

/// Send Later for a conversation pane: the composer's time menu, the custom-time
/// picker, and the bar above the composer listing this conversation's scheduled
/// messages (reschedule, move back into the composer, delete).
extension ConversationController {
    func updateScheduled(_ posts: [ScheduledPost], available: Bool) {
        composer.isSchedulingAllowed = available && editingPost == nil
        guard scheduled != posts else { return }
        scheduled = posts
        let count = posts.count
        scheduledBar.isHidden = count == 0
        let failed = posts.contains(where: \.hasFailed)
        let title = count == 1 ? String(localized: "1 scheduled message") : String(localized: "\(count) scheduled messages")
        scheduledBar.title = failed ? title + " · " + String(localized: "1 or more not sent") : title
        scheduledBar.contentTintColor = failed ? .systemOrange : .secondaryLabelColor
        scheduledBar.setAccessibilityLabel(scheduledBar.title)
        updateOverlayInset()
        view.needsLayout = true
    }

    func configureScheduledBar() {
        scheduledBar.isBordered = false
        scheduledBar.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        scheduledBar.imagePosition = .imageLeading
        scheduledBar.alignment = .left
        scheduledBar.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scheduledBar.target = self
        scheduledBar.action = #selector(showScheduledMenu(_:))
        scheduledBar.toolTip = String(localized: "Show scheduled messages")
        scheduledBar.isHidden = true
    }

    // MARK: Scheduling from the composer

    func composerRequestsScheduleMenu(from button: NSView) {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Send Later"), action: nil, keyEquivalent: "").isEnabled = false
        for option in SendLaterOptions.presets(now: Date()) {
            let date = option.date
            menu.addItem(MenuAction.item(option.title) { [weak self] in self?.scheduleDraft(at: date) })
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(String(localized: "Custom Time…")) { [weak self] in
            guard let self, let date = chooseTime(title: String(localized: "Send Later"),
                                                  initial: Date().addingTimeInterval(3_600)) else { return }
            scheduleDraft(at: date)
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Hands the composer text to the server to send at `date`. Like a send, the draft
    /// is pinned while the request runs and kept if the server refuses.
    func scheduleDraft(at date: Date) {
        guard sendTask == nil, selectionTask == nil, editingPost == nil, selectedFiles.isEmpty,
              !environment.drafts.isSubmitting(key), let model else { return }
        let text = composer.text
        let key = key, target = target, generation = generation, rootID = key.rootID ?? replyRoot
        if ServerSession.isSlashCommand(text) {
            model.inlineError = "Slash commands can’t be scheduled. Start the message with a space to schedule it as text."
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
                try await model.session.validateSend(text: text, channel: target.channelID, attachments: [])
                guard !Task.isCancelled, self.generation == generation, composer.text == text else { return }
                let reservation = try environment.drafts.takeForSending(key)
                updateComposerAvailability()
                defer {
                    refreshDraft(for: key)
                    model.refreshDraft(for: key)
                }
                do {
                    let post = try await model.session.scheduleMessage(text, channel: target.channelID, rootID: rootID,
                                                                       at: MattermostTimestamp(date: date))
                    environment.drafts.finishSending(key, reservation: reservation, accepted: true)
                    // The server holds the text now; nothing is pending locally.
                    environment.unsentLedger.release(reservation)
                    model.didSchedule(post)
                } catch {
                    environment.drafts.finishSending(key, reservation: reservation, accepted: false)
                    throw error
                }
            } catch {
                if !Task.isCancelled {
                    model.inlineError = (error as? ServerSession.SendRejection).map(Self.sendRejectionText)
                        ?? (error as? UserFacingError).map(UserFacingErrorText.describe)
                        ?? "The message could not be scheduled. Your text has been kept."
                }
            }
        }
        updateComposerAvailability()
    }

    // MARK: The scheduled list

    @objc func showScheduledMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for post in scheduled {
            let when = post.hasFailed ? String(localized: "Not sent")
                                      : SendLaterOptions.describe(post.scheduledAt.date)
            let item = NSMenuItem(title: when + " · " + Self.preview(post.message), action: nil, keyEquivalent: "")
            if post.hasFailed { item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) }
            let submenu = NSMenu()
            submenu.addItem(MenuAction.item(String(localized: "Reschedule…")) { [weak self] in
                guard let self, let date = chooseTime(title: String(localized: "Reschedule"),
                                                      initial: max(post.scheduledAt.date, Date().addingTimeInterval(3_600)))
                else { return }
                model?.reschedule(post, to: date)
            })
            let edit = MenuAction.item(String(localized: "Edit in Composer")) { [weak self] in self?.editScheduled(post) }
            edit.isEnabled = composer.text.isEmpty && editingPost == nil && selectedFiles.isEmpty && post.fileIDs.isEmpty
            submenu.addItem(edit)
            submenu.addItem(.separator())
            submenu.addItem(MenuAction.item(String(localized: "Delete")) { [weak self] in
                guard let self, confirmDelete() else { return }
                model?.deleteScheduled(post)
            })
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// Moves a scheduled message back into an empty composer and cancels the schedule.
    private func editScheduled(_ post: ScheduledPost) {
        guard composer.text.isEmpty, editingPost == nil, root == post.rootID || root == nil else { return }
        if root == nil { replyRoot = post.rootID }
        composer.load(draft: Draft(text: post.message))
        if let replyRoot { composer.mode = .reply(authorName: timeline.threadRootAuthorName(replyRoot) ?? String(localized: "a thread")) }
        saveDraft()
        composer.focus()
        model?.deleteScheduled(post)
    }

    private func confirmDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete this scheduled message?")
        alert.informativeText = String(localized: "It will not be sent.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Delete"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// A date-and-time picker in a sheetless alert; at least two minutes from now.
    private func chooseTime(title: String, initial: Date) -> Date? {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate = Date().addingTimeInterval(120)
        picker.dateValue = max(initial, picker.minDate ?? initial)
        picker.sizeToFit()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: "The server sends the message at this time, even if MatterMac is closed.")
        alert.accessoryView = picker
        alert.addButton(withTitle: String(localized: "Schedule"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return picker.dateValue
    }

    static func preview(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}

/// Menu items that run a closure. The item's `target` is weak, so the action object
/// is kept alive as its `representedObject`.
final class MenuAction: NSObject {
    private let handler: () -> Void

    private init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc private func run() { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}
