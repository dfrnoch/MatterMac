import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

/// How a profile card finds its user: by ID (authors, members) or by `@username`
/// (mentions in message text).
enum ProfileLookup: Hashable {
    case id(UserID)
    case username(String)
}

extension PresenceStatus {
    var label: String {
        switch self {
        case .online: String(localized: "Online")
        case .away: String(localized: "Away")
        case .doNotDisturb: String(localized: "Do Not Disturb")
        case .offline: String(localized: "Offline")
        case .outOfOffice: String(localized: "Out of Office")
        case .unknown: String(localized: "Status unknown")
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .away: .yellow
        case .doNotDisturb, .outOfOffice: .red
        case .offline, .unknown: .secondary.opacity(0.5)
        }
    }

    /// Statuses the user can choose; the server has no manual "unknown".
    static let selectable: [PresenceStatus] = [.online, .away, .doNotDisturb, .offline]
}

struct StatusDot: View {
    let status: PresenceStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: size > 9 ? 2 : 0))
            .accessibilityHidden(true)
    }
}

/// A round profile picture loaded through the shared, bounded image pipeline.
/// Initials on a stable tint are shown until (or unless) the image arrives. The
/// decoded image's budget lease is held only while this view is on screen.
struct ProfileAvatar: View {
    let session: SessionViewModel
    let userID: UserID
    let revision: Int64
    let name: String
    let size: CGFloat
    var status: PresenceStatus?
    @State private var image: NSImage?
    @State private var lease: ImagePipeline.Decoded?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Circle()
                        .fill(Color(nsColor: TimelinePalette.avatarTint(for: userID.rawValue)).opacity(0.85))
                        .overlay(Text(AvatarView.initials(for: name))
                            .font(.system(size: floor(size * 0.4), weight: .semibold))
                            .foregroundStyle(.white))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            if let status { StatusDot(status: status, size: max(8, floor(size * 0.28))) }
        }
        .accessibilityHidden(true)
        .task(id: "\(userID.rawValue)#\(revision)") { await load() }
        .onDisappear {
            image = nil
            lease = nil
        }
    }

    private func load() async {
        image = nil
        lease = nil
        guard let pipeline = session.app?.images, !session.isDetached else { return }
        let pixels = Int((size * max(1, displayScale)).rounded(.up))
        guard let decoded = await session.session.profileImage(userID, revision: revision, maxPixelSize: pixels,
                                                                pipeline: pipeline),
              !Task.isCancelled, !session.isDetached else { return }
        lease = decoded
        image = NSImage(cgImage: decoded.image, size: .zero)
    }
}

/// Profile card shown from avatars, author names, `@mentions` and member lists.
struct UserProfileCard: View {
    let session: SessionViewModel
    let lookup: ProfileLookup
    var onClose: () -> Void = {}
    @State private var state: LoadState = .loading

    enum LoadState: Equatable {
        case loading
        case loaded(UserProfilePresentation)
        case unavailable
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading profile…")
                    .controlSize(.small)
                    .frame(width: 300, height: 120)
            case .unavailable:
                Text("This profile is not available. The user may not exist or may not be visible to you.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: 300)
            case .loaded(let profile):
                content(profile)
            }
        }
        .task(id: lookup) { await load() }
    }

    private func load() async {
        state = .loading
        let profile: UserProfilePresentation? = switch lookup {
        case .id(let id): await session.profile(for: id)
        case .username(let name): await session.profile(username: name)
        }
        guard !Task.isCancelled else { return }
        state = profile.map(LoadState.loaded) ?? .unavailable
    }

    private func content(_ profile: UserProfilePresentation) -> some View {
        let user = profile.user
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ProfileAvatar(session: session, userID: user.id, revision: user.lastPictureUpdate.milliseconds,
                              name: profile.displayName, size: 56, status: profile.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(verbatim: "@" + user.username)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    badges(profile)
                }
            }
            .accessibilityElement(children: .combine)
            if !user.position.isEmpty {
                Text(user.position).font(.callout)
            }
            if let custom = user.customStatus, custom.isVisible(at: .now) {
                customStatus(custom)
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                if let status = profile.status {
                    row("Status") {
                        HStack(spacing: 5) {
                            StatusDot(status: status)
                            if let end = profile.doNotDisturbEnd {
                                Text("Do Not Disturb until \(end.formatted(date: .omitted, time: .shortened))")
                            } else { Text(status.label) }
                        }
                    }
                }
                if let zone = user.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) {
                    row("Local time") { LocalTimeText(zone: zone) }
                }
                if !user.fullName.isEmpty, user.fullName != profile.displayName {
                    row("Name") { Text(user.fullName).textSelection(.enabled) }
                }
                if !user.nickname.isEmpty, user.nickname != profile.displayName {
                    row("Nickname") { Text(user.nickname).textSelection(.enabled) }
                }
                if !user.email.isEmpty {
                    row("Email") { Text(verbatim: user.email).textSelection(.enabled) }
                }
            }
            .font(.callout)
            actions(profile)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder private func badges(_ profile: UserProfilePresentation) -> some View {
        let user = profile.user
        let labels = [
            profile.isCurrentUser ? String(localized: "You") : nil,
            user.isBot ? String(localized: "Bot") : nil,
            user.isGuest ? String(localized: "Guest") : nil,
            user.isDeactivated ? String(localized: "Deactivated") : nil,
            user.isSystemAdmin ? String(localized: "System Admin") : nil,
        ].compactMap { $0 }
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
            }
        }
    }

    private func customStatus(_ status: CustomStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !status.emoji.isEmpty { Text(EmojiText.display(status.emoji)) }
            VStack(alignment: .leading, spacing: 1) {
                if !status.text.isEmpty { Text(status.text).textSelection(.enabled) }
                if let expires = status.expiresAt {
                    Text("Until \(expires.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }

    @ViewBuilder private func actions(_ profile: UserProfilePresentation) -> some View {
        HStack {
            if profile.isCurrentUser {
                Button("Edit Profile…") {
                    onClose()
                    ProfileEditSheet.present(session: session)
                }
                Menu("Set Status") {
                    ForEach(PresenceStatus.selectable, id: \.self) { status in
                        Button(status.label) {
                            session.setStatus(status)
                            onClose()
                        }
                    }
                }
                .fixedSize()
            } else if !profile.user.isDeactivated {
                Button("Send Message") {
                    session.openDirectMessage(with: profile.user.id)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Button("Copy Username") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("@" + profile.user.username, forType: .string)
            }
        }
    }
}

/// The user's current local time, refreshed every minute, with the offset from this Mac.
struct LocalTimeText: View {
    let zone: TimeZone

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(verbatim: text(at: context.date))
        }
    }

    private func text(at date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        let time = date.formatted(style)
        let delta = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        guard delta != 0 else { return time }
        let hours = Double(delta) / 3_600
        let amount = hours.formatted(.number.precision(.fractionLength(0...2)))
        return delta > 0
            ? String(localized: "\(time) (\(amount) h ahead)")
            : String(localized: "\(time) (\(String(amount.dropFirst())) h behind)")
    }
}

/// Emoji short names in profile/status UI: system emoji as glyphs; unknown (for
/// example custom) names as `:name:` rather than guessed.
enum EmojiText {
    static func display(_ name: String) -> String {
        EmojiCatalog.system.glyph(for: name) ?? ":" + name + ":"
    }
}

/// Presents a profile card from AppKit (the native timeline).
@MainActor
enum ProfilePopover {
    private static weak var current: NSPopover?
    private static weak var owner: SessionViewModel?

    static func close(for session: SessionViewModel) {
        guard owner === session else { return }
        current?.close()
        current?.contentViewController = nil
        current = nil
        owner = nil
    }

    @discardableResult
    static func show(session: SessionViewModel, lookup: ProfileLookup, relativeTo rect: NSRect, of view: NSView) -> NSPopover? {
        guard !session.isDetached, !session.requiresAuthentication else { return nil }
        if let owner { close(for: owner) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let card = UserProfileCard(session: session, lookup: lookup) { [weak popover] in popover?.performClose(nil) }
        let host = NSHostingController(rootView: card)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        current = popover
        owner = session
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        return popover
    }
}
