import SwiftUI
import MatterMacModels
import MatterMacCore

/// The navigation column: an optional server/team rail at the leading edge, then the
/// selected team's channels in the server's sidebar categories.
struct SidebarView: View {
    let app: AppModel
    @Bindable var session: SessionViewModel

    var body: some View {
        HStack(spacing: 0) {
            if WorkspaceRail.isShown(app: app, sidebar: session.sidebar) {
                WorkspaceRail(app: app, session: session)
                Divider()
            }
            VStack(spacing: 0) {
                SidebarHeader(app: app, session: session)
                channelList
                Divider()
                ConnectionFooter(session: session)
                AccountBar(app: app, session: session)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            // The column may be narrower than the list's ideal width; never push the
            // rail out of the column.
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $session.directorySheet) { sheet in
            DirectorySheetView(session: session, sheet: sheet)
        }
    }

    private var channelList: some View {
        // Drafts are read when the sidebar re-renders (selection or snapshot changes);
        // the composer saves them on every navigation.
        let drafts = Set(app.environment.drafts.nonEmptyKeys(for: session.scope).map(\.channelID))
        return List(selection: Binding(
            get: { session.selectedChannel },
            set: { if let id = $0 { session.select(channel: id) } })) {
            if let sidebar = session.sidebar {
                ForEach(sidebar.sections) { section in
                    let rows = section.visibleRows(selected: session.selectedChannel)
                    if !rows.isEmpty || section.kind == .custom || section.kind == .channels || section.hiddenCount > 0 {
                        Section {
                            ForEach(rows) { row in
                                SidebarRow(row: row, session: session,
                                           hasDraft: drafts.contains(row.channelID) && row.channelID != session.selectedChannel)
                                    .tag(row.channelID)
                                    .contextMenu { rowMenu(row) }
                            }
                            if section.hiddenCount > 0 {
                                Button("More…") { session.directorySheet = .newMessage }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("\(section.hiddenCount) more conversations — start or find a direct message")
                            }
                        } header: {
                            SidebarSectionHeader(section: section, title: SidebarSectionHeader.title(for: section),
                                                 onToggle: section.categoryID == nil ? nil : {
                                                     session.setCategoryCollapsed(section, collapsed: !section.isCollapsed)
                                                 })
                        }
                    }
                }
                if sidebar.isTruncated {
                    Button("More channels…") { session.isQuickSwitcherVisible = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("This session keeps a bounded channel list; find other channels with the quick switcher (⌘K).")
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
    }

    @ViewBuilder private func rowMenu(_ row: SidebarChannelRow) -> some View {
        if row.isUnread || row.mentionCount > 0 {
            Button("Mark as Read") { session.markChannelsRead([row.channelID]) }
            Divider()
        }
        Button("Channel Info") {
            session.select(channel: row.channelID)
            session.isChannelInfoVisible = true
        }
        if (row.type == .open || row.type == .private) && !row.isArchived {
            Button("Add Members…") { session.directorySheet = .addMembers(row.channelID) }
        }
        Divider()
        Button(row.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            session.setFavorite(row.channelID, !row.isFavorite)
        }
        if !row.isArchived {
            Button(row.isMuted ? "Unmute" : "Mute") { session.setMuted(row.channelID, !row.isMuted) }
            Button("Notification Preferences…") { session.showNotificationPreferences(row.channelID) }
        }
        if row.type == .open || row.type == .private {
            Divider()
            Button("Leave Channel…") { session.leaveChannel(row.channelID, displayName: row.displayName) }
        }
    }
}

/// Team name and the menu for browsing, creating and messaging.
struct SidebarHeader: View {
    let app: AppModel
    let session: SessionViewModel

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: teamName)
                    .font(.headline)
                    .lineLimit(1)
                if app.slots.count > 1 {
                    Text(verbatim: serverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Browse Channels…") { session.directorySheet = .browseChannels }
                Button("New Channel…") { session.directorySheet = .createChannel }
                Button("New Direct Message…") { session.directorySheet = .newMessage }
                Divider()
                Button("Mark All as Read") { session.markChannelsRead(nil) }
                Divider()
                Toggle("Group Unread Channels Separately", isOn: Binding(
                    get: { session.sidebar?.groupsUnreads ?? false },
                    set: { session.setGroupsUnreads($0) }))
                if app.canAddServer {
                    Divider()
                    Button("Add Server…") { app.showAddServer() }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(session.requiresAuthentication)
            .help("Browse or create channels and messages")
            .accessibilityLabel("Channels and messages")
            .accessibilityIdentifier("sidebarAddMenu")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    private var teamName: String {
        guard let sidebar = session.sidebar, let team = sidebar.teams.first(where: { $0.id == sidebar.selectedTeam })
        else { return serverName }
        return team.displayName.isEmpty ? team.name : team.displayName
    }

    private var serverName: String {
        session.slot.siteName.isEmpty ? session.slot.endpoint.host : session.slot.siteName
    }
}

/// A category title with a disclosure control. Collapsing writes the category's
/// `collapsed` flag on the server, so the user's other clients follow.
struct SidebarSectionHeader: View {
    let section: SidebarSection
    let title: String
    let onToggle: (() -> Void)?

    static func title(for section: SidebarSection) -> String {
        switch section.kind {
        case .unreads: String(localized: "Unreads")
        case .favorites: String(localized: "Favorites")
        case .channels: String(localized: "Channels")
        case .directMessages: String(localized: "Direct Messages")
        case .custom: section.title.isEmpty ? String(localized: "Category") : section.title
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                            .frame(width: 10)
                        Text(verbatim: title).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.isCollapsed ? "Expand \(title)" : "Collapse \(title)")
            } else {
                Text(verbatim: title).lineLimit(1)
            }
            if section.isMuted {
                Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.tertiary)
                    .help("Muted category")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(onToggle == nil ? [.isHeader] : [.isHeader, .isButton])
        .accessibilityAction { onToggle?() }
    }

    private var accessibilityText: String {
        var parts = [title]
        if onToggle != nil { parts.append(section.isCollapsed ? String(localized: "collapsed") : String(localized: "expanded")) }
        if section.isMuted { parts.append(String(localized: "muted")) }
        return parts.joined(separator: ", ")
    }
}

struct SidebarRow: View {
    let row: SidebarChannelRow
    let session: SessionViewModel
    var hasDraft = false

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: row.partnerID == nil ? 16 : 20)
            Text(row.displayName)
                .fontWeight(row.isUnread ? .semibold : .regular)
                .foregroundStyle(row.isArchived ? .secondary : .primary)
                .lineLimit(1)
                .help(row.partnerUsername.map { "@" + $0 } ?? row.displayName)
            Spacer(minLength: 4)
            if hasDraft {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Unsent draft")
            }
            if row.mentionCount > 0 {
                Text(row.mentionCount > 99 ? "99+" : "\(row.mentionCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            } else if row.isUnread {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            }
        }
        // Muted channels are dimmed; mentions still stand out through the badge.
        .opacity(row.isMuted && row.mentionCount == 0 ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(session.selectedChannel == row.channelID ? .isSelected : [])
        .accessibilityAction { session.select(channel: row.channelID) }
    }

    @ViewBuilder private var icon: some View {
        switch row.type {
        case .direct:
            if let partner = row.partnerID {
                ProfileAvatar(session: session, userID: partner, revision: row.partnerAvatarRevision,
                              name: row.displayName, size: 20, status: row.partnerStatus ?? .offline)
            } else {
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
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
        if hasDraft { parts.append(String(localized: "draft")) }
        if row.isArchived { parts.append(String(localized: "archived")) }
        if row.isMuted { parts.append(String(localized: "muted")) }
        return parts.joined(separator: ", ")
    }
}

/// Leading rail: signed-in servers (circles) above the active server's teams
/// (rounded squares), with unread and mention indicators. ⌘1…⌘9 select teams.
struct WorkspaceRail: View {
    let app: AppModel
    let session: SessionViewModel
    static let width: CGFloat = 52

    static func isShown(app: AppModel, sidebar: SidebarSnapshot?) -> Bool {
        app.slots.count > 1 || (sidebar?.teams.count ?? 0) > 1
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                if app.slots.count > 1 {
                    ForEach(app.slots) { slot in
                        ServerRailButton(app: app, slot: slot)
                    }
                    if app.canAddServer {
                        Button { app.showAddServer() } label: {
                            Image(systemName: "plus")
                                .frame(width: 30, height: 30)
                                .background(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Add a server")
                        .accessibilityLabel("Add a server")
                    }
                    if let teams = session.sidebar?.teams, teams.count > 1 {
                        Divider().frame(width: 26).padding(.vertical, 4)
                    }
                }
                if let sidebar = session.sidebar, sidebar.teams.count > 1 {
                    ForEach(Array(sidebar.teams.enumerated()), id: \.element.id) { index, team in
                        TeamRailButton(session: session, team: team, index: index,
                                       isSelected: team.id == sidebar.selectedTeam)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Servers and teams")
        .accessibilityIdentifier("workspaceRail")
    }
}

struct TeamRailButton: View {
    let session: SessionViewModel
    let team: TeamSummary
    let index: Int
    let isSelected: Bool

    var body: some View {
        Button { session.selectTeam(team.id) } label: {
            TeamIconView(session: session, team: team, size: 32)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                        .padding(-3)
                }
                .overlay(alignment: .topTrailing) {
                    if team.mentionCount > 0 {
                        Text(team.mentionCount > 99 ? "99+" : "\(team.mentionCount)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .foregroundStyle(.white)
                            .offset(x: 7, y: -6)
                    }
                }
                .frame(width: WorkspaceRail.width, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            // Selected: a tall bar; unread elsewhere: a short one (as in the official client).
            if isSelected || team.hasUnread {
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: isSelected ? 22 : 8)
                    .offset(x: -1)
            }
        }
        .help(index < 9 ? "\(team.displayName) (⌘\(index + 1))" : team.displayName)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("team-\(team.name)")
    }

    private var accessibilityText: String {
        var parts = [team.displayName]
        if team.mentionCount > 0 { parts.append(String(localized: "\(team.mentionCount) mentions")) }
        else if team.hasUnread { parts.append(String(localized: "unread")) }
        return parts.joined(separator: ", ")
    }
}

/// The team's icon (`GET /teams/{id}/image` through the bounded image pipeline)
/// when it has one, else its initials on a stable tint.
struct TeamIconView: View {
    let session: SessionViewModel
    let team: TeamSummary
    let size: CGFloat
    @State private var image: NSImage?
    @State private var lease: ImagePipeline.Decoded?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: TimelinePalette.avatarTint(for: team.id.rawValue)).opacity(0.85))
                    .overlay(Text(verbatim: Self.initials(team.displayName.isEmpty ? team.name : team.displayName))
                        .font(.system(size: floor(size * 0.4), weight: .semibold))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: "\(team.id.rawValue)#\(team.iconRevision)") { await load() }
        .onDisappear {
            image = nil
            lease = nil
        }
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    private func load() async {
        image = nil
        lease = nil
        guard team.iconRevision > 0, let pipeline = session.app?.images, !session.isDetached else { return }
        let pixels = Int((size * max(1, displayScale)).rounded(.up))
        guard let decoded = await session.session.teamIcon(team.id, revision: team.iconRevision, maxPixelSize: pixels,
                                                           pipeline: pipeline),
              !Task.isCancelled, !session.isDetached else { return }
        lease = decoded
        image = NSImage(cgImage: decoded.image, size: .zero)
    }
}

struct ServerRailButton: View {
    let app: AppModel
    let slot: SessionRegistry.Slot

    var body: some View {
        let isActive = slot.id == app.activeSlotID
        Button { app.activate(slot.id) } label: {
            Text(verbatim: TeamIconView.initials(name))
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.25)))
                .foregroundStyle(isActive ? .white : .primary)
                .frame(width: WorkspaceRail.width, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(name) — @\(slot.user.username)")
        .accessibilityLabel("\(name), signed in as \(slot.user.username)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var name: String { slot.siteName.isEmpty ? slot.endpoint.host : slot.siteName }
}

/// The signed-in account: picture, presence, custom status, and session actions.
/// Changing the status is an explicit server change visible to other users.
struct AccountBar: View {
    let app: AppModel
    let session: SessionViewModel
    @State private var isProfileVisible = false
    @State private var isCustomStatusVisible = false

    var body: some View {
        let user = session.slot.user
        let status = session.sidebar?.myStatus
        HStack(spacing: 8) {
            Button { isProfileVisible = true } label: {
                ProfileAvatar(session: session, userID: user.id, revision: user.lastPictureUpdate.milliseconds,
                              name: user.username, size: 26, status: status)
            }
            .buttonStyle(.plain)
            .help("View your profile")
            .accessibilityLabel("Your profile")
            .popover(isPresented: $isProfileVisible) {
                UserProfileCard(session: session, lookup: .id(user.id)) { isProfileVisible = false }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "@" + user.username).font(.callout.weight(.medium)).lineLimit(1)
                if let custom = session.sidebar?.myCustomStatus, custom.isVisible(at: .now) {
                    Text(verbatim: [custom.emoji.isEmpty ? "" : EmojiText.display(custom.emoji), custom.text]
                        .filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let status {
                    Text(status.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Section("Status") {
                    ForEach(PresenceStatus.selectable, id: \.self) { option in
                        Toggle(option.label, isOn: Binding(get: { status == option },
                                                            set: { if $0 { session.setStatus(option) } }))
                    }
                    Button("Set Custom Status…") { isCustomStatusVisible = true }
                }
                Section("Notifications") {
                    Toggle("Show Notifications", isOn: Binding(get: { app.notificationsEnabled },
                                                               set: { value in Task { await app.setNotificationsEnabled(value) } }))
                    Toggle("Play Sound", isOn: Binding(get: { app.notificationSounds }, set: { app.notificationSounds = $0 }))
                }
                Divider()
                Button("Review Unsent Work…") { session.isUnsentRecoveryVisible = true }
                Button("Copy Unsent Text") { session.copyUnsentText() }
                    .disabled(session.isCopyingUnsentText)
                Divider()
                Button("About MatterMac") { app.isCompatibilityVisible = true }
                Button("Sign Out…") { Task { await app.signOut(session.slot.id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Status and session")
            .accessibilityLabel("Status and session")
            .sheet(isPresented: $isCustomStatusVisible) {
                CustomStatusView(session: session, current: session.sidebar?.myCustomStatus)
            }
        }
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
