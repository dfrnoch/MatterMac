import AppKit
import SwiftUI
import MatterMacCore
import MatterMacPlatform

/// Settings › Assistant: who answers (nobody by default), reply suggestions, and
/// command-line agent control. Every choice says where conversation text goes.
struct AssistantSettingsTab: View {
    let environment: AppEnvironment
    @State private var apiKey = ""
    @State private var hasKey = KeychainSecret.claudeAPIKey.exists
    /// Bumped to re-read state that lives outside SwiftUI (installed scripts).
    @State private var revision = 0
    @State private var test: TestState = .idle

    enum TestState: Equatable {
        case idle, running
        case passed(String)
        case failed(String)
    }

    private var settings: LocalSettings { environment.settings }

    var body: some View {
        Form {
            Section {
                Picker("Answer with", selection: Binding(get: { settings.assistant }, set: {
                    settings.assistant = $0
                    test = .idle
                })) {
                    Text("Off").tag(LocalSettings.AssistantChoice.off)
                    Text("On-device model").tag(LocalSettings.AssistantChoice.onDevice)
                    Text("Claude API").tag(LocalSettings.AssistantChoice.claudeAPI)
                    Text("Claude Code (Claude subscription)").tag(LocalSettings.AssistantChoice.claudeCode)
                    Text("Codex (ChatGPT subscription)").tag(LocalSettings.AssistantChoice.codex)
                }
                .accessibilityIdentifier("assistantPicker")
                providerDetails
                if settings.assistant != .off { testRow }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Assistant", systemImage: "sparkles")
                    Text("Drafts replies and summarizes threads and your day. Saved on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Suggest a reply while reading", isOn: Binding(get: { settings.assistantSuggestsReplies },
                                                                      set: { settings.assistantSuggestsReplies = $0 }))
                    .disabled(settings.assistant == .off)
                    .accessibilityIdentifier("assistantSuggestionsToggle")
                Text("Off unless you turn it on. The suggestion appears greyed out in an empty message box when the newest message is someone else’s. Tab inserts it, Escape removes it. Nothing is sent until you send it.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.assistantSuggestsReplies, settings.assistant != .off {
                    if let session = environment.appModel?.activeSession, !session.isDetached, !session.requiresAuthentication {
                        WritingStyleRows(session: session, providerName: settings.assistant.title)
                    } else {
                        Text("Sign in to teach the assistant how you write.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Reply Suggestions", systemImage: "text.cursor")
            }

            AgentControlSection(environment: environment)
        }
        .formStyle(.grouped)
        .id(revision)
    }

    @ViewBuilder private var providerDetails: some View {
        switch settings.assistant {
        case .off:
            caption("No conversation text is sent anywhere.")
        case .onDevice:
            caption("Runs on this Mac with Apple Intelligence. Nothing leaves the Mac. Long conversations are condensed in steps, so summaries are less detailed.")
            if let problem = Self.onDeviceProblem {
                warning(problem)
            } else if !OnDeviceAssistant.supportedLanguageNames.isEmpty {
                caption("Apple’s model only handles \(OnDeviceAssistant.supportedLanguageNames.joined(separator: ", ")). In other languages its replies are poor; choose Claude or Codex for those.")
            }
        case .claudeAPI:
            caption("Sends the conversation text of each request to Anthropic (api.anthropic.com), billed to your API key. The key is kept in your Mac’s Keychain.")
            caption("Reply suggestions use Claude Haiku 5.5 and learning your writing style uses Claude Sonnet 5.5.")
            Picker("Model for summaries", selection: Binding(get: { settings.assistantClaudeModel },
                                               set: { settings.assistantClaudeModel = $0 })) {
                Text("Claude Opus 5.5").tag(ClaudeAPIAssistant.Model.opus)
                Text("Claude Sonnet 5.5").tag(ClaudeAPIAssistant.Model.sonnet)
                Text("Claude Haiku 5.5").tag(ClaudeAPIAssistant.Model.haiku)
            }
            if hasKey {
                LabeledContent("API key") {
                    HStack {
                        Text("Saved").foregroundStyle(.secondary)
                        Button("Remove") {
                            KeychainSecret.claudeAPIKey.delete()
                            hasKey = false
                            test = .idle
                        }
                    }
                }
            } else {
                HStack {
                    SecureField("API key", text: $apiKey, prompt: Text("sk-ant-…"))
                        .accessibilityIdentifier("assistantKeyField")
                    Button("Save") {
                        hasKey = KeychainSecret.claudeAPIKey.save(apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        case .claudeCode:
            scriptDetails(.claudeCode, text: "Runs the claude command-line tool through a script you install, so requests use your Claude Code login and subscription. The conversation text of each request goes to Anthropic.")
        case .codex:
            scriptDetails(.codex, text: "Runs the codex command-line tool through a script you install, so requests use your Codex login and ChatGPT subscription. The conversation text of each request goes to OpenAI.")
        }
    }

    @ViewBuilder private func scriptDetails(_ kind: ScriptAssistant.Kind, text: LocalizedStringKey) -> some View {
        caption(text)
        let installed = ScriptAssistant.isInstalled(kind)
        LabeledContent("Script") {
            HStack {
                Text(installed ? "Installed" : "Not installed").foregroundStyle(.secondary)
                if installed {
                    Button("Show in Finder") {
                        if let url = ScriptAssistant.scriptURL(kind) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                Button("Copy Install Command") {
                    guard let command = ScriptAssistant.installCommand(kind) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .accessibilityIdentifier("assistantInstallScript")
                Button("Refresh") { revision += 1 }
            }
        }
        caption("Paste the command into Terminal once. macOS only runs scripts that you place in MatterMac’s scripts folder yourself; MatterMac can’t install it for you. You can edit the script afterwards, for example to choose another model.")
    }

    private var testRow: some View {
        HStack {
            Button("Test") { runTest() }.disabled(test == .running)
            switch test {
            case .idle: EmptyView()
            case .running: ProgressView().controlSize(.small)
            case .passed(let text):
                Label(text, systemImage: "checkmark.circle").foregroundStyle(.secondary).lineLimit(2)
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .accessibilityIdentifier("assistantTestRow")
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    static var onDeviceProblem: String? {
        switch OnDeviceAssistant.availability {
        case .available: nil
        case .needsNewerSystem: String(localized: "Needs macOS 26 or later.")
        case .deviceNotEligible: String(localized: "This Mac doesn’t support Apple Intelligence.")
        case .appleIntelligenceOff: String(localized: "Turn on Apple Intelligence in System Settings.")
        case .modelNotReady: String(localized: "The model is still downloading. Try again later.")
        }
    }

    /// One small request through the chosen provider (no conversation text).
    private func runTest() {
        guard let provider = environment.assistant else { return }
        test = .running
        environment.assistantProblemReported = false
        Task {
            do throws(AssistantError) {
                let answer = try await provider.respond(to: AssistantRequest(
                    task: .reply, instructions: "You are checking a connection. Answer with one short friendly sentence.",
                    input: "Say that the MatterMac assistant is ready."))
                test = .passed(String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140)))
            } catch {
                test = .failed(AssistantStrings.describe(error))
            }
        }
    }
}

/// "Learn from my writing": the stronger model reads the user's recent messages once
/// and writes notes on how they write; the fast model uses them for every suggestion.
struct WritingStyleRows: View {
    let session: SessionViewModel
    let providerName: String
    @State private var showsProfile = false

    var body: some View {
        LabeledContent("Your writing style") {
            HStack {
                if session.isLearningStyle {
                    ProgressView().controlSize(.small)
                    Text("Reading your messages…").foregroundStyle(.secondary)
                } else {
                    Button(session.styleProfile == nil ? "Learn from My Writing" : "Learn Again") { session.learnStyle() }
                        .accessibilityIdentifier("assistantLearnStyle")
                    if session.styleProfile != nil {
                        Button("Forget") { session.forgetStyle() }
                    }
                }
            }
        }
        if let profile = session.styleProfile {
            Text("Learned from \(profile.messageCount) of your messages on \(profile.learnedAt.formatted(date: .abbreviated, time: .shortened)) with \(profile.provider). Suggestions follow these notes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistantStyleStatus")
            DisclosureGroup("What it learned", isExpanded: $showsProfile) {
                Text(profile.text)
                    .font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !session.isLearningStyle {
            Text("Not learned yet, so suggestions only copy your messages in the current conversation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let error = session.styleLearningError {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Learning sends up to 300 of your recent messages to \(providerName) once. The notes stay in your Mac’s Keychain for this account, go along with each suggestion request, and are deleted when you sign out or press Forget.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
