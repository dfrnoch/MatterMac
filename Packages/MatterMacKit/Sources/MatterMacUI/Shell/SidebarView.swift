import SwiftUI
import MatterMacModels
import MatterMacCore

struct SidebarView: View {
    let app: AppModel
    let session: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            if app.slots.count > 1 || app.canAddServer {
                ServerSwitcher(app: app)
                Divider()
            }
            if let sidebar = session.sidebar, sidebar.teams.count > 1 {
                TeamPicker(session: session, sidebar: sidebar)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            List(selection: Binding(
                get: { session.selectedChannel },
                set: { if let id = $0 { session.select(channel: id) } })) {
                if let sidebar = session.sidebar {
                    ForEach(sidebar.sections) { section in
                        Section(sectionTitle(section.kind)) {
                            ForEach(section.rows) { row in
                                SidebarRow(row: row)
                                    .tag(row.channelID)
                            }
                        }
                    }
                    if sidebar.isTruncated {
                        Text("More channels are available through ⌘K.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if session.requiresAuthentication {
                    Text("Sign in again to load channels.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading channels…").foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            ConnectionFooter(session: session)
            Menu("Session") {
                Button("Review Unsent Work…") { session.isUnsentRecoveryVisible = true }
                Button("Copy Unsent Text") { session.copyUnsentText() }
                    .disabled(session.isCopyingUnsentText)
                Divider()
                Button("Sign Out…") { Task { await app.signOut(session.slot.id) } }
            }
            .controlSize(.small).padding(.horizontal, 10).padding(.bottom, 8)
        }
    }

    private func sectionTitle(_ kind: SidebarSection.Kind) -> String {
        switch kind {
        case .favorites: String(localized: "Favorites")
        case .channels: String(localized: "Channels")
        case .directMessages: String(localized: "Direct Messages")
        }
    }
}

struct SidebarRow: View {
    let row: SidebarChannelRow

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 16)
            Text(row.displayName)
                .fontWeight(row.isUnread ? .semibold : .regular)
                .foregroundStyle(row.isArchived || row.isMuted ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if row.mentionCount > 0 {
                Text(row.mentionCount > 99 ? "99+" : "\(row.mentionCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var icon: some View {
        switch row.type {
        case .direct:
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
        case .group:
            Image(systemName: "person.2").foregroundStyle(.secondary)
        case .private:
            Image(systemName: row.isArchived ? "archivebox" : "lock").foregroundStyle(.secondary)
        default:
            Image(systemName: row.isArchived ? "archivebox" : "number").foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch row.partnerStatus {
        case .online: .green
        case .away: .yellow
        case .doNotDisturb: .red
        default: .secondary.opacity(0.5)
        }
    }

    private var accessibilityText: String {
        var parts = [row.displayName]
        if row.mentionCount > 0 { parts.append(String(localized: "\(row.mentionCount) mentions")) }
        else if row.isUnread { parts.append(String(localized: "unread")) }
        if row.isArchived { parts.append(String(localized: "archived")) }
        if row.isMuted { parts.append(String(localized: "muted")) }
        return parts.joined(separator: ", ")
    }
}

struct TeamPicker: View {
    let session: SessionViewModel
    let sidebar: SidebarSnapshot

    var body: some View {
        Picker("Team", selection: Binding(
            get: { sidebar.selectedTeam },
            set: { if let id = $0 { session.selectTeam(id) } })) {
            ForEach(sidebar.teams) { team in
                Text(team.hasUnread ? "\(team.displayName) •" : team.displayName).tag(Optional(team.id))
            }
        }
        .labelsHidden()
    }
}

struct ServerSwitcher: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(app.slots) { slot in
                Button {
                    app.activate(slot.id)
                } label: {
                    Text(initials(slot))
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(slot.id == app.activeSlotID ? Color.accentColor : Color.secondary.opacity(0.25)))
                        .foregroundStyle(slot.id == app.activeSlotID ? .white : .primary)
                }
                .buttonStyle(.plain)
                .help("\(slot.siteName.isEmpty ? slot.endpoint.host : slot.siteName) — @\(slot.user.username)")
                .accessibilityLabel("\(slot.siteName.isEmpty ? slot.endpoint.host : slot.siteName), signed in as \(slot.user.username)")
            }
            if app.canAddServer {
                Button {
                    app.showAddServer()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Add a server")
                .accessibilityLabel("Add a server")
            }
            Spacer()
        }
        .padding(8)
    }

    private func initials(_ slot: SessionRegistry.Slot) -> String {
        let name = slot.siteName.isEmpty ? slot.endpoint.host : slot.siteName
        return String(name.prefix(2)).uppercased()
    }
}

struct ConnectionFooter: View {
    let session: SessionViewModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !session.requiresAuthentication, showsRetry {
                Button("Reconnect") { session.reconnect() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
    }

    private var showsRetry: Bool {
        switch session.connection {
        case .backingOff, .offline, .disconnected: true
        default: false
        }
    }

    private var color: Color {
        switch session.connection {
        case .connected: .green
        case .connecting, .authenticating, .synchronizing: .yellow
        case .backingOff, .offline, .disconnected: .orange
        case .authenticationRequired: .red
        }
    }

    private var text: String {
        switch session.connection {
        case .connected: String(localized: "Connected as @\(session.slot.user.username)")
        case .connecting: String(localized: "Connecting…")
        case .authenticating: String(localized: "Authenticating…")
        case .synchronizing: String(localized: "Syncing…")
        case .backingOff(let seconds): String(localized: "Disconnected. Retrying in \(seconds)s")
        case .offline: String(localized: "Offline — showing messages already loaded")
        case .disconnected: String(localized: "Disconnected")
        case .authenticationRequired: String(localized: "Signed out by the server — sign in again")
        }
    }
}
