import AppKit
import SwiftUI
import MatterMacModels
import MatterMacCore

/// "Notification Preferences…" for one channel. Every value here is a server-side
/// setting of the signed-in account (`PUT /channels/{id}/members/{user}/notify_props`)
/// and also applies to the official Mattermost apps; nothing is saved until Save.
struct ChannelNotificationPreferencesView: View {
    let session: SessionViewModel
    let channel: ChannelID
    let onClose: () -> Void

    @State private var loaded: ChannelNotificationPreferences?
    @State private var desktop: ChannelDesktopLevel = .default
    @State private var muted = false
    @State private var ignore: IgnoreChannelMentions = .default
    @State private var error: UserFacingError?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loaded.map { "Notification Preferences for \($0.channelName)" } ?? "Notification Preferences")
                .font(.headline)
                .lineLimit(2)
            if let loaded {
                form(loaded)
            } else if let error {
                Text(UserFacingErrorText.describe(error)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            if loaded != nil, let error {
                Label(UserFacingErrorText.describe(error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("channelNotificationError")
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loaded == nil || isSaving || !hasChanges)
                .accessibilityIdentifier("saveChannelNotifications")
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await load() }
    }

    @ViewBuilder private func form(_ loaded: ChannelNotificationPreferences) -> some View {
        Form {
            Picker("Desktop notifications", selection: $desktop) {
                Text("Default (\(Self.label(loaded.accountDesktop)))").tag(ChannelDesktopLevel.default)
                Text("All new messages").tag(ChannelDesktopLevel.all)
                Text("Mentions and keywords").tag(ChannelDesktopLevel.mention)
                Text("Nothing").tag(ChannelDesktopLevel.nothing)
            }
            .accessibilityIdentifier("channelDesktopLevel")
            Toggle("Mute channel", isOn: $muted)
                .accessibilityIdentifier("channelMuted")
            if !loaded.channelType.isDirectOrGroup {
                Toggle("Ignore @channel, @here and @all", isOn: Binding(
                    get: { ignore == .on || !loaded.accountChannelWideMentions },
                    set: { ignore = $0 ? .on : .off }))
                    .disabled(!loaded.accountChannelWideMentions)
                    .accessibilityIdentifier("channelIgnoreChannelMentions")
                if !loaded.accountChannelWideMentions {
                    Text("Channel-wide mentions are turned off for your account in Settings › Notifications.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.columns)
        Text("""
            Muted channels don’t notify and are marked unread only for mentions. These are server settings for your \
            account: they also apply to the official Mattermost apps.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hasChanges: Bool {
        guard let loaded else { return false }
        return loaded.desktop != desktop || loaded.isMuted != muted || loaded.ignoreChannelMentions != ignore
    }

    static func label(_ level: DesktopNotificationLevel) -> String {
        switch level {
        case .all: String(localized: "All new messages")
        case .mention: String(localized: "Mentions and keywords")
        case .nothing: String(localized: "Nothing")
        }
    }

    private func load() async {
        do throws(UserFacingError) {
            let preferences = try await session.channelNotificationPreferences(channel)
            loaded = preferences
            desktop = preferences.desktop
            muted = preferences.isMuted
            ignore = preferences.ignoreChannelMentions
            error = nil
        } catch {
            self.error = error
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        let desktop = desktop, muted = muted, ignore = ignore
        Task {
            defer { isSaving = false }
            do throws(UserFacingError) {
                try await session.setChannelNotificationPreferences(channel, desktop: desktop, muted: muted,
                                                                    ignoreChannelMentions: ignore)
                onClose()
            } catch {
                self.error = error
            }
        }
    }
}

/// Presents the preferences as a sheet on the key window, so any view (sidebar menu,
/// channel info) can open it without owning presentation state. One at a time.
@MainActor
enum ChannelNotificationSheet {
    private static weak var current: NSWindow?

    @discardableResult
    static func present(session: SessionViewModel, channel: ChannelID, on host: NSWindow? = nil) -> NSWindow? {
        guard current == nil, let host = host ?? NSApp.keyWindow ?? NSApp.mainWindow, host.attachedSheet == nil else {
            return nil
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isRestorable = false
        sheet.isReleasedWhenClosed = false
        let view = ChannelNotificationPreferencesView(session: session, channel: channel) { [weak host, weak sheet] in
            guard let sheet else { return }
            if let host { host.endSheet(sheet) } else { sheet.orderOut(nil) }
        }
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize
        sheet.contentViewController = controller
        current = sheet
        host.beginSheet(sheet)
        return sheet
    }
}
