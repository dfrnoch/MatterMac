import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

/// Channel details inspector: header/purpose, favorite and mute (explicit server
/// changes), link, leave, and a paged member list. Everything is fetched on demand
/// and dropped when the inspector closes or the channel changes; the member list is
/// capped at `maximumMembers` rows.
struct ChannelInfoView: View {
    let session: SessionViewModel
    let channel: ChannelID
    @State private var details: ChannelDetailsPresentation?
    @State private var error: UserFacingError?
    @State private var members: [ChannelMemberRow] = []
    @State private var nextPage = 0
    @State private var hasMore = false
    @State private var isLoadingMembers = false
    @State private var membersError: UserFacingError?
    @State private var memberFilter = ""
    @State private var profile: ProfileTarget?

    static let maximumMembers = 600

    struct ProfileTarget: Identifiable, Hashable {
        let id: UserID
    }

    var body: some View {
        Group {
            if let details {
                content(details)
            } else if let error {
                VStack(spacing: 8) {
                    Text(UserFacingErrorText.describe(error)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await loadDetails() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading channel details…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: channel) {
            details = nil
            error = nil
            resetMembers()
            await loadDetails()
            await loadMembers()
        }
        .onChange(of: session.channelInfoRevision) { Task { await loadDetails() } }
    }

    private func content(_ details: ChannelDetailsPresentation) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(details.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                    } icon: {
                        Image(systemName: symbol(details.type)).foregroundStyle(.secondary)
                    }
                    if !details.type.isDirectOrGroup {
                        Text(verbatim: "~" + details.name).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    HStack(spacing: 10) {
                        if let count = details.memberCount {
                            Label("\(count) members", systemImage: "person.2").labelStyle(.titleAndIcon)
                        }
                        if let pinned = details.pinnedPostCount, pinned > 0 {
                            Label("\(pinned) pinned", systemImage: "pin")
                        }
                        if details.isArchived { Label("Archived", systemImage: "archivebox") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !details.purpose.isEmpty {
                Section("Purpose") { Text(details.purpose).textSelection(.enabled) }
            }
            if !details.header.isEmpty {
                Section("Header") { Text(details.header).textSelection(.enabled) }
            }
            Section("Settings") {
                Toggle("Favorite", isOn: Binding(get: { details.isFavorite },
                                                  set: { session.setFavorite(channel, $0) }))
                    .help("Moves the channel into or out of Favorites on the server.")
                Toggle("Mute", isOn: Binding(get: { details.isMuted },
                                              set: { session.setMuted(channel, $0) }))
                    .help("Muted channels are marked unread only for mentions. This changes your notification setting on the server.")
                    .disabled(details.isArchived)
                if let partner = details.directPartner {
                    Button("View Profile") { profile = ProfileTarget(id: partner) }
                        .popover(isPresented: profileBinding(partner), arrowEdge: .leading) {
                            UserProfileCard(session: session, lookup: .id(partner)) { profile = nil }
                        }
                }
                if let link = details.link {
                    Button("Copy Channel Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    }
                }
                if (details.type == .open || details.type == .private) && !details.isArchived {
                    Button("Add Members…") { session.directorySheet = .addMembers(channel) }
                }
                if details.canLeave {
                    Button("Leave Channel…", role: .destructive) {
                        session.leaveChannel(channel, displayName: details.displayName)
                    }
                }
            }
            if details.type != .direct {
                membersSection
            }
        }
        .listStyle(.inset)
    }

    /// Presents the profile card anchored to the view that opened it.
    private func profileBinding(_ user: UserID) -> Binding<Bool> {
        Binding(get: { profile?.id == user }, set: { if !$0, profile?.id == user { profile = nil } })
    }

    @ViewBuilder private var membersSection: some View {
        Section {
            TextField("Filter loaded members", text: $memberFilter)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter loaded members")
            ForEach(filteredMembers) { member in
                Button { profile = ProfileTarget(id: member.userID) } label: { MemberRow(session: session, member: member) }
                    .buttonStyle(.plain)
                    .popover(isPresented: profileBinding(member.userID), arrowEdge: .leading) {
                        UserProfileCard(session: session, lookup: .id(member.userID)) { profile = nil }
                    }
                    .contextMenu {
                        Button("View Profile") { profile = ProfileTarget(id: member.userID) }
                        Button("Send Message") { session.openDirectMessage(with: member.userID) }
                    }
            }
            if let membersError {
                HStack {
                    Text(UserFacingErrorText.describe(membersError)).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await loadMembers() } }
                }
            } else if isLoadingMembers {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if hasMore {
                if members.count >= Self.maximumMembers {
                    Text("Showing the first \(members.count) members.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Load More Members") { Task { await loadMembers() } }
                }
            }
        } header: {
            Text("Members")
        }
    }

    private var filteredMembers: [ChannelMemberRow] {
        let needle = memberFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return members }
        return members.filter { $0.displayName.lowercased().contains(needle) || $0.username.lowercased().contains(needle) }
    }

    private func resetMembers() {
        members = []
        nextPage = 0
        hasMore = false
        membersError = nil
        memberFilter = ""
    }

    private func loadDetails() async {
        do throws(UserFacingError) {
            let loaded = try await session.channelDetails(channel)
            guard !Task.isCancelled else { return }
            details = loaded
            error = nil
        } catch {
            if !Task.isCancelled, error != .cancelled { self.error = error }
        }
    }

    private func loadMembers() async {
        guard !isLoadingMembers, members.count < Self.maximumMembers else { return }
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        let target = channel
        do throws(UserFacingError) {
            let page = try await session.channelMembers(target, page: nextPage)
            guard !Task.isCancelled, target == channel else { return }
            let known = Set(members.map(\.userID))
            members.append(contentsOf: page.members.filter { !known.contains($0.userID) }.prefix(Self.maximumMembers - members.count))
            nextPage += 1
            hasMore = page.hasMore
            membersError = nil
        } catch {
            if !Task.isCancelled, error != .cancelled { membersError = error }
        }
    }

    private func symbol(_ type: ChannelType) -> String {
        switch type {
        case .direct: "person"
        case .group: "person.2"
        case .private: "lock"
        default: "number"
        }
    }
}

private struct MemberRow: View {
    let session: SessionViewModel
    let member: ChannelMemberRow

    var body: some View {
        HStack(spacing: 8) {
            ProfileAvatar(session: session, userID: member.userID, revision: member.avatarRevision,
                          name: member.displayName, size: 24, status: member.status)
            VStack(alignment: .leading, spacing: 0) {
                Text(member.displayName).lineLimit(1)
                if member.displayName != member.username {
                    Text(verbatim: "@" + member.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if member.isBot { tag("Bot") }
            if member.isGuest { tag("Guest") }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private func tag(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var accessibilityText: String {
        var parts = [member.displayName, "@" + member.username]
        if let status = member.status { parts.append(status.label) }
        if member.isBot { parts.append(String(localized: "bot")) }
        if member.isGuest { parts.append(String(localized: "guest")) }
        return parts.joined(separator: ", ")
    }
}
