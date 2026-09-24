public import MatterMacModels
import MattermostAPI

extension ServerSession {
    /// Visibility policy (SPEC §12): a channel is marked viewed only when the app is
    /// active, its window is visible, the channel is the visible conversation, and the
    /// timeline shows the live edge (so the newest content is exposed). Receiving an
    /// event or fetching data never marks anything read.
    ///
    /// After "Mark as Unread" (`manualUnreadHold`) the channel is not marked viewed
    /// again until the user acts: scrolls its timeline (`userScrolled`), sends a message
    /// in it, or opens another channel. Snapshot updates, new posts, app activation and
    /// window changes do not end the hold (decision 0022).
    public func updateVisibility(target: TimelineTarget, first: PostID?, last: PostID?, atLiveEdge: Bool,
                                 userScrolled: Bool = false) {
        if userScrolled, case .channel(let channel) = target, manualUnreadHold == channel {
            manualUnreadHold = nil
            markDirty(.sidebar)
        }
        let range = VisibleRange(first: first, last: last, atLiveEdge: atLiveEdge)
        guard visibility[target] != range || userScrolled else { return }
        visibility[target] = range
        evaluateReadState()
    }

    public func updateAppState(isActive: Bool, isWindowVisible: Bool) {
        let wasForeground = appIsActive && windowIsVisible
        let isForeground = isActive && isWindowVisible
        appIsActive = isActive
        windowIsVisible = isWindowVisible
        if !wasForeground && isForeground { refreshPresenceSoon() }
        if !isWindowVisible { tasks[.presence]?.cancel(); tasks[.presence] = nil }
        if wasForeground && !isForeground { clearServerActiveChannel() }
        evaluateReadState()
    }

    /// `view` also records the server-side *active channel*, which suppresses push
    /// notifications for it and refreshes activity. When MatterMac leaves the
    /// foreground it clears that (channel_id "", prev_channel_id current), matching the
    /// official client, so the user is not kept "active" in a channel they can't see.
    func clearServerActiveChannel() {
        guard let previous = lastViewedChannel ?? activeChannel else { return }
        run(.readMark) { session in
            _ = try? await session.service.viewChannel(nil, previous: previous, collapsedThreadsSupported: true)
        }
    }

    func readConditionsHold(for channel: ChannelID) -> Bool {
        guard appIsActive, windowIsVisible, activeChannel == channel, isActiveSessionAlive, manualUnreadHold != channel,
              let window = windows[.channel(channel)], window.isLoaded, !window.hasNewer,
              visibility[.channel(channel)]?.atLiveEdge == true
        else { return false }
        return directory.unread(for: channel, collapsedThreads: collapsedThreadsActive).isUnread
            || (directory.memberships[channel]?.mentionCount ?? 0) > 0
    }

    func evaluateReadState() {
        guard let channel = activeChannel, readConditionsHold(for: channel) else { return }
        guard !isRunning(.readMark) else { return }
        run(.readMark) { session in
            // Short dwell so a channel flicked past is not marked read.
            try? await session.deps.clock.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, session.readConditionsHold(for: channel) else { return }
            let epoch = session.epoch
            let previous = session.lastViewedChannel == channel ? nil : session.lastViewedChannel
            do {
                // collapsed_threads_supported = true: MatterMac has a thread view, so the
                // server must not mark every thread read as a side effect.
                let times = try await session.service.viewChannel(channel, previous: previous,
                                                                  collapsedThreadsSupported: true)
                guard session.epoch == epoch else { return }
                session.lastViewedChannel = channel
                session.markViewedLocally(channel, at: times[channel] ?? session.now())
                session.markDirty(.sidebar)
            } catch {
                guard session.epoch == epoch else { return }
                // Not retried with the old context: the next visibility change re-evaluates.
                session.deps.diagnostics.record(.sync, .warning, "view channel failed")
                session.handleAuthenticationFailureIfNeeded(error)
            }
        }
    }
}
