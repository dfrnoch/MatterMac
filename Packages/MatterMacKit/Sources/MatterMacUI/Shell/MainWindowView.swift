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

    @ViewBuilder private var conversationArea: some View {
        if session.isThreadsViewVisible {
            HSplitView {
                ThreadsListView(session: session)
                    .frame(minWidth: 300, idealWidth: 420, maxHeight: .infinity)
                if let thread = session.thread {
                    TrailingPane(title: "Thread", systemImage: "bubble.left.and.text.bubble.right",
                                 close: { session.closeThread() }) {
                        ConversationView(session: session, target: thread.target, snapshot: thread)
                    }
                    .frame(minWidth: 300, idealWidth: 480)
                } else {
                    ContentUnavailableView("Select a Thread", systemImage: "text.bubble",
                                           description: Text("Choose a thread to read and reply."))
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if let channel = session.selectedChannel {
            HSplitView {
                ConversationView(session: session, target: .channel(channel), snapshot: session.timeline)
                    .frame(minWidth: 300)
                // The single optional trailing panel (SPEC §4): thread or details.
                if let thread = session.thread {
                    TrailingPane(title: "Thread", systemImage: "bubble.left.and.text.bubble.right",
                                 close: { session.closeThread() }) {
                        ConversationView(session: session, target: thread.target, snapshot: thread)
                    }
                    .frame(minWidth: 240, idealWidth: 360)
                } else if session.isSearchVisible {
                    SearchPane(session: session)
                        .frame(minWidth: 280, idealWidth: 380)
                } else if session.isChannelInfoVisible {
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
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            ZStack(alignment: .top) {
                conversationArea
                banners
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: bannerIdentity)
        }
        .navigationTitle(session.isThreadsViewVisible ? String(localized: "Threads") : ChannelHeaderText.title(session.header))
        .navigationSubtitle(session.isThreadsViewVisible ? "" : ChannelHeaderText.subtitle(session.header))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ChannelHeaderAccessories(header: session.header, session: session)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $session.isThreadsViewVisible) {
                    Label("Threads", systemImage: "bubble.left.and.text.bubble.right")
                }
                .overlay(alignment: .topTrailing) { threadsBadge }
                .help("Followed threads (⇧⌘T)")
                .accessibilityValue(threadsAccessibilityValue)
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
                Toggle(isOn: $session.isChannelInfoVisible) {
                    Label("Channel Info", systemImage: "info.circle")
                }
                .help("Show channel details and members (⇧⌘I)")
                .disabled(session.selectedChannel == nil)
            }
        }
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
private struct TrailingPane<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                Spacer()
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
