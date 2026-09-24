import SwiftUI
import MatterMacModels
import MatterMacCore

/// Channel identity lives in the window title (name) and subtitle (typing, header
/// or purpose); these toolbar accessories carry status, archive state and members.
/// A header row inside the content would sit under the toolbar's edge effect.
enum ChannelHeaderText {
    static func title(_ header: ChannelHeaderPresentation?) -> String {
        header?.displayName ?? ""
    }

    static func subtitle(_ header: ChannelHeaderPresentation?) -> String {
        guard let header else { return "" }
        if !header.typingNames.isEmpty { return typingText(header.typingNames) }
        let text = header.header.isEmpty ? header.purpose : header.header
        // One line: the subtitle is not a place for a multi-line Markdown header.
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    static func typingText(_ names: [String]) -> String {
        switch names.count {
        case 1: String(localized: "\(names[0]) is typing…")
        case 2: String(localized: "\(names[0]) and \(names[1]) are typing…")
        default: String(localized: "Several people are typing…")
        }
    }
}

struct ChannelHeaderAccessories: View {
    let header: ChannelHeaderPresentation?
    let session: SessionViewModel

    var body: some View {
        if let header {
            HStack(spacing: 10) {
                if header.type == .direct, let status = header.partnerStatus {
                    HStack(spacing: 4) { StatusDot(status: status); Text(status.label) }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                }
                if header.isArchived {
                    Label("Archived", systemImage: "archivebox").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                }
                if let count = header.memberCount {
                    Button { session.isChannelInfoVisible = true } label: {
                        Label("\(count)", systemImage: "person.2").labelStyle(.titleAndIcon)
                    }
                    .help("\(count) members — show channel details")
                    .accessibilityLabel("\(count) members, show channel details")
                }
            }
            .font(.callout)
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
                GroupBox("Sign-in") {
                    Text("""
                        Password (with MFA), personal access tokens, and single sign-on through your system browser \
                        when the server advertises an OpenID, SAML, Google, Microsoft or GitLab route. Single sign-on \
                        depends on your organization's configuration and has been verified only on test deployments.
                        """)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Not supported natively") {
                    VStack(alignment: .leading, spacing: 6) {
                        unsupported("Calls, screen sharing, and video", "Call posts stay readable; joining happens in your browser, outside MatterMac.")
                        unsupported("Web plugins, Boards, Playbooks", "Plugin posts show a summary. Interactive buttons are not executed.")
                        unsupported("Interactive commands and ephemeral posts", "Slash commands run on the server and their text reply appears above the conversation. Command dialogs and ephemeral bot posts are not shown.")
                        unsupported("Custom theme CSS and administration", "Out of scope for MatterMac.")
                        unsupported("Notifications after quitting", "There is no MatterMac push service. While the app runs, the Dock badge counts mentions, and optional notifications (account menu › Show Notifications) announce mentions and direct messages without message text.")
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
