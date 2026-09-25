import AppKit
public import Observation
public import MatterMacModels
public import MatterMacCore
import MattermostAPI
import MatterMacPlatform

/// Runtime UI state. Verified sign-ins persist separately in Keychain.
@MainActor
@Observable
public final class AppModel {
    public enum Phase {
        case restoring
        case connect
        case login(LoginModel)
        case main
    }

    public private(set) var phase: Phase = .connect
    public let environment: AppEnvironment
    public let registry: SessionRegistry
    let layoutCaches: TimelineLayoutCaches
    public let images: ImagePipeline
    let loginCoordinator: LoginCoordinator
    public private(set) var activeSession: SessionViewModel?
    public private(set) var sessionModels: [ServerSlotID: SessionViewModel] = [:]
    /// Increments when the slot list changes (drives the server switcher).
    public private(set) var slotsRevision = 0
    public var isAddingServer = false
    /// About / Compatibility panel (SPEC §19).
    public var isCompatibilityVisible = false
    /// Help › Keyboard Shortcuts (⌘/).
    public var isShortcutsVisible = false
    public var lastSignOutMessage: String?
    public private(set) var isReauthenticating = false
    private var isSigningOut = false
    private var didRestore = false
    private var isShuttingDown = false
    @ObservationIgnored private var discoveryGeneration: UInt64 = 0
    public private(set) var canRetrySavedSignIn = false
    /// Whether Notification Center alerts for mentions and direct messages are being
    /// delivered now: the saved choice (`LocalSettings.notificationsEnabled`, on by
    /// default) plus macOS authorization. The toggles show the saved choice.
    public private(set) var notificationsEnabled = false
    /// The last macOS answer (`nil` until checked after a sign-in). Settings uses it
    /// to say honestly when macOS blocks MatterMac's notifications.
    private(set) var notificationAuthorization: SystemNotifications.Authorization?
    /// In-app alert sound (see `LocalSettings.playSound`).
    public var notificationSounds: Bool {
        get { environment.settings.playSound }
        set { environment.settings.playSound = newValue }
    }
    @ObservationIgnored var notifications = SystemNotifications()
    @ObservationIgnored private var notificationAuthorizationGeneration: UInt64 = 0
    /// macOS's permission request is shown automatically at most once per launch.
    @ObservationIgnored private var didRequestNotificationAuthorization = false
    @ObservationIgnored private var notificationAuthorizationCheck: Task<Void, Never>?
    /// Sounds and Dock bounces; replaceable in tests.
    @ObservationIgnored var attention: any AttentionRequesting = SystemAttention()

    public init(environment: AppEnvironment) {
        self.environment = environment
        let dependencies = environment.sessionDependencies
        self.registry = SessionRegistry(dependencies: dependencies, factory: environment.serviceFactory)
        self.layoutCaches = TimelineLayoutCaches(budget: environment.budget)
        self.images = ImagePipeline(budget: environment.budget, diagnostics: environment.diagnostics,
                                    cache: environment.contentCache)
        self.loginCoordinator = LoginCoordinator(factory: environment.serviceFactory)
        registry.onChange = { [weak self] in self?.registryChanged() }
        notifications.onOpen = { [weak self] target in self?.open(target) }
    }

    // MARK: - Notifications and badge

    /// The user's choice from Settings or the account menu, saved on this Mac.
    /// Turning it on asks macOS for permission if the user has not answered yet
    /// (macOS returns an earlier answer without prompting again).
    public func setNotificationsEnabled(_ enabled: Bool) async {
        notificationAuthorizationGeneration &+= 1
        let generation = notificationAuthorizationGeneration
        if !isShuttingDown { environment.settings.notificationsEnabled = enabled }
        defer { syncAlertPreviews() }
        guard enabled, !isShuttingDown else {
            notificationsEnabled = false
            notifications.removeDelivered()
            return
        }
        didRequestNotificationAuthorization = true
        let authorization = await notifications.requestAuthorization()
        guard generation == notificationAuthorizationGeneration, !isShuttingDown, !Task.isCancelled else { return }
        notificationAuthorization = authorization
        notificationsEnabled = authorization == .granted
        if authorization == .denied {
            activeSession?.inlineError = String(localized: "Notifications are turned off for MatterMac in System Settings › Notifications.")
        }
    }

    /// Starts delivery when notifications are on (the default). Reads macOS's
    /// decision and asks for permission only if the user has never answered, at most
    /// once per launch. Called after a sign-in and when the app becomes active, never
    /// before an account exists; it does not block the UI or report a refusal as an
    /// error (Settings shows it).
    public func refreshNotificationAuthorization() {
        guard environment.settings.notificationsEnabled, !sessionModels.isEmpty, !isShuttingDown,
              notificationAuthorizationCheck == nil else { return }
        let generation = notificationAuthorizationGeneration
        notificationAuthorizationCheck = Task { [weak self] in
            guard let self else { return }
            defer { notificationAuthorizationCheck = nil }
            var authorization = await notifications.authorizationStatus()
            if authorization == .notDetermined, !didRequestNotificationAuthorization,
               generation == notificationAuthorizationGeneration, !isShuttingDown, !Task.isCancelled {
                didRequestNotificationAuthorization = true
                authorization = await notifications.requestAuthorization()
            }
            // A toggle or quit meanwhile wins over this late answer.
            guard generation == notificationAuthorizationGeneration, !isShuttingDown, !Task.isCancelled,
                  environment.settings.notificationsEnabled else { return }
            notificationAuthorization = authorization
            notificationsEnabled = authorization == .granted
            syncAlertPreviews()
        }
    }

    /// Message text in Notification Center (on by default), saved on this Mac.
    public func setShowMessagePreview(_ enabled: Bool) {
        environment.settings.showMessagePreview = enabled
        syncAlertPreviews()
    }

    /// Core computes preview text only while previews are on and notifications can
    /// show them; otherwise alerts stay content-free.
    func syncAlertPreviews() {
        let enabled = notificationsEnabled && environment.settings.showMessagePreview
        for model in sessionModels.values { model.setAlertPreviews(enabled) }
    }

    /// Notification Center (when on and allowed), the selected in-app sound, and a Dock
    /// bounce for mentions and direct messages while the app is inactive.
    func deliver(_ alert: IncomingMessageAlert) {
        guard !isShuttingDown, sessionModels.values.contains(where: { $0.scope == alert.scope }) else { return }
        let settings = environment.settings
        if notificationsEnabled {
            let content = Self.notificationContent(for: alert, includePreview: settings.showMessagePreview)
            // The in-app sound below replaces Notification Center's so it plays once.
            notifications.post(title: content.title, subtitle: content.subtitle, body: content.body,
                               target: .init(scope: alert.scope, channel: alert.channelID, root: alert.rootID),
                               sound: false)
        }
        if settings.playSound, alert.soundEnabled { attention.playSound(named: settings.soundName) }
        if settings.bounceDockIcon, alert.kind != .channelMessage { attention.requestAttention() }
    }

    /// Who and where; the message text only while previews are on.
    static func notificationContent(for alert: IncomingMessageAlert, includePreview: Bool)
        -> (title: String, subtitle: String?, body: String) {
        let preview = includePreview ? alert.preview : nil
        switch alert.kind {
        case .mention:
            let place = String(localized: "in \(alert.channelName)")
            return (String(localized: "\(alert.senderName) mentioned you"), preview == nil ? nil : place, preview ?? place)
        case .directMessage:
            let isDirect = alert.channelName == alert.senderName
            let fallback = isDirect ? String(localized: "New direct message")
                                    : String(localized: "New message in \(alert.channelName)")
            return (alert.senderName, preview == nil || isDirect ? nil : alert.channelName, preview ?? fallback)
        case .channelMessage:
            return (alert.channelName, preview == nil ? nil : alert.senderName,
                    preview ?? String(localized: "New message from \(alert.senderName)"))
        }
    }

    private func open(_ target: SystemNotifications.Target) {
        guard let model = sessionModels.values.first(where: { $0.scope == target.scope }), !model.requiresAuthentication
        else { return }
        if activeSlotID != model.slot.id { activate(model.slot.id) }
        model.select(channel: target.channel)
        if let root = target.root { model.openThread(root: root) }
    }

    /// Dock badge: total unread mentions across connected sessions.
    func updateDockBadge() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let total = sessionModels.values.reduce(0) { sum, model in
            guard let sidebar = model.sidebar else { return sum }
            let teams = sidebar.teams.reduce(0) { $0 + $1.mentionCount }
            let directs = sidebar.directMessageMentions
            return sum + teams + directs
        }
        // Like the official app: the mention count, or a dot for unread messages only.
        let hasUnread = sessionModels.values.contains { model in
            guard let sidebar = model.sidebar else { return false }
            return sidebar.teams.contains(where: \.hasUnread)
                || sidebar.sections.contains { $0.rows.contains(where: \.isUnread) }
        }
        let label = total > 0 ? (total > 99 ? "99+" : String(total)) : (hasUnread ? "•" : nil)
        if NSApplication.shared.dockTile.badgeLabel != label { NSApplication.shared.dockTile.badgeLabel = label }
    }

    public var slots: [SessionRegistry.Slot] { registry.slots }
    public var activeSlotID: ServerSlotID? { registry.activeSlot }
    public var canAddServer: Bool { registry.canAddSession }

    // MARK: - Connect & login

    /// Validates and probes a server address; moves to the login phase on success.
    func beginLogin(serverText: String) async -> String? {
        guard !isShuttingDown, !Task.isCancelled else { return nil }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        let endpoint: ServerEndpoint
        do {
            endpoint = try ServerURLNormalizer.normalize(serverText, allowInsecureLoopback: environment.allowsInsecureLoopback)
        } catch {
            return ServerURLErrorText.describe(error)
        }
        do {
            let discovery = try await loginCoordinator.discover(endpoint)
            guard generation == discoveryGeneration, !Task.isCancelled, !isShuttingDown else { return nil }
            phase = .login(LoginModel(discovery: discovery, app: self))
            return nil
        } catch {
            guard generation == discoveryGeneration, !Task.isCancelled, !isShuttingDown else { return nil }
            switch error {
            case .notMattermost:
                return String(localized: "No Mattermost server answered at \(endpoint.description). Check the address, including any path such as /chat.")
            case .redirectedElsewhere:
                return String(localized: "The server redirected to a different address. Enter the server’s final address directly; MatterMac never follows redirects to another origin with your credentials.")
            case .unreachable(let failure):
                return UserFacingErrorText.describe(failure)
            }
        }
    }

    func cancelLogin() {
        discoveryGeneration &+= 1
        if case .login(let login) = phase { login.cancel() }
        phase = registry.slots.isEmpty ? .connect : .main
        isAddingServer = false
    }

    func completeLogin(_ result: LoginResult, discovery: DiscoveryResult, remember: Bool = true) async throws(SessionRegistry.AddError) {
        let slot = try registry.add(endpoint: discovery.endpoint, login: result, capabilities: discovery.capabilities)
        let model = SessionViewModel(slot: slot, app: self)
        sessionModels[slot.id] = model
        model.setAlertPreviews(notificationsEnabled && environment.settings.showMessagePreview)
        activeSession = model
        isAddingServer = false
        if remember, let accounts = environment.accounts {
            do {
                try await accounts.save(.init(endpoint: discovery.endpoint, userID: result.user.id, credential: result.credential))
                if model.requiresAuthentication || (sessionModels[slot.id] == nil && !isShuttingDown) {
                    try await accounts.remove(endpoint: discovery.endpoint, userID: result.user.id)
                }
            } catch {
                model.inlineError = "Signed in, but Keychain could not save this account. You may need to sign in again after quitting."
            }
        }
        if !isShuttingDown && remember { phase = .main }
        refreshNotificationAuthorization()
    }

    public func restoreSavedAccounts(retry: Bool = false) async {
        guard (!didRestore || retry), !isShuttingDown, let accounts = environment.accounts else { return }
        if case .restoring = phase { return }
        didRestore = true
        canRetrySavedSignIn = false
        lastSignOutMessage = nil
        phase = .restoring
        do {
            for account in try await accounts.load() {
                guard !isShuttingDown, !Task.isCancelled else { break }
                if slots.contains(where: { $0.endpoint == account.endpoint && $0.user.id == account.userID }) { continue }
                do {
                    let discovery = try await loginCoordinator.discover(account.endpoint)
                    let login = try await loginCoordinator.restore(account.endpoint, credential: account.credential, expectedUser: account.userID)
                    guard !isShuttingDown, !Task.isCancelled else { break }
                    try await completeLogin(login, discovery: discovery, remember: false)
                } catch LoginCoordinator.RestoreError.invalidCredential {
                    try await accounts.remove(endpoint: account.endpoint, userID: account.userID)
                    await environment.contentCache?.removeAll(for: CacheAccount(endpoint: account.endpoint, user: account.userID))
                    lastSignOutMessage = "A saved sign-in has expired or was revoked. Sign in again."
                } catch LoginCoordinator.RestoreError.accountChanged {
                    try await accounts.remove(endpoint: account.endpoint, userID: account.userID)
                    await environment.contentCache?.removeAll(for: CacheAccount(endpoint: account.endpoint, user: account.userID))
                    lastSignOutMessage = "A saved sign-in returned a different account and was removed. Sign in again."
                } catch {
                    canRetrySavedSignIn = true
                    lastSignOutMessage = "A saved account could not be connected. Its sign-in remains in Keychain; retry when the server is available."
                }
            }
        } catch {
            canRetrySavedSignIn = true
            lastSignOutMessage = "Saved sign-ins could not be read or updated in Keychain. Unlock your login Keychain and retry."
        }
        guard !isShuttingDown else { return }
        phase = slots.isEmpty ? .connect : .main
        if let message = lastSignOutMessage { activeSession?.inlineError = message }
    }

    func forgetSavedAccount(_ model: SessionViewModel) async -> Bool {
        do {
            try await environment.accounts?.remove(endpoint: model.slot.endpoint, userID: model.scope.user)
            return true
        } catch {
            model.inlineError = "The saved sign-in could not be removed from Keychain. Unlock your login Keychain and try signing out again."
            return false
        }
    }

    public func showAddServer() {
        guard registry.canAddSession else { return }
        isAddingServer = true
        phase = .connect
    }

    public func activate(_ slot: ServerSlotID) {
        activeSession?.saveDrafts()
        activeSession?.updateAppState(isActive: false, isWindowVisible: false)
        registry.activate(slot)
    }

    private func registryChanged() {
        slotsRevision &+= 1
        if let active = registry.activeSlot {
            // Switching servers switches the visible identity immediately; the old
            // model's late snapshots are ignored because they carry another scope.
            activeSession = sessionModels[active]
        } else {
            activeSession = nil
        }
        for slot in sessionModels.keys where !registry.slots.contains(where: { $0.id == slot }) {
            sessionModels[slot]?.detach()
            sessionModels[slot] = nil
        }
        if registry.slots.isEmpty, case .main = phase { phase = .connect }
        updateDockBadge()
    }

    // MARK: - Sign out

    /// Signs out of one server after confirming unsent work (SPEC §7 logout).
    @discardableResult
    public func signOut(_ slot: ServerSlotID) async -> Bool {
        guard !isSigningOut, let model = sessionModels[slot] else { return false }
        isSigningOut = true
        defer { isSigningOut = false }
        let unsentCount = await model.unsentWorkCount()
        if unsentCount > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Sign out and discard unsent messages?")
            alert.informativeText = String(localized: "\(unsentCount) draft(s) or message(s) have not been confirmed by the server. MatterMac keeps them only in memory; signing out discards them and any selected attachments. Use Review Unsent Work before signing out to copy text or export pasted images.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Sign Out and Discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        guard await forgetSavedAccount(model) else { return false }
        notifications.removeDelivered(scope: model.scope)
        model.prepareForSignOut()
        environment.drafts.discardAll(for: model.scope)
        layoutCaches.purge(scope: model.scope)
        await images.purge(scope: model.scope)
        await environment.contentCache?.removeAll(for: model.cacheAccount)
        let outcome = await registry.remove(slot, revokeServerSession: true)
        lastSignOutMessage = outcome.map(SignOutText.describe)
        updateDockBadge()
        return true
    }

    func reauthenticate(_ slot: ServerSlotID) async {
        guard !isReauthenticating, let model = sessionModels[slot], model.requiresAuthentication else { return }
        isReauthenticating = true
        defer { isReauthenticating = false }
        let endpoint = model.slot.endpoint
        guard await signOut(slot) else { return }
        isAddingServer = !registry.slots.isEmpty
        if let error = await beginLogin(serverText: endpoint.description) {
            lastSignOutMessage = error
            phase = .connect
        }
    }

    /// Close all sessions. App termination keeps saved tokens valid on the server.
    public func shutdownAll(preservingSavedSignIns: Bool = false) async {
        isShuttingDown = true
        notificationAuthorizationGeneration &+= 1
        notificationAuthorizationCheck?.cancel()
        // Delivery stops; the saved choice stays for the next launch.
        notificationsEnabled = false
        notifications.removeDelivered()
        if case .login(let login) = phase { login.cancel() }
        for model in sessionModels.values {
            // Quitting keeps the account's cache current for the next launch.
            if preservingSavedSignIns, !model.requiresAuthentication {
                await model.slot.session.persistCache()
            } else {
                await environment.contentCache?.removeAll(for: model.cacheAccount)
            }
            model.prepareForSignOut()
            environment.drafts.discardAll(for: model.scope)
            layoutCaches.purge(scope: model.scope)
            await images.purge(scope: model.scope)
        }
        await registry.removeAll(revokeServerSessions: !preservingSavedSignIns)
    }
}

enum SignOutText {
    static func describe(_ outcome: SignOutOutcome) -> String {
        switch outcome {
        case .serverSessionRevoked:
            String(localized: "Signed out. The server confirmed the session was ended, and local session data was cleared.")
        case .serverLogoutUnconfirmed:
            String(localized: "Local session data was cleared. Server logout was not confirmed; the session follows your server’s expiry policy.")
        case .personalAccessTokenDiscardedLocally:
            String(localized: "The personal access token was removed from this Mac, including Keychain. It remains valid on the server until you revoke it in Mattermost (Profile › Security › Personal Access Tokens).")
        }
    }
}

/// Login form state for one discovered server.
@MainActor
@Observable
public final class LoginModel {
    public enum Method: Hashable { case password, personalAccessToken, browserSSO }
    public let discovery: DiscoveryResult
    weak var app: AppModel?
    var method: Method = .password
    var loginID = ""
    var password = ""
    var mfaCode = ""
    var token = ""
    var ssoProvider: SSOProvider = .openID
    @ObservationIgnored private var browser: BrowserAuthentication?
    @ObservationIgnored private var submission: Task<Void, Never>?
    var needsMFA = false
    var isWorking = false
    var errorMessage: String?

    init(discovery: DiscoveryResult, app: AppModel) {
        self.discovery = discovery
        self.app = app
        if let provider = discovery.browserSSOProviders.first { ssoProvider = provider }
        if !discovery.capabilities.login.passwordLoginAvailable {
            method = discovery.browserSSOProviders.isEmpty ? .personalAccessToken : .browserSSO
        }
    }

    var loginIDPrompt: String {
        let login = discovery.capabilities.login
        switch (login.email, login.username, login.ldap) {
        case (true, true, _): return String(localized: "Email or username")
        case (true, false, false): return String(localized: "Email")
        case (false, true, false): return String(localized: "Username")
        case (_, _, true):
            return login.ldapFieldName.isEmpty ? String(localized: "Username or AD/LDAP username") : login.ldapFieldName
        default: return String(localized: "Username")
        }
    }

    func cancel() {
        submission?.cancel()
        browser?.cancel()
        password = ""; token = ""; mfaCode = ""
    }

    func submit() async {
        guard let app, !isWorking, !Task.isCancelled else { return }
        isWorking = true
        errorMessage = nil
        let task = Task { await performSubmit(app: app) }
        submission = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        submission = nil
        isWorking = false
    }

    private func performSubmit(app: AppModel) async {
        defer { browser = nil }
        do {
            let result: LoginResult
            switch method {
            case .password:
                result = try await app.loginCoordinator.login(discovery.endpoint, loginID: loginID, password: password,
                                                             mfaCode: needsMFA ? mfaCode : nil)
            case .personalAccessToken:
                result = try await app.loginCoordinator.authenticate(discovery.endpoint, personalAccessToken: token)
            case .browserSSO:
                guard let anchor = NSApp.keyWindow ?? NSApp.mainWindow else { throw BrowserLoginError.browserUnavailable }
                let attempt = try BrowserLoginAttempt(discovery: discovery, provider: ssoProvider,
                                                      budget: app.environment.budget)
                let browser = BrowserAuthentication(budget: app.environment.budget)
                self.browser = browser
                let callback = try await browser.authenticate(attempt, anchor: anchor)
                result = try await app.loginCoordinator.completeBrowserLogin(attempt, callback: callback)
            }
            guard !Task.isCancelled, case .login(let current) = app.phase, current === self else {
                await app.loginCoordinator.discardNewLogin(result, endpoint: discovery.endpoint)
                return
            }
            // Minimize password lifetime in this object (not secure erasure).
            password = ""
            token = ""
            mfaCode = ""
            do { try await app.completeLogin(result, discovery: discovery) }
            catch {
                await app.loginCoordinator.discardNewLogin(result, endpoint: discovery.endpoint)
                throw error
            }
        } catch let error as BrowserLoginError {
            errorMessage = Self.browserErrorText(error)
        } catch let error as AuthenticationError {
            handle(error)
        } catch let error as SessionRegistry.AddError {
            switch error {
            case .limitReached(let limit):
                errorMessage = String(localized: "MatterMac supports up to \(limit) connected servers at once. Sign out of one first.")
            case .alreadyConnected:
                errorMessage = String(localized: "This account is already connected.")
            }
        } catch {
            errorMessage = UserFacingErrorText.describe(.unknown)
        }
    }

    static func browserErrorText(_ error: BrowserLoginError) -> String? {
        switch error {
        case .cancelled: nil
        case .unsupportedProvider: "This sign-in provider is not enabled on this server."
        case .invalidCallback: "The browser response did not match this sign-in attempt. Start sign-in again."
        case .timedOut: "Browser sign-in timed out. Start sign-in again."
        case .browserUnavailable: "The system could not open browser sign-in. Check your default browser and try again."
        case .randomUnavailable: "Secure browser sign-in could not be started. Try again."
        case .requestFailed(let error): UserFacingErrorText.describe(error)
        }
    }

    private func handle(_ error: AuthenticationError) {
        switch error {
        case .login(let failure):
            switch failure {
            case .mfaRequired:
                if needsMFA {
                    errorMessage = String(localized: "Enter the 6-digit code from your authenticator app.")
                } else {
                    needsMFA = true
                    errorMessage = nil
                }
            case .invalidMFACode:
                mfaCode = ""
                errorMessage = String(localized: "That code was not accepted. Codes can be used only once; wait for the next code and try again.")
            case .invalidCredentials:
                errorMessage = String(localized: "The sign-in details were not accepted. Check them and try again.")
            case .accountLocked:
                errorMessage = String(localized: "Too many failed attempts. The account is temporarily locked; contact your administrator if this persists.")
            case .accountDeactivated:
                errorMessage = String(localized: "This account is deactivated.")
            case .loginMethodDisabled, .ssoAccountRequiresBrowser:
                errorMessage = String(localized: "This account can’t sign in with a password here. For single sign-on, use the Browser SSO option if this server advertises it.")
            case .emailNotVerified:
                errorMessage = String(localized: "Verify your email address first (see the message from your server), then sign in.")
            case .api(let api):
                errorMessage = UserFacingErrorText.describe(ServerSession.userFacing(api))
            }
        case .invalidToken:
            errorMessage = String(localized: "That doesn’t look like a Mattermost access token.")
        case .personalAccessTokensDisabledOrInvalid:
            errorMessage = String(localized: "The server rejected this token. It may be invalid or revoked, or personal access tokens may be disabled by your administrator.")
        case .failed(let failure):
            errorMessage = UserFacingErrorText.describe(failure)
        }
    }
}
