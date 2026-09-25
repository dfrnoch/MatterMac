import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore
import MatterMacPlatform

/// Channel details inspector: identity, purpose and rendered header, favorite and
/// mute (explicit server changes), actions, leave, and a paged member list.
/// Everything is fetched on demand and dropped when the inspector closes or the
/// channel changes; the member list is capped at `maximumMembers` rows.
///
/// Each group is its own view: small view values keep SwiftUI's (debug) stack use
/// low while the lazy member list lays out.
struct ChannelInfoView: View {
    let session: SessionViewModel
    let channel: ChannelID
    @State private var details: ChannelDetailsPresentation?
    @State private var headerText: AttributedString?
    @State private var error: UserFacingError?

    static let maximumMembers = 600
    static let membersAnchor = "channel-info-members"

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
            headerText = nil
            error = nil
            await loadDetails()
        }
        .onChange(of: session.channelInfoRevision) { Task { await loadDetails() } }
    }

    private func content(_ details: ChannelDetailsPresentation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ChannelIdentityHeader(session: session, details: details) {
                        withAnimation { proxy.scrollTo(Self.membersAnchor, anchor: .top) }
                    }
                    if !details.purpose.isEmpty || !details.header.isEmpty {
                        ChannelAboutGroup(session: session, details: details, headerText: headerText)
                    }
                    ChannelSettingsGroup(session: session, details: details)
                    ChannelActionsGroup(session: session, details: details)
                    if details.canLeave {
                        InfoGroup {
                            Button(role: .destructive) {
                                session.leaveChannel(details.channelID, displayName: details.displayName)
                            } label: {
                                InfoRowLabel(Text("Leave Channel…"), systemImage: "rectangle.portrait.and.arrow.right",
                                             tint: .red, isDestructive: true)
                            }
                            .buttonStyle(InfoRowButtonStyle())
                        }
                    }
                    if details.type != .direct {
                        ChannelMembersSection(session: session, channel: channel)
                            .id(Self.membersAnchor)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func loadDetails() async {
        do throws(UserFacingError) {
            let loaded = try await session.channelDetails(channel)
            guard !Task.isCancelled else { return }
            if loaded.header != details?.header || headerText == nil {
                headerText = loaded.header.isEmpty ? nil
                    : ChannelHeaderMarkup.render(loaded.header, parse: session.app?.environment.markupParse)
            }
            details = loaded
            error = nil
        } catch {
            if !Task.isCancelled, error != .cancelled { self.error = error }
        }
    }
}

// MARK: - Identity

/// Icon, name, handle (or DM presence) and statistic pills.
private struct ChannelIdentityHeader: View {
    let session: SessionViewModel
    let details: ChannelDetailsPresentation
    let showMembers: () -> Void

    var body: some View {
        let partner = details.type == .direct ? partnerRow : nil
        VStack(spacing: 6) {
            ChannelInfoIcon(session: session, details: details, partner: partner)
                .padding(.bottom, 4)
            Text(details.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !details.type.isDirectOrGroup {
                Text(verbatim: "~" + details.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let partner, partner.partnerStatus != nil || partner.partnerUsername != nil {
                HStack(spacing: 5) {
                    if let status = partner.partnerStatus {
                        StatusDot(status: status)
                        Text(status.label)
                    }
                    if let username = partner.partnerUsername {
                        if partner.partnerStatus != nil { Text(verbatim: "·").accessibilityHidden(true) }
                        Text(verbatim: "@" + username)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            if details.memberCount != nil || details.pinnedPostCount != nil || details.isArchived {
                ViewThatFits(in: .horizontal) {
                    pills(compact: false)
                    pills(compact: true)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func pills(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if let count = details.memberCount {
                Button(action: showMembers) {
                    pillLabel(compact ? Text(verbatim: "\(count)") : Text("\(count) members"), systemImage: "person.2.fill")
                }
                .help("\(count) members — show the member list")
                .accessibilityLabel(Text("\(count) members"))
            }
            if let pinned = details.pinnedPostCount {
                Button { session.showPinnedPosts() } label: {
                    pillLabel(compact ? Text(verbatim: "\(pinned)") : Text("\(pinned) pinned"), systemImage: "pin.fill")
                }
                .help("Show pinned messages")
                .accessibilityLabel(Text("\(pinned) pinned messages"))
            }
            if details.isArchived {
                pillLabel(Text("Archived"), systemImage: "archivebox.fill")
                    .modifier(InfoPillBackground(fill: 0.06))
                    .accessibilityElement(children: .combine)
            }
        }
        .buttonStyle(InfoPillButtonStyle())
        .fixedSize()
    }

    private func pillLabel(_ title: Text, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            title.foregroundStyle(.primary)
        }
    }

    /// The DM partner (avatar revision, presence, username) from the sidebar snapshot.
    private var partnerRow: SidebarChannelRow? {
        guard let sections = session.sidebar?.sections else { return nil }
        for section in sections {
            if let row = section.rows.first(where: { $0.channelID == details.channelID }) { return row }
        }
        return nil
    }
}

// MARK: - About

/// Purpose and the header with Markdown rendered; links follow the safe-link policy.
private struct ChannelAboutGroup: View {
    let session: SessionViewModel
    let details: ChannelDetailsPresentation
    let headerText: AttributedString?

    var body: some View {
        InfoGroup {
            if !details.purpose.isEmpty {
                block(title: "Purpose", text: Text(details.purpose))
            }
            if !details.purpose.isEmpty && !details.header.isEmpty {
                InfoDivider(leadingInset: 12)
            }
            if !details.header.isEmpty {
                block(title: "Header", text: Text(headerText ?? AttributedString(details.header)))
                    .environment(\.openURL, ChannelHeaderMarkup.openAction(for: session))
            }
        }
    }

    private func block(title: LocalizedStringKey, text: Text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            text
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Settings

private struct ChannelSettingsGroup: View {
    let session: SessionViewModel
    let details: ChannelDetailsPresentation

    var body: some View {
        let channel = details.channelID
        InfoGroup(title: "Settings") {
            InfoRowLabel(Text("Favorite"), systemImage: "star.fill", tint: .yellow, isTitleAccessible: false) {
                Toggle("Favorite", isOn: Binding(get: { details.isFavorite },
                                                 set: { session.setFavorite(channel, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .help("Moves the channel into or out of Favorites on the server.")
            InfoDivider()
            InfoRowLabel(Text("Mute"), systemImage: "bell.slash.fill", tint: .indigo, isTitleAccessible: false) {
                Toggle("Mute", isOn: Binding(get: { details.isMuted },
                                             set: { session.setMuted(channel, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .help("Muted channels are marked unread only for mentions. This changes your notification setting on the server.")
            .disabled(details.isArchived)
            InfoDivider()
            Button { session.showNotificationPreferences(channel) } label: {
                InfoRowLabel(Text("Notification Preferences…"), systemImage: "bell.badge.fill", tint: .red) {
                    InfoChevron()
                }
            }
            .buttonStyle(InfoRowButtonStyle())
            .disabled(details.isArchived)
        }
    }
}

// MARK: - Actions

private struct ChannelActionsGroup: View {
    let session: SessionViewModel
    let details: ChannelDetailsPresentation
    @State private var isShowingProfile = false
    @State private var isEditing = false
    @State private var didCopyLink = false

    var body: some View {
        InfoGroup {
            if let partner = details.directPartner {
                Button { isShowingProfile = true } label: {
                    InfoRowLabel(Text("View Profile"), systemImage: "person.crop.circle.fill", tint: .blue) {
                        InfoChevron()
                    }
                }
                .buttonStyle(InfoRowButtonStyle())
                .popover(isPresented: $isShowingProfile, arrowEdge: .leading) {
                    UserProfileCard(session: session, lookup: .id(partner)) { isShowingProfile = false }
                }
                InfoDivider()
            }
            Button { session.runFileSearch("in:" + details.name) } label: {
                InfoRowLabel(Text("Channel Files"), systemImage: "doc.on.doc.fill", tint: .blue) { InfoChevron() }
            }
            .buttonStyle(InfoRowButtonStyle())
            InfoDivider()
            Button { session.showPinnedPosts() } label: {
                InfoRowLabel(Text("Pinned Messages"), systemImage: "pin.fill", tint: .orange) {
                    HStack(spacing: 6) {
                        if let pinned = details.pinnedPostCount { Text(verbatim: "\(pinned)").monospacedDigit() }
                        InfoChevron()
                    }
                }
            }
            .buttonStyle(InfoRowButtonStyle())
            .accessibilityLabel(details.pinnedPostCount.map { String(localized: "Pinned Messages (\($0))") }
                                ?? String(localized: "Pinned Messages"))
            if !details.type.isDirectOrGroup, !details.isArchived {
                InfoDivider()
                Button { isEditing = true } label: {
                    InfoRowLabel(Text("Edit Channel…"), systemImage: "pencil", tint: .gray) { InfoChevron() }
                }
                .buttonStyle(InfoRowButtonStyle())
                .sheet(isPresented: $isEditing) { EditChannelSheet(session: session, details: details) }
            }
            if (details.type == .open || details.type == .private) && !details.isArchived {
                InfoDivider()
                Button { session.directorySheet = .addMembers(details.channelID) } label: {
                    InfoRowLabel(Text("Add Members…"), systemImage: "person.badge.plus", tint: .green) { InfoChevron() }
                }
                .buttonStyle(InfoRowButtonStyle())
            }
            if let link = details.link {
                InfoDivider()
                Button {
                    Pasteboard.copy(link.absoluteString)
                    withAnimation { didCopyLink = true }
                } label: {
                    InfoRowLabel(Text("Copy Channel Link"), systemImage: "link", tint: .teal) {
                        if didCopyLink {
                            Label("Copied", systemImage: "checkmark")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .transition(.opacity)
                        }
                    }
                }
                .buttonStyle(InfoRowButtonStyle())
                .task(id: didCopyLink) {
                    guard didCopyLink else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled { withAnimation { didCopyLink = false } }
                }
            }
        }
    }
}

// MARK: - Members

/// The paged member list with a local filter; loads its first page when shown.
private struct ChannelMembersSection: View {
    let session: SessionViewModel
    let channel: ChannelID
    @State private var members: [ChannelMemberRow] = []
    @State private var nextPage = 0
    @State private var hasMore = false
    @State private var isLoadingMembers = false
    @State private var membersError: UserFacingError?
    @State private var memberFilter = ""
    @State private var profile: ChannelInfoView.ProfileTarget?

    private var maximumMembers: Int { ChannelInfoView.maximumMembers }

    var body: some View {
        let rows = filteredMembers
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Members")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !members.isEmpty {
                    Text(verbatim: "\(members.count)\(hasMore ? "+" : "")")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 4)
            MemberFilterField(text: $memberFilter)
            InfoGroup {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { member in
                        MemberListRow(session: session, member: member, isFirst: member.id == rows.first?.id,
                                      profile: $profile)
                    }
                    footer(hasRows: !rows.isEmpty)
                }
            }
        }
        .task(id: channel) {
            resetMembers()
            await loadMembers()
        }
    }

    @ViewBuilder private func footer(hasRows: Bool) -> some View {
        if let membersError {
            if hasRows { InfoDivider(leadingInset: 12) }
            HStack {
                Text(UserFacingErrorText.describe(membersError)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Retry") { Task { await loadMembers() } }.controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else if isLoadingMembers {
            if hasRows { InfoDivider(leadingInset: 12) }
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
        } else if hasMore {
            if hasRows { InfoDivider(leadingInset: 12) }
            if members.count >= maximumMembers {
                Text("Showing the first \(members.count) members.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                Button { Task { await loadMembers() } } label: {
                    Text("Load More Members")
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InfoRowButtonStyle())
            }
        } else if !hasRows {
            Text(memberFilter.isEmpty ? "No members loaded." : "No loaded members match.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
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

    private func loadMembers() async {
        guard !isLoadingMembers, members.count < maximumMembers else { return }
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        let target = channel
        do throws(UserFacingError) {
            let page = try await session.channelMembers(target, page: nextPage)
            guard !Task.isCancelled, target == channel else { return }
            let known = Set(members.map(\.userID))
            members.append(contentsOf: page.members.filter { !known.contains($0.userID) }.prefix(maximumMembers - members.count))
            nextPage += 1
            hasMore = page.hasMore
            membersError = nil
        } catch {
            if !Task.isCancelled, error != .cancelled { membersError = error }
        }
    }
}

private struct MemberFilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter loaded members", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Filter loaded members")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// One member: opens the profile card; the context menu also offers a message.
private struct MemberListRow: View {
    let session: SessionViewModel
    let member: ChannelMemberRow
    let isFirst: Bool
    @Binding var profile: ChannelInfoView.ProfileTarget?

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { InfoDivider(leadingInset: 48) }
            Button { profile = ChannelInfoView.ProfileTarget(id: member.userID) } label: {
                MemberRow(session: session, member: member)
            }
            .buttonStyle(InfoRowButtonStyle())
            .popover(isPresented: isPresented, arrowEdge: .leading) {
                UserProfileCard(session: session, lookup: .id(member.userID)) { profile = nil }
            }
            .contextMenu {
                Button("View Profile") { profile = ChannelInfoView.ProfileTarget(id: member.userID) }
                Button("Send Message") { session.openDirectMessage(with: member.userID) }
            }
        }
    }

    /// Presents the profile card anchored to the row that opened it.
    private var isPresented: Binding<Bool> {
        let user = member.userID
        return Binding(get: { profile?.id == user }, set: { if !$0, profile?.id == user { profile = nil } })
    }
}

/// The large identity icon: a DM partner's avatar, or a rounded tile with the
/// channel kind's symbol; archived channels carry a badge.
private struct ChannelInfoIcon: View {
    let session: SessionViewModel
    let details: ChannelDetailsPresentation
    let partner: SidebarChannelRow?
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 64

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if details.type == .direct, let user = details.directPartner {
                ProfileAvatar(session: session, userID: user, revision: partner?.partnerAvatarRevision ?? 0,
                              name: details.displayName, size: size, status: partner?.partnerStatus)
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: symbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
            if details.isArchived {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Circle().fill(Color.gray))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch details.type {
        case .direct: "person.fill"
        case .group: "person.2.fill"
        case .private: "lock.fill"
        default: "number"
        }
    }

    private var tint: Color {
        if details.isArchived { return .gray }
        switch details.type {
        case .group: return .teal
        case .private: return .orange
        default: return .blue
        }
    }
}

private struct MemberRow: View {
    let session: SessionViewModel
    let member: ChannelMemberRow

    var body: some View {
        HStack(spacing: 10) {
            ProfileAvatar(session: session, userID: member.userID, revision: member.avatarRevision,
                          name: member.displayName, size: 28, status: member.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName).lineLimit(1)
                if member.displayName != member.username {
                    Text(verbatim: "@" + member.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if member.isBot { MemberTag(title: "Bot") }
            if member.isGuest { MemberTag(title: "Guest") }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [member.displayName, "@" + member.username]
        if let status = member.status { parts.append(status.label) }
        if member.isBot { parts.append(String(localized: "bot")) }
        if member.isGuest { parts.append(String(localized: "guest")) }
        return parts.joined(separator: ", ")
    }
}

/// A small capsule tag (bot, guest). A separate view rather than a generic helper
/// function: the `some View` helper crashed the member list at runtime in the
/// debug test host whenever a bot member row became visible.
private struct MemberTag: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// Rename a channel or change its purpose and header (explicit server change;
/// the server decides whether the user may).
private struct EditChannelSheet: View {
    let session: SessionViewModel
    let details: ChannelDetailsPresentation
    @State private var name = ""
    @State private var purpose = ""
    @State private var header = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Channel").font(.title3.weight(.semibold))
            LabeledContent("Name") {
                TextField("Channel name", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Purpose").font(.callout.weight(.medium))
                TextEditor(text: $purpose).frame(height: 60).font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                Text("\(purpose.count)/250").font(.caption).foregroundStyle(purpose.count > 250 ? .red : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Header").font(.callout.weight(.medium))
                TextEditor(text: $header).frame(height: 80).font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                Text("Shown under the channel name. Markdown is supported. \(header.count)/1024")
                    .font(.caption).foregroundStyle(header.count > 1024 ? .red : .secondary)
            }
            Text("Changes are saved on the server and visible to everyone in the channel.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    session.updateChannel(details.channelID, displayName: name, header: header, purpose: purpose)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 64
                          || purpose.count > 250 || header.count > 1024)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = details.displayName
            purpose = details.purpose
            header = details.header
        }
    }
}
