import SwiftUI
import MatterMacModels
import MatterMacCore

struct MainWindowView: View {
    let app: AppModel
    @Bindable var session: SessionViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bannerIdentity: [String] {
        [session.noticeText ?? "", session.commandFeedback ?? "", session.inlineError ?? ""]
    }

    @ViewBuilder private func conversationArea(width: CGFloat) -> some View {
        // Keep both panes readable; at narrow widths the selected trailing pane
        // replaces the conversation until its existing Close action is used.
        // A nested native HSplitView adds the sidebar safe-area inset to its
        // minimum widths (1100pt window + 276pt sidebar overflowed by 16.5pt).
        // HStack keeps responsive panes inside the proposal; only the outer
        // sidebar divider is draggable.
        let showsBothPanes = width >= 800
        if session.isThreadsViewVisible {
            HStack(spacing: 0) {
                if showsBothPanes || session.thread == nil {
                    ThreadsListView(session: session)
                        .frame(minWidth: 300, idealWidth: 420, maxHeight: .infinity)
                }
                if let thread = session.thread {
                    if showsBothPanes { Divider() }
                    TrailingPane(title: "Thread", systemImage: "bubble.left.and.text.bubble.right",
                                 close: { session.closeThread() },
                                 accessory: { ThreadFollowButton(session: session, target: thread.target) }) {
                        ConversationView(session: session, target: thread.target, snapshot: thread)
                    }
                    .frame(minWidth: 300, idealWidth: 480)
                } else if showsBothPanes {
                    Divider()
                    ContentUnavailableView("Select a Thread", systemImage: "text.bubble",
                                           description: Text("Choose a thread to read and reply."))
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if let channel = session.selectedChannel {
            HStack(spacing: 0) {
                if showsBothPanes || (session.thread == nil && !session.isSearchVisible && !session.isChannelInfoVisible) {
                    ConversationView(session: session, target: .channel(channel), snapshot: session.timeline)
                        .ignoresSafeArea(.container, edges: .top)
                        .frame(minWidth: 300)
                }
                // The single optional trailing panel (SPEC §4): thread or details.
                if let thread = session.thread {
                    if showsBothPanes { Divider() }
                    TrailingPane(title: "Thread", systemImage: "bubble.left.and.text.bubble.right",
                                 close: { session.closeThread() },
                                 accessory: { ThreadFollowButton(session: session, target: thread.target) }) {
                        ConversationView(session: session, target: thread.target, snapshot: thread)
                    }
                    .frame(minWidth: 240, idealWidth: 360)
                } else if session.isSearchVisible {
                    if showsBothPanes { Divider() }
                    GeometryReader { geometry in
                        SearchPane(session: session) {
                            if !showsBothPanes { session.isSearchVisible = false }
                        }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(minWidth: 280, idealWidth: 380)
                } else if session.isChannelInfoVisible {
                    if showsBothPanes { Divider() }
                    TrailingPane(title: "Channel Info", systemImage: "info.circle",
                                 close: { session.isChannelInfoVisible = false }) {
                        ChannelInfoView(session: session, channel: channel).id(channel)
                    }
                    .frame(minWidth: 240, idealWidth: 320)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Choose a channel or direct message in the sidebar, or press ⌘K to switch.")
            } actions: {
                Button("Quick Switcher…") { session.isQuickSwitcherVisible = true }
                    .glassButtonStyle()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var threadsBadge: some View {
        if let activity = session.threadActivity, activity.isAvailable, activity.unreadThreads > 0 {
            if activity.unreadMentions > 0 {
                Text(activity.unreadMentions > 99 ? "99+" : "\(activity.unreadMentions)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 4, y: -2)
                    .allowsHitTesting(false)
            } else {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .offset(x: 2, y: 0)
                    .allowsHitTesting(false)
            }
        }
    }

    private var threadsAccessibilityValue: String {
        guard let activity = session.threadActivity, activity.unreadThreads > 0 else { return "" }
        return String(localized: "\(activity.unreadThreads) unread threads, \(activity.unreadMentions) mentions")
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 8) {
            if let updater = app.environment.updater {
                UpdateBanner(updater: updater)
            }
            if let notice = session.noticeText {
                VStack(alignment: .leading, spacing: 8) {
                    FloatingBanner(tone: session.requiresAuthentication ? .error : .warning,
                                   systemImage: session.requiresAuthentication ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle",
                                   message: notice) {
                        HStack {
                            if session.requiresAuthentication || session.pendingNotice?.preservesUnsentWork == true {
                                Button("Review Unsent Work…") { session.isUnsentRecoveryVisible = true }
                                Button("Copy Unsent Text") { session.copyUnsentText() }
                                    .disabled(session.isCopyingUnsentText)
                            }
                            if session.requiresAuthentication {
                                Button("Sign In Again…") { Task { await app.reauthenticate(session.slot.id) } }
                                    .disabled(app.isReauthenticating)
                                    .glassButtonStyle(prominent: true)
                            } else {
                                Button("Dismiss") { session.dismissNotice() }
                            }
                        }
                    }
                    if session.pendingNotice?.preservesUnsentWork == true {
                        Text("Interrupted sends may already have reached the server. Check before resending copied text. Review unsent work to copy individual messages or export pasted images before signing out or quitting.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    }
                }
                .accessibilityIdentifier("sessionNotice")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let feedback = session.commandFeedback {
                FloatingBanner(tone: .info, systemImage: "terminal", message: feedback) {
                    Button("Dismiss") { session.commandFeedback = nil }
                }
                .accessibilityLabel("Command reply: \(feedback)")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let error = session.inlineError {
                FloatingBanner(tone: .error, systemImage: "exclamationmark.octagon", message: error) {
                    Button("Dismiss") { session.inlineError = nil }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let header = session.header, header.canPost == false || header.fileAttachmentsEnabled == false {
                Label(header.canPost == false ? "This channel is read-only. Your draft is kept in this session."
                                              : "File attachments are disabled on this server.",
                      systemImage: header.canPost == false ? "lock" : "paperclip.badge.ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCapsule()
            }
        }
        .frame(maxWidth: 720)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app, session: session)
                .navigationSplitViewColumnWidth(
                    min: WorkspaceRail.isShown(app: app, sidebar: session.sidebar) ? 260 : 200,
                    ideal: 280, max: 340)
        } detail: {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    conversationArea(width: geometry.size.width)
                    banners
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: bannerIdentity)
            }
        }
        .modifier(ConversationTitleToolbar(
            title: session.isThreadsViewVisible ? String(localized: "Threads") : ChannelHeaderText.title(session.header),
            subtitle: session.isThreadsViewVisible ? "" : ChannelHeaderText.subtitle(session.header, parse: app.environment.markupParse),
            header: session.isThreadsViewVisible ? nil : session.header, session: session))
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .navigationTitle(session.isThreadsViewVisible ? String(localized: "Threads") : ChannelHeaderText.title(session.header))
        .navigationSubtitle(session.isThreadsViewVisible ? "" : ChannelHeaderText.subtitle(session.header, parse: app.environment.markupParse))
        .toolbar {
            // macOS 26 shows these beside the title (ConversationTitleToolbar), so the
            // trailing controls keep their place when switching conversations.
            if !ConversationTitleToolbar.showsAccessoriesInTitle, let header = session.header,
               header.memberCount != nil || header.isArchived || (header.type == .direct && header.partnerStatus != nil) {
                ToolbarItem(placement: .primaryAction) {
                    ChannelHeaderAccessories(header: header, session: session)
                }
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $session.isThreadsViewVisible) {
                    Label("Threads", systemImage: "bubble.left.and.text.bubble.right")
                }
                .overlay(alignment: .topTrailing) { threadsBadge }
                .help("Followed threads (⇧⌘T)")
                .accessibilityValue(threadsAccessibilityValue)
            }
            ToolbarItemGroup(placement: .automatic) {
                Button { session.isQuickSwitcherVisible = true } label: {
                    Label("Quick Switcher", systemImage: "arrow.left.arrow.right.square")
                }
                .help("Switch to a channel or person (⌘K)")
                Menu {
                    Button { session.showRecentMentions() } label: { Label("Recent Mentions", systemImage: "at") }
                    Button { session.showSavedPosts() } label: { Label("Saved Messages", systemImage: "bookmark") }
                    Button { session.showPinnedPosts() } label: { Label("Pinned Messages", systemImage: "pin") }
                        .disabled(session.selectedChannel == nil)
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                } primaryAction: {
                    session.isSearchVisible = true
                }
                .help("Search messages on the server (⌘F); hold for mentions, saved and pinned")
                .accessibilityLabel("Search")
                Toggle(isOn: $session.isChannelInfoVisible) {
                    Label("Channel Info", systemImage: "info.circle")
                }
                .help("Show channel details and members (⇧⌘I)")
                .disabled(session.selectedChannel == nil)
            }
        }
        // The window theme: a gradient behind both columns and the glass chrome (the
        // conversation panes draw no background of their own while it is active),
        // and its accent for badges and controls. Applies live from Settings.
        .themedBackground()
        .themeAccentTint()
        .environment(\.matterMacTheme, app.environment.settings.theme)
        .focusedSceneValue(\.matterMacSession, session)
        .sheet(isPresented: $session.isQuickSwitcherVisible) { QuickSwitcherView(session: session) }
        .sheet(isPresented: $session.isUnsentRecoveryVisible) { UnsentRecoveryView(session: session) }
    }
}

extension SessionNotice {
    var preservesUnsentWork: Bool {
        switch self {
        case .accessRevoked, .teamRemoved, .signedOutByServer, .identityChanged: true
        case .operationFailed: false
        }
    }
}

/// Header and content of the trailing thread/details pane.
private struct TrailingPane<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let close: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(title: LocalizedStringKey, systemImage: String, close: @escaping () -> Void,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.close = close
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Spacer()
                accessory()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel(Text("Close"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            content()
        }
    }
}

/// Follow / Following toggle for the open thread (collapsed reply threads only).
private struct ThreadFollowButton: View {
    let session: SessionViewModel
    let target: TimelineTarget
    @State private var following: Bool?

    private var root: PostID? {
        if case .thread(let root, _) = target { return root }
        return nil
    }

    var body: some View {
        Group {
            if let following, let root {
                Button(following ? "Following" : "Follow") {
                    session.setThreadFollowing(root, !following)
                    self.following = !following
                }
                .controlSize(.small)
                .glassButtonStyle(prominent: following)
                .help(following ? "Stop following this thread" : "Follow this thread to see replies in Threads")
            }
        }
        .task(id: root) {
            guard let root else { return }
            following = await session.isFollowingThread(root)
        }
    }
}

/// The conversation's name at the leading edge of its part of the toolbar (after the
/// sidebar toggle), with one secondary line: presence or member count, archived
/// state, then the channel header or who is typing. It replaces the centered title.
private struct ConversationTitleToolbar: ViewModifier {
    let title: String
    let subtitle: String
    let header: ChannelHeaderPresentation?
    let session: SessionViewModel

    static var showsAccessoriesInTitle: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        titleView
                    }
                    .sharedBackgroundVisibility(.hidden)
                    // An empty centre item: its flexible space keeps the conversation
                    // controls at the trailing edge.
                    ToolbarItem(placement: .principal) {
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        } else {
            content
        }
    }

    @ViewBuilder private var titleView: some View {
        if !title.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.headline)
                    .overlay(WindowTitleDragRegion())
                HStack(spacing: 6) {
                    if let header {
                        if header.type == .direct, let status = header.partnerStatus {
                            HStack(spacing: 4) { StatusDot(status: status); Text(status.label) }
                                .accessibilityElement(children: .combine)
                        }
                        if header.isArchived {
                            Label("Archived", systemImage: "archivebox").labelStyle(.titleAndIcon)
                        }
                        if let count = header.memberCount {
                            Button { session.isChannelInfoVisible = true } label: {
                                Label("\(count)", systemImage: "person.2").labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.plain)
                            .help("\(count) members — show channel details")
                            .accessibilityLabel("\(count) members, show channel details")
                        }
                    }
                    if !subtitle.isEmpty {
                        if header?.memberCount != nil || header?.partnerStatus != nil || header?.isArchived == true {
                            Text(verbatim: "·").accessibilityHidden(true)
                        }
                        Text(verbatim: subtitle)
                            .truncationMode(.tail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            // Narrow enough that the conversation controls fit beside it in small windows.
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversationWindowTitle")
            .transaction { $0.animation = nil }
        }
    }
}

private struct WindowTitleDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 1 { window?.performDrag(with: event) }
            else { super.mouseDown(with: event) }
        }
    }
}
