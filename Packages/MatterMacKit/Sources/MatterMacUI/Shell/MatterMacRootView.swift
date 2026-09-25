public import SwiftUI
import AppKit
import MatterMacModels
import MatterMacCore

/// Root content of the main window. The app target embeds this in its single
/// `Window` scene; all navigation state below it lives in memory only.
public struct MatterMacRootView: View {
    @State private var model: AppModel
    /// The address typed on the connect screen, kept while moving between the
    /// connect and sign-in steps of this window (memory only, cleared once signed in).
    @State private var serverDraft = ""
    @State private var connectStep: OnboardingStep = .server
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(environment: AppEnvironment) {
        let model = environment.appModel ?? AppModel(environment: environment)
        environment.appModel = model
        _model = State(initialValue: model)
    }

    public var body: some View {
        ZStack {
            if screen != .main {
                OnboardingBackdrop(stage: backdropStage)
                    .transition(.opacity)
            }
            Group {
                switch model.phase {
                case .restoring:
                    RestoringSignInsView()
                        .transition(Self.cardTransition)
                case .connect:
                    ConnectView(model: model, serverText: $serverDraft, step: $connectStep)
                        .transition(Self.cardTransition)
                case .login(let login):
                    LoginView(login: login, app: model)
                        .transition(Self.cardTransition)
                case .main:
                    if let session = model.activeSession {
                        MainWindowView(app: model, session: session)
                            .id(session.scope)
                            .transition(.opacity)
                    } else {
                        ConnectView(model: model, serverText: $serverDraft, step: $connectStep)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: screen)
        .environment(\.matterMacTheme, model.environment.settings.theme)
        .environment(\.onboardingBackdropPalette, OnboardingBackdropPalette(theme: model.environment.settings.theme))
        .themeAccentTint()
        .frame(minWidth: 760, minHeight: 500)
        .task { await model.restoreSavedAccounts() }
        .onChange(of: screen) { _, screen in
            if screen == .main { serverDraft = "" }
            if screen != .connect { connectStep = .server }
        }
        .sheet(isPresented: Binding(get: { model.isCompatibilityVisible },
                                    set: { model.isCompatibilityVisible = $0 })) {
            CompatibilityView(app: model)
        }
        .sheet(isPresented: Binding(get: { model.isShortcutsVisible }, set: { model.isShortcutsVisible = $0 })) {
            KeyboardShortcutsView()
        }
    }

    private static let cardTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.98))

    /// Which screen is visible, for transitions (the login model's identity counts).
    private enum Screen: Hashable {
        case restoring, connect, login(ObjectIdentifier), main
    }

    private var screen: Screen {
        switch model.phase {
        case .restoring: .restoring
        case .connect: .connect
        case .login(let login): .login(ObjectIdentifier(login))
        case .main: model.activeSession == nil ? .connect : .main
        }
    }

    private var backdropStage: Int {
        switch screen {
        case .restoring: 0
        case .connect: connectStep.rawValue
        case .login, .main: 2
        }
    }
}

/// Launch state while saved sign-ins are read from Keychain and verified.
struct RestoringSignInsView: View {
    var body: some View {
        OnboardingCardLayout(width: 300) {
            VStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                    .accessibilityHidden(true)
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel(Text("Restoring saved sign-ins…"))
                Text("Restoring saved sign-ins…")
                    .font(.headline)
                    .accessibilityHidden(true)
                Text("Checking the accounts saved in Keychain with their servers.")
                    .font(.callout)
                    .foregroundStyle(OnboardingStyle.supporting)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Server connection screen; saved accounts are restored separately at launch.
/// Two steps: Continue shows the normalized final origin, Connect probes it.
struct ConnectView: View {
    let model: AppModel
    @Binding var serverText: String
    @Binding var step: OnboardingStep
    @State private var validation: ValidationState
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    enum ValidationState: Equatable {
        case idle
        case invalid(String)
        case normalized(String)
    }

    init(model: AppModel, serverText: Binding<String>, step: Binding<OnboardingStep> = .constant(.server),
         validation: ValidationState = .idle) {
        self.model = model
        _serverText = serverText
        _step = step
        _validation = State(initialValue: validation)
    }

    var body: some View {
        OnboardingCardLayout { card }
            .onDisappear(perform: cancelProbe)
            .onChange(of: currentStep, initial: true) { _, current in step = current }
    }

    private var currentStep: OnboardingStep {
        if isProbing { return .confirm }
        if case .normalized = validation { return .confirm }
        return .server
    }

    private var isConfirming: Bool {
        if case .normalized = validation { true } else { false }
    }

    private var card: some View {
        VStack(spacing: 0) {
            OnboardingStepIndicator(current: currentStep)
                .padding(.bottom, 20)
            header
            if let message = model.lastSignOutMessage {
                OnboardingNotice(
                    tone: model.canRetrySavedSignIn ? .warning : .info,
                    systemImage: model.canRetrySavedSignIn ? "exclamationmark.triangle.fill" : "info.circle.fill",
                    message: message,
                    actionTitle: model.canRetrySavedSignIn ? String(localized: "Retry Saved Sign-In") : nil,
                    action: retrySavedSignIn,
                    actionDisabled: isProbing)
                    .padding(.top, 20)
            } else if model.canRetrySavedSignIn {
                Button("Retry Saved Sign-In", action: retrySavedSignIn)
                    .glassButtonStyle()
                    .disabled(isProbing)
                    .padding(.top, 20)
            }
            addressField
                .padding(.top, 26)
            buttons
                .padding(.top, 22)
            disclosure
                .padding(.top, 24)
        }
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private var header: some View {
        if model.isAddingServer {
            OnboardingHeader(title: String(localized: "Add a Server"),
                             subtitle: String(localized: "Connect to another Mattermost server. You stay signed in to the others."))
            if !model.slots.isEmpty {
                Text("Signed in to \(model.slots.map { $0.siteName.isEmpty ? $0.endpoint.host : $0.siteName }.formatted(.list(type: .and)))")
                    .font(.callout)
                    .foregroundStyle(OnboardingStyle.supporting)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        } else {
            // UI tests look for the exact "MatterMac" title.
            OnboardingHeader(title: "MatterMac",
                             subtitle: String(localized: "An independent, native client for existing Mattermost servers."))
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnboardingField(systemImage: "server.rack", isFocused: fieldFocused, isInvalid: isInvalid,
                            focus: { fieldFocused = true }) {
                // Verbatim: a localized key would render the URL as a link.
                TextField(text: $serverText, prompt: Text(verbatim: "https://chat.example.org")) {
                    Text("Server URL")
                }
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onChange(of: serverText) { validation = .idle }
                    .accessibilityLabel(Text("Server URL"))
                    .disabled(isProbing)
            }
            switch validation {
            case .idle:
                Text("Enter the address you use for Mattermost in a browser, including any path such as /chat.")
                    .font(.callout)
                    .foregroundStyle(OnboardingStyle.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            case .invalid(let message):
                OnboardingNotice(tone: .error, systemImage: "exclamationmark.triangle.fill", message: message,
                                 identifier: "serverError")
            case .normalized(let origin):
                let secure = origin.hasPrefix("https://")
                OnboardingNotice(tone: secure ? .info : .warning,
                                 systemImage: secure ? "lock.fill" : "lock.open.fill",
                                 message: String(localized: "Will connect to \(origin)"),
                                 identifier: "normalizedOrigin")
                Text(isProbing ? "Checking that a Mattermost server answers at this address…"
                               : "Check the address, then choose Connect. No sign-in details are sent yet.")
                    .font(.callout)
                    .foregroundStyle(OnboardingStyle.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var isInvalid: Bool {
        if case .invalid = validation { true } else { false }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if model.isAddingServer {
                Button("Cancel") { cancelProbe(); model.cancelLogin() }
                    .keyboardShortcut(.cancelAction)
                    .onboardingSecondaryButton()
            }
            Button(action: submit) {
                OnboardingPrimaryButtonLabel(
                    title: isConfirming ? String(localized: "Connect") : String(localized: "Continue"),
                    progressTitle: isProbing ? String(localized: "Connecting…") : nil)
            }
            .keyboardShortcut(.defaultAction)
            .onboardingPrimaryButton()
            .disabled(serverText.trimmingCharacters(in: .whitespaces).isEmpty || isProbing)
        }
    }

    private var disclosure: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.body)
                .foregroundStyle(OnboardingStyle.supporting)
                .accessibilityHidden(true)
            Text("""
                MatterMac saves account sign-ins in macOS Keychain and keeps an encrypted cache of recent \
                messages, profiles and images on this Mac so it opens quickly. Signing out removes both. \
                Settings are saved on this Mac. Drafts stay in memory only. Your server stores sent messages.
                """)
                .font(.footnote)
                .foregroundStyle(OnboardingStyle.supporting)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sessionDisclosure")
        }
        .padding(.top, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
    }

    private func retrySavedSignIn() {
        Task { await model.restoreSavedAccounts(retry: true) }
    }

    private func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
        isProbing = false
    }

    private func submit() {
        guard !isProbing else { return }
        let confirmed: Bool
        if case .normalized = validation { confirmed = true } else { confirmed = false }
        // Show the final origin before any credential can be sent (SPEC §4).
        do {
            let endpoint = try ServerURLNormalizer.normalize(
                serverText, allowInsecureLoopback: model.environment.allowsInsecureLoopback)
            validation = .normalized(endpoint.description)
        } catch {
            validation = .invalid(ServerURLErrorText.describe(error))
            return
        }
        guard confirmed else { return }
        isProbing = true
        probeTask = Task {
            let failure = await model.beginLogin(serverText: serverText)
            guard !Task.isCancelled else { return }
            probeTask = nil
            isProbing = false
            if let failure { validation = .invalid(failure) }
        }
    }
}

enum ServerURLErrorText {
    static func describe(_ error: ServerURLError) -> String {
        switch error {
        case .empty: String(localized: "Enter your Mattermost server address.")
        case .malformed: String(localized: "That doesn’t look like a valid server address.")
        case .unsupportedScheme: String(localized: "Only https:// server addresses are supported.")
        case .embeddedCredentials: String(localized: "Remove the username or password from the address.")
        case .missingHost: String(localized: "The address is missing a host name.")
        case .queryOrFragmentNotAllowed: String(localized: "Remove the ? or # part from the address.")
        case .insecureTransportNotAllowed:
            String(localized: "Plain http:// is not allowed. Use https:// (http is only available for local development servers with the development setting enabled).")
        case .invalidPort: String(localized: "The port number is not valid.")
        }
    }
}

/// Sign-in for one discovered server. Shows the final origin and which methods
/// advertised by this server; browser sign-in uses the desktop token handoff.
struct LoginView: View {
    @Bindable var login: LoginModel
    let app: AppModel
    @FocusState private var focused: Field?

    enum Field { case loginID, password, mfa, token }

    var body: some View {
        OnboardingCardLayout { form }
    }

    private var isSecure: Bool { login.discovery.endpoint.scheme == .https }

    private var siteName: String {
        login.discovery.capabilities.siteName.isEmpty ? "Mattermost" : login.discovery.capabilities.siteName
    }

    private var form: some View {
        VStack(spacing: 0) {
            OnboardingStepIndicator(current: .signIn)
                .padding(.bottom, 20)
            OnboardingHeader(title: String(localized: "Sign in to \(siteName)"), subtitle: nil, iconSize: 56)
            OnboardingServerChip(origin: login.discovery.endpoint.description, isSecure: isSecure,
                                 change: changeServer)
                .padding(.top, 12)
            serverDetails
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Sign in with", selection: $login.method) {
                    if login.discovery.capabilities.login.passwordLoginAvailable {
                        Text("Password").tag(LoginModel.Method.password)
                    }
                    Text("Access Token").tag(LoginModel.Method.personalAccessToken)
                    if !login.discovery.browserSSOProviders.isEmpty {
                        Text("Browser SSO").tag(LoginModel.Method.browserSSO)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(login.isWorking)
                .padding(.bottom, 4)

                methodFields

                if let message = login.errorMessage {
                    OnboardingNotice(tone: .error, systemImage: "exclamationmark.circle.fill", message: message,
                                     identifier: "loginError")
                }
            }
            .padding(.top, 18)

            HStack(spacing: 10) {
                Button(login.isWorking ? "Cancel" : "Back") { app.cancelLogin() }
                    .keyboardShortcut(.cancelAction)
                    .onboardingSecondaryButton()
                Button(action: submit) {
                    OnboardingPrimaryButtonLabel(title: primaryTitle, progressTitle: progressTitle)
                }
                .keyboardShortcut(.defaultAction)
                .onboardingPrimaryButton()
                .disabled(login.isWorking || !canSubmit)
            }
            .padding(.top, 20)
        }
        .onAppear { focused = login.method == .password ? .loginID : .token }
        .onChange(of: login.method) { _, method in
            switch method {
            case .password: focused = .loginID
            case .personalAccessToken: focused = .token
            case .browserSSO: focused = nil
            }
        }
        .onDisappear { login.cancel() }
    }

    @ViewBuilder private var serverDetails: some View {
        VStack(spacing: 4) {
            if let version = login.discovery.version {
                if login.discovery.capabilities.isTestedReleaseLine {
                    Text("Mattermost \(version.description)")
                        .font(.caption)
                        .foregroundStyle(OnboardingStyle.supporting)
                } else {
                    Label {
                        Text("Mattermost \(version.description) — not a release line MatterMac has been tested with.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .foregroundStyle(.primary)
                }
            }
            if !isSecure {
                Text("Development mode: this local server uses unencrypted HTTP.")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var methodFields: some View {
        switch login.method {
        case .password:
            OnboardingField(systemImage: "person", isFocused: focused == .loginID, focus: { focused = .loginID }) {
                TextField(login.loginIDPrompt, text: $login.loginID)
                    .accessibilityLabel(Text(login.loginIDPrompt))
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .loginID)
                    .onSubmit { focused = .password }
            }
            OnboardingField(systemImage: "key", isFocused: focused == .password, focus: { focused = .password }) {
                SecureField("Password", text: $login.password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .onSubmit(submit)
            }
            if login.needsMFA {
                OnboardingField(systemImage: "lock.shield", isFocused: focused == .mfa, focus: { focused = .mfa }) {
                    TextField("Authentication code", text: $login.mfaCode)
                        .textContentType(.oneTimeCode)
                        .focused($focused, equals: .mfa)
                        .onSubmit(submit)
                        .onAppear { focused = .mfa }
                }
                Text("Your account uses multi-factor authentication. Enter the current code from your authenticator app.")
                    .font(.callout)
                    .foregroundStyle(OnboardingStyle.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        case .browserSSO:
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OnboardingStyle.supporting)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text("Provider")
                    .font(.title3)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Picker("Sign-in provider", selection: $login.ssoProvider) {
                    ForEach(login.discovery.browserSSOProviders, id: \.self) { provider in
                        Text(login.discovery.capabilities.login.displayName(for: provider)).tag(provider)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(login.isWorking)
            }
            .padding(.horizontal, 12)
            .frame(height: OnboardingStyle.fieldHeight)
            .background(RoundedRectangle(cornerRadius: OnboardingStyle.fieldRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: OnboardingStyle.fieldRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14)))
            OnboardingNotice(tone: .info, systemImage: "globe",
                             message: String(localized: "Continue in your browser to sign in with your organization. Use the same sign-in provider you use in Mattermost."))
            Text("MatterMac requests a private browser session. Your browser, macOS, and identity provider may retain their own sign-in data. Your organization’s SSO configuration has not been verified by MatterMac.")
                .font(.caption)
                .foregroundStyle(OnboardingStyle.supporting)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        case .personalAccessToken:
            OnboardingField(systemImage: "key.horizontal", isFocused: focused == .token, focus: { focused = .token }) {
                SecureField("Personal access token", text: $login.token)
                    .focused($focused, equals: .token)
                    .onSubmit(submit)
            }
            Text("""
                Tokens are created in Mattermost under Profile › Security when your administrator allows it. \
                MatterMac saves the token in macOS Keychain. Signing out removes it locally but does not revoke it on the server.
                """)
                .font(.callout)
                .foregroundStyle(OnboardingStyle.supporting)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var primaryTitle: String {
        login.method == .browserSSO ? String(localized: "Continue in Browser") : String(localized: "Sign In")
    }

    private var progressTitle: String? {
        guard login.isWorking else { return nil }
        return login.method == .browserSSO ? String(localized: "Waiting for Browser…") : String(localized: "Signing In…")
    }

    private var canSubmit: Bool {
        switch login.method {
        case .password:
            !login.loginID.trimmingCharacters(in: .whitespaces).isEmpty && !login.password.isEmpty
                && (!login.needsMFA || !login.mfaCode.isEmpty)
        case .personalAccessToken:
            !login.token.trimmingCharacters(in: .whitespaces).isEmpty
        case .browserSSO:
            login.discovery.browserSSOProviders.contains(login.ssoProvider)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await login.submit() }
    }

    /// Back to address entry, keeping the typed address. While adding a server,
    /// the connect screen reopens in that mode instead of returning to the window.
    private func changeServer() {
        let returnsToAddServer = !app.slots.isEmpty
        app.cancelLogin()
        if returnsToAddServer { app.showAddServer() }
    }
}
