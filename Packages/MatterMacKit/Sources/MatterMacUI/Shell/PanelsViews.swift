import SwiftUI
import MatterMacModels
import MatterMacCore

struct ChannelHeaderView: View {
    let header: ChannelHeaderPresentation?
    let session: SessionViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let header {
                Image(systemName: symbol(for: header))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(header.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if !header.typingNames.isEmpty {
                        Text(typingText(header.typingNames))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(typingText(header.typingNames))
                    } else if !header.purpose.isEmpty || !header.header.isEmpty {
                        Text(header.header.isEmpty ? header.purpose : header.header)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(header.header.isEmpty ? header.purpose : header.header)
                    }
                }
                Spacer()
                if header.isArchived {
                    Label("Archived", systemImage: "archivebox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let count = header.memberCount {
                    Label("\(count)", systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("\(count) members")
                        .accessibilityLabel("\(count) members")
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func symbol(for header: ChannelHeaderPresentation) -> String {
        switch header.type {
        case .direct: "person"
        case .group: "person.2"
        case .private: "lock"
        default: "number"
        }
    }

    private func typingText(_ names: [String]) -> String {
        switch names.count {
        case 1: String(localized: "\(names[0]) is typing…")
        case 2: String(localized: "\(names[0]) and \(names[1]) are typing…")
        default: String(localized: "Several people are typing…")
        }
    }
}

/// ⌘K quick switcher: channels, DMs, and people (server autocomplete).
struct QuickSwitcherView: View {
    let session: SessionViewModel
    @State private var query = ""
    @State private var results: [QuickSwitchItem] = []
    @State private var selection: QuickSwitchItem.Kind?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TextField("Switch to a channel or person…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit(openSelection)
                .onChange(of: query) { schedule() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .accessibilityLabel("Quick switcher")
            Divider()
            List(results, selection: $selection) { item in
                HStack {
                    Image(systemName: icon(for: item)).foregroundStyle(.secondary).frame(width: 18)
                    Text(item.title).fontWeight(item.isUnread ? .semibold : .regular)
                    Spacer()
                    Text(item.subtitle).foregroundStyle(.secondary).font(.caption)
                }
                .tag(item.kind)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { session.open(item); dismiss() }
            }
            .listStyle(.plain)
        }
        .frame(width: 520, height: 380)
        .onAppear {
            focused = true
            schedule()
        }
        .onDisappear { searchTask?.cancel() }
        .onExitCommand { dismiss() }
    }

    private func icon(for item: QuickSwitchItem) -> String {
        switch item.channelType {
        case .direct?: "person"
        case .group?: "person.2"
        case .private?: "lock"
        default: "number"
        }
    }

    private func schedule() {
        searchTask?.cancel()
        let text = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await session.quickSwitcherResults(text)
            guard !Task.isCancelled else { return }
            results = found
            selection = found.first?.kind
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.kind == selection } ?? -1
        selection = results[max(0, min(results.count - 1, index + delta))].kind
    }

    private func openSelection() {
        guard let item = results.first(where: { $0.kind == selection }) ?? results.first else { return }
        session.open(item)
        dismiss()
    }
}

/// ⌘F server search. Results are opened in their real channel context.
struct SearchPanel: View {
    let session: SessionViewModel
    @State private var terms = ""
    @State private var debounce: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search messages (from:, in:, before:, after:, \"phrase\")", text: $terms)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { session.runSearch(terms) }
                    .onChange(of: terms) { schedule() }
                    .accessibilityLabel("Search messages")
                Button {
                    session.clearSearch()
                    session.isSearchVisible = false
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close search")
            }
            .padding(10)
            Divider()
            content
        }
        .onAppear { focused = true }
        .onDisappear { debounce?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch session.search?.state {
        case .searching?:
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error)?:
            VStack(spacing: 8) {
                Text(UserFacingErrorText.describe(error)).foregroundStyle(.secondary)
                Button("Try Again") { session.runSearch(terms) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results?:
            if let search = session.search, !search.items.isEmpty {
                List(search.items) { item in
                    Button { session.open(item) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.author).font(.caption.weight(.semibold))
                                Text("in \(item.channelName)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(item.createdAt.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(item.preview).lineLimit(3)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                if search.canLoadMore {
                    Button("Load More Results") { session.loadMoreSearchResults() }.padding(8)
                } else if search.isTruncated {
                    Text("Showing the first \(search.items.count) results. Refine the search to see others.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            } else {
                Text("No results.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            Text("Search runs on your Mattermost server. MatterMac keeps no local search index.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func schedule() {
        debounce?.cancel()
        let text = terms
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, text.count >= 2 else { return }
            session.runSearch(text)
        }
    }
}

/// About / Compatibility (SPEC §19, §20): version, verified server info, session
/// identity, and honest boundaries for unsupported features.
struct CompatibilityView: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("MatterMac").font(.title.weight(.semibold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    .foregroundStyle(.secondary)
                Text("An independent, open-source, Mattermost-compatible client. Not affiliated with or endorsed by Mattermost, Inc.")
                    .font(.callout)
                if let slot = app.registry.active {
                    GroupBox("Active session") {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Server", value: slot.endpoint.description)
                            LabeledContent("Signed in as", value: "@\(slot.user.username)")
                            LabeledContent("Server name", value: slot.siteName.isEmpty ? "—" : slot.siteName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GroupBox("Tested server releases") {
                    Text("Mattermost 11.11 and 10.11 (ESR). Other versions may work but have not been verified.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Not supported natively") {
                    VStack(alignment: .leading, spacing: 6) {
                        unsupported("Calls, screen sharing, and video", "Call posts stay readable; joining happens in your browser, outside MatterMac.")
                        unsupported("Web plugins, Boards, Playbooks", "Plugin posts show a summary. Interactive buttons are not executed.")
                        unsupported("Single sign-on (SAML, OpenID, Google, Entra ID, GitLab)", "Use password or a personal access token if your server allows it.")
                        unsupported("Slash commands and ephemeral replies", "Not yet implemented.")
                        unsupported("Custom theme CSS and administration", "Out of scope for MatterMac.")
                        unsupported("Notifications after quitting", "There is no MatterMac push service; badges work only while the app runs.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Privacy") {
                    Text("""
                        MatterMac keeps your session, messages, drafts, and images only in memory while it runs. \
                        It writes no database, cache, token, or log to disk. Files you explicitly save or export, and \
                        system services (swap, clipboard managers, file dialogs), are outside that guarantee.
                        """)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 600)
    }

    private func unsupported(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
