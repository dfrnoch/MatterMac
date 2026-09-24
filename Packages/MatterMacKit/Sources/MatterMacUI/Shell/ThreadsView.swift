import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

/// Followed threads (collapsed reply threads), newest reply first. Pages are fetched
/// on demand and dropped when the view closes; at most `maximumThreads` rows.
struct ThreadsListView: View {
    let session: SessionViewModel
    @State private var threads: [ThreadSummary] = []
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var error: UserFacingError?
    @State private var unreadOnly = false

    static let maximumThreads = 250

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: TaskKey(unreadOnly: unreadOnly, revision: session.threadActivity?.revision ?? 0)) { await reload() }
        // No channel pane is visible here, so this view reports window visibility.
        .onAppear { session.updateAppState(isActive: NSApp.isActive, isWindowVisible: true) }
    }

    private struct TaskKey: Hashable {
        let unreadOnly: Bool
        let revision: UInt64
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Threads", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
            Spacer()
            Picker("Show", selection: $unreadOnly) {
                Text("Followed").tag(false)
                Text("Unread").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            Button {
                session.markThreadRead(nil)
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            .labelStyle(.iconOnly)
            .help("Mark all followed threads as read")
            .disabled((session.threadActivity?.unreadThreads ?? 0) == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if session.threadActivity?.isAvailable == false {
            ContentUnavailableView("Threads Are Off", systemImage: "bubble.left.and.text.bubble.right",
                                   description: Text("Collapsed reply threads are turned off on this server or in your display settings, so replies appear in channels."))
        } else if let error, threads.isEmpty {
            ContentUnavailableView {
                Label("Threads Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(UserFacingErrorText.describe(error))
            } actions: {
                Button("Try Again") { Task { await reload() } }
            }
        } else if threads.isEmpty {
            if isLoading {
                ProgressView("Loading threads…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(unreadOnly ? "No Unread Threads" : "No Followed Threads",
                                       systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Threads you start, reply to, or are mentioned in appear here."))
            }
        } else {
            List(selection: Binding(get: { session.replyTarget }, set: { root in
                guard let root, let thread = threads.first(where: { $0.rootID == root }) else { return }
                session.openThreadFromList(root: thread.rootID, channel: thread.channelID)
            })) {
                ForEach(threads) { thread in
                    ThreadRow(session: session, thread: thread)
                        .tag(thread.rootID)
                        .contextMenu {
                            Button("Open Thread") { session.openThreadFromList(root: thread.rootID, channel: thread.channelID) }
                            if thread.unreadReplies > 0 {
                                Button("Mark as Read") { session.markThreadRead(thread.rootID) }
                            }
                            Divider()
                            Button("Unfollow Thread") { session.setThreadFollowing(thread.rootID, false) }
                        }
                }
                if hasMore, threads.count < Self.maximumThreads {
                    Button(isLoading ? "Loading…" : "Load Older Threads") { Task { await loadMore() } }
                        .disabled(isLoading)
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.inset)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do throws(UserFacingError) {
            let page = try await session.followedThreads(unreadOnly: unreadOnly, before: nil)
            guard !Task.isCancelled else { return }
            threads = page.threads
            hasMore = page.hasMore
            error = nil
        } catch {
            if !Task.isCancelled, error != .cancelled { self.error = error }
        }
    }

    private func loadMore() async {
        guard !isLoading, let last = threads.last?.rootID else { return }
        isLoading = true
        defer { isLoading = false }
        do throws(UserFacingError) {
            let page = try await session.followedThreads(unreadOnly: unreadOnly, before: last)
            let known = Set(threads.map(\.rootID))
            threads.append(contentsOf: page.threads.filter { !known.contains($0.rootID) }
                .prefix(Self.maximumThreads - threads.count))
            hasMore = page.hasMore
        } catch {
            if error != .cancelled { self.error = error }
        }
    }
}

private struct ThreadRow: View {
    let session: SessionViewModel
    let thread: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProfileAvatar(session: session, userID: thread.authorID, revision: thread.authorAvatarRevision,
                          name: thread.authorName, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(thread.authorName.isEmpty ? String(localized: "Unknown") : thread.authorName)
                        .fontWeight(thread.unreadReplies > 0 ? .bold : .semibold)
                        .lineLimit(1)
                    Text(thread.channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(thread.lastReplyAt.date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(verbatim: thread.preview.isEmpty ? String(localized: "(no text)") : thread.preview)
                    .lineLimit(2)
                    .foregroundStyle(thread.unreadReplies > 0 ? .primary : .secondary)
                HStack(spacing: 8) {
                    participants
                    Text(thread.replyCount == 1 ? String(localized: "1 reply") : String(localized: "\(thread.replyCount) replies"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    if thread.unreadMentions > 0 {
                        Text(thread.unreadMentions > 99 ? "99+" : "\(thread.unreadMentions)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    } else if thread.unreadReplies > 0 {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var participants: some View {
        HStack(spacing: -6) {
            ForEach(thread.participants, id: \.id) { person in
                ProfileAvatar(session: session, userID: person.id, revision: person.avatarRevision, name: person.name, size: 18)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
        }
    }

    private var accessibilityText: String {
        var parts = [thread.authorName, thread.channelName, thread.preview,
                     String(localized: "\(thread.replyCount) replies")]
        if thread.unreadMentions > 0 { parts.append(String(localized: "\(thread.unreadMentions) mentions")) }
        else if thread.unreadReplies > 0 { parts.append(String(localized: "unread")) }
        return parts.joined(separator: ", ")
    }
}
