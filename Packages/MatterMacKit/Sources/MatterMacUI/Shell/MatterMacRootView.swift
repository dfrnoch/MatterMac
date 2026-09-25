public import SwiftUI
import AppKit
import MatterMacModels
import MatterMacCore

/// Root content of the main window. The app target embeds this in its single
/// `Window` scene; all navigation state below it lives in memory only.
public struct MatterMacRootView: View {
    @State private var model: AppModel

    public init(environment: AppEnvironment) {
        let model = environment.appModel ?? AppModel(environment: environment)
        environment.appModel = model
        _model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .restoring:
                ZStack {
                    OnboardingBackdrop()
                    ProgressView("Restoring saved sign-ins…")
                        .padding(24)
                        .glassSurface(cornerRadius: 20)
                }
            case .connect:
                ConnectView(model: model)
            case .login(let login):
                LoginView(login: login, app: model)
            case .main:
                if let session = model.activeSession {
                    MainWindowView(app: model, session: session)
                        .id(session.scope)
                } else {
                    ConnectView(model: model)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .task { await model.restoreSavedAccounts() }
        .sheet(isPresented: Binding(get: { model.isCompatibilityVisible },
                                    set: { model.isCompatibilityVisible = $0 })) {
            CompatibilityView(app: model)
        }
        .sheet(isPresented: Binding(get: { model.isShortcutsVisible }, set: { model.isShortcutsVisible = $0 })) {
            KeyboardShortcutsView()
        }
    }
}

/// Server connection screen; saved accounts are restored separately at launch.
struct ConnectView: View {
    let model: AppModel
    @State private var serverText = ""
    @State private var validation: ValidationState = .idle
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    enum ValidationState: Equatable {
        case idle
        case invalid(String)
        case normalized(String)
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            card
        }
        .onDisappear(perform: cancelProbe)
    }

    private var card: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("MatterMac")
                .font(.largeTitle.weight(.semibold))
            // Primary-weight colours: secondary text fails contrast on the glass card.
            Text("An independent, native client for existing Mattermost servers.")
                .foregroundStyle(Color.primary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL")
                    .font(.headline)
                TextField("https://chat.example.org", text: $serverText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .textContentType(.URL)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onChange(of: serverText) { validation = .idle }
                    .accessibilityLabel(Text("Server URL"))
                    .disabled(isProbing)
                switch validation {
                case .idle:
                    EmptyView()
                case .invalid(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("serverError")
                case .normalized(let origin):
                    Label("Will connect to \(origin)", systemImage: "lock")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .accessibilityIdentifier("normalizedOrigin")
                }
            }
            .frame(maxWidth: 420)

            HStack {
                if model.isAddingServer {
                    Button("Cancel") { cancelProbe(); model.cancelLogin() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(action: submit) {
                    if isProbing { ProgressView().controlSize(.small) }
                    else if case .normalized = validation { Text("Connect") }
                    else { Text("Continue") }
                }
                .keyboardShortcut(.defaultAction)
                .glassButtonStyle(prominent: true)
                .disabled(serverText.trimmingCharacters(in: .whitespaces).isEmpty || isProbing)
            }
            .controlSize(.large)

            Text("""
                MatterMac saves account sign-ins in macOS Keychain. Signing out removes the saved sign-in. \
                Messages and drafts stay in memory only; quitting discards them. Your server stores sent messages.
                """)
                .font(.footnote)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .accessibilityIdentifier("sessionDisclosure")
            if model.canRetrySavedSignIn {
                Button("Retry Saved Sign-In") { Task { await model.restoreSavedAccounts(retry: true) } }
                    .disabled(isProbing)
            }
            if let message = model.lastSignOutMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .padding(36)
        .frame(width: 540)
        .glassSurface(cornerRadius: 28, tint: Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { fieldFocused = true }
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
        ZStack {
            OnboardingBackdrop()
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: login.discovery.endpoint.scheme == .https ? "lock.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(login.discovery.endpoint.scheme == .https ? Color.secondary : Color.orange)
                VStack(alignment: .leading) {
                    Text(login.discovery.capabilities.siteName.isEmpty ? "Mattermost" : login.discovery.capabilities.siteName)
                        .font(.title2.weight(.semibold))
                    Text(login.discovery.endpoint.description)
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("loginOrigin")
                }
            }
            if let version = login.discovery.version {
                Text(login.discovery.capabilities.isTestedReleaseLine
                     ? "Mattermost \(version.description)"
                     : "Mattermost \(version.description) — not a release line MatterMac has been tested with.")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            if login.discovery.endpoint.scheme == .http {
                Text("Development mode: this local server uses unencrypted HTTP.")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            Picker("Sign in with", selection: $login.method) {
                if login.discovery.capabilities.login.passwordLoginAvailable {
                    Text("Password").tag(LoginModel.Method.password)
                }
                Text("Personal access token").tag(LoginModel.Method.personalAccessToken)
                if !login.discovery.browserSSOProviders.isEmpty {
                    Text("Browser SSO").tag(LoginModel.Method.browserSSO)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(login.isWorking)

            switch login.method {
            case .password:
                TextField(login.loginIDPrompt, text: $login.loginID)
                    .accessibilityLabel(Text(login.loginIDPrompt))
                    .textContentType(.username)
                    .focused($focused, equals: .loginID)
                    .onSubmit { focused = .password }
                SecureField("Password", text: $login.password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .onSubmit(submit)
                if login.needsMFA {
                    TextField("Authentication code", text: $login.mfaCode)
                        .textContentType(.oneTimeCode)
                        .focused($focused, equals: .mfa)
                        .onSubmit(submit)
                        .onAppear { focused = .mfa }
                    Text("Your account uses multi-factor authentication. Enter the current code from your authenticator app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .browserSSO:
                Picker("Sign-in provider", selection: $login.ssoProvider) {
                    ForEach(login.discovery.browserSSOProviders, id: \.self) { provider in
                        Text(login.discovery.capabilities.login.displayName(for: provider)).tag(provider)
                    }
                }
                .disabled(login.isWorking)
                Text("Continue in your browser to sign in with your organization. Use the same sign-in provider you use in Mattermost.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("MatterMac requests a private browser session. Your browser, macOS, and identity provider may retain their own sign-in data. Your organization’s SSO configuration has not been verified by MatterMac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .personalAccessToken:
                SecureField("Personal access token", text: $login.token)
                    .focused($focused, equals: .token)
                    .onSubmit(submit)
                Text("""
                    Tokens are created in Mattermost under Profile › Security when your administrator allows it. \
                    MatterMac saves the token in macOS Keychain. Signing out removes it locally but does not revoke it on the server.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = login.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("loginError")
            }

            HStack {
                Button(login.isWorking ? "Cancel" : "Back") { app.cancelLogin() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submit) {
                    if login.isWorking { ProgressView().controlSize(.small) } else { Text(login.method == .browserSSO ? "Continue in Browser" : "Sign In") }
                }
                .keyboardShortcut(.defaultAction)
                .glassButtonStyle(prominent: true)
                .disabled(login.isWorking || !canSubmit)
            }
            .controlSize(.large)
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 440)
        .padding(32)
        .glassSurface(cornerRadius: 28, tint: Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = login.method == .password ? .loginID : .token }
        .onDisappear { login.cancel() }
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
}

/// Quiet, static tinted backdrop behind the onboarding cards (no animation).
struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.18), .clear],
                           center: .topLeading, startRadius: 40, endRadius: 700)
            RadialGradient(colors: [Color.purple.opacity(colorScheme == .dark ? 0.20 : 0.12), .clear],
                           center: .bottomTrailing, startRadius: 40, endRadius: 650)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
