import SwiftUI
import MatterMacModels
import MatterMacCore

struct MainWindowView: View {
    let app: AppModel
    @Bindable var session: SessionViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app, session: session)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let notice = session.noticeText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(notice).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if session.requiresAuthentication || session.pendingNotice?.preservesUnsentWork == true {
                                Button("Review Unsent Work…") { session.isUnsentRecoveryVisible = true }
                                Button("Copy Unsent Text") { session.copyUnsentText() }
                                    .disabled(session.isCopyingUnsentText)
                            }
                            if session.requiresAuthentication {
                                Button("Sign In Again…") { Task { await app.reauthenticate(session.slot.id) } }
                                    .disabled(app.isReauthenticating)
                            } else {
                                Button("Dismiss") { session.dismissNotice() }
                            }
                        }
                        if session.pendingNotice?.preservesUnsentWork == true {
                            Text("Interrupted sends may already have reached the server. Check before resending copied text.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Review unsent work to copy individual messages or export pasted images before signing out or quitting.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.1))
                    .accessibilityIdentifier("sessionNotice")
                }
                if let header = session.header {
                    if header.canPost == false {
                        Text("This channel is read-only. Your draft is kept in this session.").font(.callout).padding(8)
                    } else if header.fileAttachmentsEnabled != true {
                        Text(header.fileAttachmentsEnabled == false
                             ? "File attachments are disabled on this server."
                             : "File attachment availability has not been confirmed by the server.")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
                if let feedback = session.commandFeedback {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(verbatim: feedback)
                            .font(.callout)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { session.commandFeedback = nil }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Command reply: \(feedback)")
                }
                if let error = session.inlineError {
                    HStack {
                        Text(error).font(.callout).foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") { session.inlineError = nil }
                    }.padding(8)
                }
                Divider()
                if let channel = session.selectedChannel {
                    HSplitView {
                        ConversationView(session: session, target: .channel(channel), snapshot: session.timeline)
                            .frame(minWidth: 300)
                        if let thread = session.thread {
                            VStack(spacing: 0) {
                                HStack {
                                    Text("Thread").font(.headline)
                                    Spacer()
                                    Button("Close") { session.closeThread() }
                                }.padding(12)
                                ConversationView(session: session, target: thread.target, snapshot: thread)
                            }.frame(minWidth: 240, idealWidth: 360)
                        } else if session.isChannelInfoVisible {
                            // The single optional trailing panel (SPEC §4): details or thread.
                            VStack(spacing: 0) {
                                HStack {
                                    Text("Channel Info").font(.headline)
                                    Spacer()
                                    Button("Close") { session.isChannelInfoVisible = false }
                                }.padding(12)
                                ChannelInfoView(session: session, channel: channel).id(channel)
                            }.frame(minWidth: 240, idealWidth: 320)
                        }
                    }
                } else {
                    Text("Select a channel").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(ChannelHeaderText.title(session.header))
        .navigationSubtitle(ChannelHeaderText.subtitle(session.header))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ChannelHeaderAccessories(header: session.header, session: session)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { session.isQuickSwitcherVisible = true } label: {
                    Label("Quick Switcher", systemImage: "arrow.left.arrow.right.square")
                }
                .help("Switch to a channel or person (⌘K)")
                Button { session.isSearchVisible = true } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search messages on the server (⌘F)")
                Toggle(isOn: $session.isChannelInfoVisible) {
                    Label("Channel Info", systemImage: "info.circle")
                }
                .help("Show channel details and members (⇧⌘I)")
                .disabled(session.selectedChannel == nil)
            }
        }
        .focusedSceneValue(\.matterMacSession, session)
        .sheet(isPresented: $session.isQuickSwitcherVisible) { QuickSwitcherView(session: session) }
        .sheet(isPresented: $session.isSearchVisible) { SearchPanel(session: session) }
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
