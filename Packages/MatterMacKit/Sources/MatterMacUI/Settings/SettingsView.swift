public import SwiftUI
import MatterMacModels
import MatterMacCore
import MatterMacPlatform

/// The Settings window (⌘,). Local settings ("On This Mac") live in memory and reset
/// when MatterMac quits; server settings belong to the active account, are saved on
/// the server as an explicit change, and also apply to the official Mattermost apps.
/// Each section says which kind it is (SPEC §4 "Native quality", §19).
public struct MatterMacSettingsView: View {
    let environment: AppEnvironment
    /// Explicit in-memory selection: without it SwiftUI saves the selected Settings
    /// tab to UserDefaults (`com_apple_SwiftUI_Settings_selectedTabIndex`, observed).
    @State private var tab: Tab = .general

    enum Tab: Hashable { case general, notifications, appearance, accounts, profile }

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        TabView(selection: $tab) {
            Group {
                if let session = environment.appModel?.activeSession {
                    ProfileSettingsView(session: session).id(session.slot.id)
                } else { Text("Sign in to edit your profile.") }
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(Tab.profile)
            GeneralSettingsTab(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            NotificationSettingsTab(environment: environment)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(Tab.notifications)
            AppearanceSettingsTab(settings: environment.settings)
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
                .tag(Tab.appearance)
            AccountsSettingsTab(environment: environment)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(Tab.accounts)
        }
        .frame(width: 540, height: 560)
    }
}

// MARK: - Shared pieces

/// Header for settings kept only in memory on this Mac.
struct LocalSectionHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("On This Mac", systemImage: "laptopcomputer")
            Text("Kept in memory only; reset when MatterMac quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("localSettingsHeader")
    }
}

/// Header for server-side settings of the active account.
struct ServerSectionHeader: View {
    let session: SessionViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Server Settings", systemImage: "server.rack")
            if let session {
                Text("Saved on \(session.slot.endpoint.description) for @\(session.slot.user.username); also used by the official Mattermost apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serverSettingsHeader")
    }
}

/// The session whose server settings are shown, or a sign-in hint.
struct ActiveSessionContent<Content: View>: View {
    let environment: AppEnvironment
    @ViewBuilder let content: (SessionViewModel, AccountSettingsSnapshot) -> Content

    var body: some View {
        if let session = environment.appModel?.activeSession, !session.requiresAuthentication, !session.isDetached {
            if let settings = session.accountSettings {
                content(session, settings)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading server settings…").foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Sign in to change server settings.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settingsSignInHint")
        }
    }
}

/// Runs one explicit server change and keeps its error next to the control.
@MainActor
@Observable
final class ServerChangeState {
    var isSaving = false
    var error: String?
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel() }

    /// Untyped `throws`: typed-throws closure types need the macOS 15 runtime.
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        task = Task {
            defer { isSaving = false; task = nil }
            do {
                try await operation()
            } catch {
                let failure = error as? UserFacingError ?? .unknown
                if failure != .cancelled { self.error = UserFacingErrorText.describe(failure) }
            }
        }
    }
}

struct ServerChangeStatus: View {
    let state: ServerChangeState

    var body: some View {
        if state.isSaving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving to the server…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let error = state.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("serverSettingError")
        }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    let environment: AppEnvironment
    @State private var change = ServerChangeState()

    var body: some View {
        Form {
            Section {
                Picker("Send messages with", selection: Binding(get: { environment.settings.sendBehavior },
                                                                 set: { environment.settings.sendBehavior = $0 })) {
                    Text("Return").tag(AppEnvironment.SendBehaviorSetting.returnSends)
                    Text("⌘Return").tag(AppEnvironment.SendBehaviorSetting.commandReturnSends)
                }
                .accessibilityIdentifier("sendBehaviorPicker")
                Text(environment.settings.sendBehavior == .returnSends
                     ? "Shift-Return inserts a new line."
                     : "Return inserts a new line; ⌘Return sends.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { LocalSectionHeader() }

            Section {
                ActiveSessionContent(environment: environment) { session, settings in
                    displaySettings(session, settings.display)
                }
                .disabled(change.isSaving)
                ServerChangeStatus(state: change)
            } header: { ServerSectionHeader(session: environment.appModel?.activeSession) }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func displaySettings(_ session: SessionViewModel, _ display: AccountSettingsSnapshot.Display) -> some View {
        Picker("Clock display", selection: Binding<Bool?>(
            get: { display.militaryTime },
            set: { value in
                guard let value else { return }
                change.run { try await session.setMilitaryTime(value) }
            })) {
            Text("12-hour (1:00 PM)").tag(Bool?.some(false))
            Text("24-hour (13:00)").tag(Bool?.some(true))
        }
        .accessibilityIdentifier("clockDisplayPicker")
        if display.militaryTime == nil {
            Text("Not set on the server: message times follow your Mac’s format.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Teammate name display", selection: Binding(
            get: { display.nameFormat },
            set: { value in change.run { try await session.setNameFormat(value) } })) {
            Text("Username").tag(NameFormat.username)
            Text("Nickname, else full name").tag(NameFormat.nicknameFullName)
            Text("Full name").tag(NameFormat.fullName)
        }
        .disabled(display.isNameFormatLocked)
        .accessibilityIdentifier("nameFormatPicker")
        if display.isNameFormatLocked {
            Text("Your administrator set how names are shown.").font(.caption).foregroundStyle(.secondary)
        }
        if display.canChangeCollapsedThreads {
            Toggle("Collapsed reply threads", isOn: Binding(
                get: { display.collapsedThreadsActive },
                set: { value in change.run { try await session.setCollapsedThreads(value) } }))
                .accessibilityIdentifier("collapsedThreadsToggle")
            Text("Replies stay in their thread instead of the channel. Open conversations reload when this changes.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            LabeledContent("Collapsed reply threads") {
                Text(collapsedThreadsLabel(display.collapsedThreadsMode))
            }
        }
    }

    private func collapsedThreadsLabel(_ mode: CollapsedThreadsMode) -> String {
        switch mode {
        case .alwaysOn: String(localized: "Always on (set by the server)")
        case .disabled: String(localized: "Not available on this server")
        default: String(localized: "Unknown")
        }
    }
}

// MARK: - Notifications

struct NotificationSettingsTab: View {
    let environment: AppEnvironment
    @State private var change = ServerChangeState()
    @State private var keywordText = ""
    @State private var keywordsEdited = false

    var body: some View {
        Form {
            localSection
            Section {
                ActiveSessionContent(environment: environment) { session, settings in
                    serverSettings(session, settings)
                }
                .disabled(change.isSaving)
                ServerChangeStatus(state: change)
            } header: { ServerSectionHeader(session: environment.appModel?.activeSession) }
        }
        .formStyle(.grouped)
        .onChange(of: environment.appModel?.activeSession?.accountSettings?.notifications) { keywordsEdited = false }
    }

    @ViewBuilder private var localSection: some View {
        let settings = environment.settings
        let app = environment.appModel
        Section {
            Toggle("Show notifications in Notification Center", isOn: Binding(
                get: { app?.notificationsEnabled ?? false },
                set: { value in Task { await app?.setNotificationsEnabled(value) } }))
                .disabled(app == nil)
                .accessibilityIdentifier("notificationCenterToggle")
            Text("macOS may keep delivered notifications in Notification Center. They name the sender and conversation, not the message, unless you turn on previews.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show message preview", isOn: Binding(
                get: { settings.showMessagePreview },
                set: { app?.setShowMessagePreview($0) }))
                .disabled(app?.notificationsEnabled != true)
                .accessibilityIdentifier("messagePreviewToggle")
            Text("Adds up to \(IncomingMessageAlert.previewCharacters) characters of message text to notifications. Off by default.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Play sound", isOn: Binding(get: { settings.playSound }, set: { settings.playSound = $0 }))
                .accessibilityIdentifier("playSoundToggle")
            HStack {
                Picker("Sound", selection: Binding(get: { settings.soundName }, set: { settings.soundName = $0 })) {
                    ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("soundPicker")
                Button("Play") { app?.attention.playSound(named: settings.soundName) }
                    .help("Plays the selected sound")
            }
            .disabled(!settings.playSound)
            Toggle("Bounce Dock icon for mentions and direct messages", isOn: Binding(
                get: { settings.bounceDockIcon }, set: { settings.bounceDockIcon = $0 }))
                .accessibilityIdentifier("bounceDockToggle")
            Text("Sounds and Dock bounces happen only while MatterMac is running and are silenced when your status is Do Not Disturb.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { LocalSectionHeader() }
    }

    @ViewBuilder
    private func serverSettings(_ session: SessionViewModel, _ settings: AccountSettingsSnapshot) -> some View {
        if let props = settings.notifications, settings.canEditNotifications {
            Picker("Desktop notifications", selection: Binding(
                get: { props.desktop },
                set: { value in update(session) { $0.desktop = value } })) {
                Text("All new messages").tag(DesktopNotificationLevel.all)
                Text("Mentions, direct messages and keywords").tag(DesktopNotificationLevel.mention)
                Text("Nothing").tag(DesktopNotificationLevel.nothing)
            }
            .accessibilityIdentifier("accountDesktopLevel")
            Toggle("Notification sound", isOn: Binding(
                get: { props.desktopSound },
                set: { value in update(session) { $0.desktopSound = value } }))
                .accessibilityIdentifier("accountDesktopSound")
            Toggle(settings.firstName.isEmpty ? "Your first name triggers mentions"
                                              : "Your first name “\(settings.firstName)” triggers mentions",
                   isOn: Binding(get: { props.firstNameMentions },
                                 set: { value in update(session) { $0.firstNameMentions = value } }))
                .disabled(settings.firstName.isEmpty && !props.firstNameMentions)
                .accessibilityIdentifier("accountFirstNameMentions")
            Toggle("@channel, @all and @here trigger mentions", isOn: Binding(
                get: { props.channelWideMentions },
                set: { value in update(session) { $0.channelWideMentions = value } }))
                .accessibilityIdentifier("accountChannelMentions")
            LabeledContent("Other mention keywords") {
                HStack {
                    TextField("keyword, another", text: Binding(
                        get: { keywordsEdited ? keywordText : props.mentionKeys.joined(separator: ", ") },
                        set: { keywordText = $0; keywordsEdited = true }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveKeywords(session) }
                        .accessibilityIdentifier("accountMentionKeys")
                    Button("Save") { saveKeywords(session) }
                        .disabled(!keywordsEdited)
                }
            }
            Text("Separate keywords with commas. @\(settings.username) always mentions you. Matching ignores case.")
                .font(.caption).foregroundStyle(.secondary)
        } else if settings.notifications == nil {
            Text("The server did not report notification settings for this account.")
                .foregroundStyle(.secondary)
        } else {
            Text("These notification settings are too large to edit here. Change them in the Mattermost web app.")
                .foregroundStyle(.secondary)
        }
    }

    private func update(_ session: SessionViewModel, _ body: @escaping @Sendable (inout UserNotifyProps) -> Void) {
        change.run { try await session.updateAccountNotifications(body) }
    }

    private func saveKeywords(_ session: SessionViewModel) {
        guard keywordsEdited else { return }
        let keys = keywordText.split(separator: ",").map { String($0) }
        change.run {
            try await session.updateAccountNotifications { $0.mentionKeys = keys }
            keywordsEdited = false
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsTab: View {
    @Bindable var settings: LocalSettings

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("System").tag(LocalSettings.Appearance.system)
                    Text("Light").tag(LocalSettings.Appearance.light)
                    Text("Dark").tag(LocalSettings.Appearance.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearancePicker")
                Picker("Message text size", selection: $settings.textSize) {
                    Text("Small").tag(LocalSettings.TextSize.small)
                    Text("Standard").tag(LocalSettings.TextSize.standard)
                    Text("Large").tag(LocalSettings.TextSize.large)
                    Text("Extra Large").tag(LocalSettings.TextSize.extraLarge)
                }
                .accessibilityIdentifier("textSizePicker")
                Text("Applies to message text in conversations and threads, on top of the system text size.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Message density") { Text("Standard") }
                Text("A compact message layout is not available yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { LocalSectionHeader() }
            Section {
                Text("Your Mattermost theme is not applied; MatterMac follows the macOS appearance. It never saves its appearance to the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Accounts

struct AccountsSettingsTab: View {
    let environment: AppEnvironment

    var body: some View {
        Form {
            Section("Signed-In Servers") {
                if let app = environment.appModel, !app.slots.isEmpty {
                    ForEach(app.slots) { slot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: slot.siteName.isEmpty ? slot.endpoint.description : slot.siteName)
                                    .font(.body.weight(.medium))
                                Text(verbatim: "@\(slot.user.username) · \(slot.endpoint.description)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if slot.id == app.activeSlotID {
                                Text("Active").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Sign Out…") { Task { await app.signOut(slot.id) } }
                                .accessibilityIdentifier("signOut-\(slot.id.rawValue)")
                        }
                    }
                } else {
                    Text("No servers are signed in.").foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Text("""
                    MatterMac saves each verified sign-in (an access token, never your password) in your macOS \
                    Keychain so it can reconnect after you quit. Signing out removes it from Keychain. Messages, \
                    drafts, images and the settings marked “On This Mac” stay in memory and are discarded when \
                    MatterMac quits. Server settings are stored by your Mattermost server.
                    """)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("accountsPrivacyNote")
            }
        }
        .formStyle(.grouped)
    }
}
