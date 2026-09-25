import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore
import MatterMacPlatform

/// The trailing results pane: server search, recent mentions, saved and pinned
/// messages. Results live in Core's bounded search storage; opening one navigates to
/// its real channel context (SPEC §12).
struct SearchPane: View {
    let session: SessionViewModel
    @State private var terms = ""
    @State private var debounce: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var kind: SearchKind { session.search?.kind ?? .terms }

    var body: some View {
        VStack(spacing: 0) {
            header
            if kind == .terms || kind == .files {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if kind == .terms || kind == .files { fieldFocused = true } }
        .onChange(of: session.search?.kind) { debounce?.cancel(); terms = session.search?.terms ?? "" }
        .onDisappear { debounce?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button { session.clearSearch(); fieldFocused = true } label: { Label("Search", systemImage: "magnifyingglass") }
                Button { terms = ""; session.runFileSearch(""); fieldFocused = true } label: { Label("Files", systemImage: "doc") }
                Button { session.showRecentMentions() } label: { Label("Recent Mentions", systemImage: "at") }
                Button { session.showSavedPosts() } label: { Label("Saved Messages", systemImage: "bookmark") }
                Button { session.showPinnedPosts() } label: { Label("Pinned Messages", systemImage: "pin") }
                    .disabled(session.selectedChannel == nil)
            } label: {
                Label(title, systemImage: symbol).font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button { session.isSearchVisible = false } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close results")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var title: String {
        switch kind {
        case .files: String(localized: "Files")
        case .terms: String(localized: "Search")
        case .recentMentions: String(localized: "Recent Mentions")
        case .saved: String(localized: "Saved Messages")
        case .pinned: String(localized: "Pinned Messages")
        }
    }

    private var symbol: String {
        switch kind {
        case .files: "doc"
        case .terms: "magnifyingglass"
        case .recentMentions: "at"
        case .saved: "bookmark"
        case .pinned: "pin"
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(kind == .files ? "Search files" : "Search messages", text: $terms)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { submit(terms) }
                .onChange(of: terms) { schedule() }
                .accessibilityLabel("Search messages")
            if !terms.isEmpty {
                Button { terms = ""; submit("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassCapsule()
        .help("Supports from:, in:, before:, after:, on:, -excluded and \"exact phrases\"")
    }

    @ViewBuilder private var content: some View {
        switch session.search?.state {
        case .searching?:
            ProgressView(kind == .terms ? "Searching…" : "Loading…").controlSize(.small)
        case .failed(let error)?:
            ContentUnavailableView {
                Label("Couldn’t Load Results", systemImage: "exclamationmark.triangle")
            } description: {
                Text(UserFacingErrorText.describe(error))
            } actions: {
                Button("Try Again", action: retry)
            }
        case .results?:
            if kind == .files {
                FileSearchResults(session: session)
            } else if let search = session.search, !search.items.isEmpty {
                List {
                    ForEach(search.items) { item in
                        SearchResultRow(session: session, item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { session.open(item) }
                            .contextMenu {
                                Button("Jump to Message") { session.open(item) }
                                Button("Open Thread") { session.openThread(for: item) }
                                Divider()
                                Button("Copy Text") { Pasteboard.copy(item.preview) }
                            }
                    }
                    if search.canLoadMore {
                        Button("Load More") { session.loadMoreSearchResults() }
                            .frame(maxWidth: .infinity)
                    } else if search.isTruncated {
                        Text("Showing the first \(search.items.count) results.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(emptyTitle, systemImage: symbol, description: Text(emptyDetail))
            }
        default:
            ContentUnavailableView {
                Label("Search Messages", systemImage: "magnifyingglass")
            } description: {
                Text("Search runs on your Mattermost server. MatterMac keeps no local search index.")
            }
        }
    }

    private var emptyTitle: String {
        switch kind {
        case .files: String(localized: "No Files")
        case .terms: String(localized: "No Results")
        case .recentMentions: String(localized: "No Recent Mentions")
        case .saved: String(localized: "No Saved Messages")
        case .pinned: String(localized: "No Pinned Messages")
        }
    }

    private var emptyDetail: String {
        switch kind {
        case .files, .terms: String(localized: "Try different words or fewer filters.")
        case .recentMentions: String(localized: "Messages that mention you appear here.")
        case .saved: String(localized: "Save messages from their menu to find them here.")
        case .pinned: String(localized: "Pinned messages in this channel appear here.")
        }
    }

    private func retry() {
        switch kind {
        case .files: session.runFileSearch(terms)
        case .terms: session.runSearch(terms)
        case .recentMentions: session.showRecentMentions()
        case .saved: session.showSavedPosts()
        case .pinned: session.showPinnedPosts()
        }
    }

    private func submit(_ text: String) {
        if kind == .files { session.runFileSearch(text) } else { session.runSearch(text) }
    }

    private func schedule() {
        debounce?.cancel()
        let text = terms
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, text.count >= 2 else { return }
            submit(text)
        }
    }
}

private struct SearchResultRow: View {
    let session: SessionViewModel
    let item: SearchResultItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let author = item.authorID {
                ProfileAvatar(session: session, userID: author, revision: item.authorAvatarRevision,
                              name: item.author, size: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.author.isEmpty ? String(localized: "Unknown") : item.author)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(item.channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.createdAt.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: item.preview)
                    .lineLimit(4)
                    .textSelection(.enabled)
                if item.rootID != nil {
                    Label("Reply in thread", systemImage: "arrowshape.turn.up.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the message in its channel")
    }
}
