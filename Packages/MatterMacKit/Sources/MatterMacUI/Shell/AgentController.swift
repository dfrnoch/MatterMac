import AppKit
import Observation
import SwiftUI
import MatterMacModels
import MatterMacCore
import MatterMacPlatform

/// Answers `MatterMac agent …` requests for the signed-in, active account. It runs
/// only while the user has "Allow command-line agents" on, reads without marking
/// anything read, and sends through the normal pending queue so every message an
/// agent sends shows in the app like one the user typed.
@MainActor
@Observable
final class AgentController {
    enum State: Equatable {
        case off
        case listening
        case failed(String)
    }

    private(set) var state: State = .off
    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var server: AgentControlServer?
    @ObservationIgnored private let socketPath: String?

    init(environment: AppEnvironment, socketPath: String?) {
        self.environment = environment
        self.socketPath = socketPath
    }

    /// Starts or stops listening to match the setting, now and whenever it changes.
    func bind() {
        withObservationTracking {
            apply(enabled: environment.settings.agentControlEnabled)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.bind() }
        }
    }

    private func apply(enabled: Bool) {
        guard enabled else {
            server?.stop()
            server = nil
            state = .off
            return
        }
        guard server == nil, let socketPath else { return }
        let server = AgentControlServer(path: socketPath) { [weak self] request in
            await self?.handle(request) ?? Self.failure("MatterMac is shutting down.")
        }
        do throws(AgentControlServer.StartError) {
            try server.start()
            self.server = server
            state = .listening
        } catch {
            switch error {
            case .inUse: state = .failed(String(localized: "Another running copy of MatterMac already answers agents."))
            case .pathTooLong: state = .failed(String(localized: "Your home folder path is too long for the control socket."))
            case .system(let code): state = .failed(String(localized: "The control socket could not be opened (\(code))."))
            }
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    // MARK: Requests

    func handle(_ data: Data) async -> Data {
        guard environment.settings.agentControlEnabled else { return Self.failure("Agent control is off.") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else { return Self.failure("Malformed request.") }
        let arguments = object["arguments"] as? [String] ?? []
        let options = object["options"] as? [String: String] ?? [:]
        environment.diagnostics.record(.lifecycle, .info, "agent command")
        if command == "status" { return status() }
        guard let model = environment.appModel?.activeSession, !model.isDetached, !model.requiresAuthentication else {
            return Self.failure("MatterMac is not signed in.")
        }
        do throws(UserFacingError) {
            switch command {
            case "channels":
                var channels = await model.session.plainChannels()
                if options["unread"] != nil { channels = channels.filter { $0.unreadMessages > 0 || $0.mentions > 0 } }
                let limit = Self.limit(options, default: 100, maximum: 1_000)
                return Self.success(["channels": channels.prefix(limit).map(Self.json)])
            case "read":
                guard let reference = arguments.first else { return Self.failure("Usage: read <channel> [--limit N]") }
                let channel = try await model.session.resolvePlainChannel(reference)
                let before = options["before"].flatMap(PostID.init(rawValue:))
                let posts = try await model.session.plainPosts(
                    channel: channel, limit: Self.limit(options, default: 30, maximum: ServerSession.plainPageLimit),
                    before: before)
                return Self.success(["channel_id": channel.rawValue, "posts": posts.map(Self.json)])
            case "thread":
                guard let id = arguments.first.flatMap(PostID.init(rawValue:)) else {
                    return Self.failure("Usage: thread <post id>")
                }
                let root = try await model.session.plainThreadRoot(of: id).root
                return Self.success(["posts": try await model.session.plainThread(root: root).map(Self.json)])
            case "search":
                guard !arguments.isEmpty else { return Self.failure("Usage: search <terms>") }
                let posts = try await model.session.plainSearch(arguments.joined(separator: " "),
                                                                limit: Self.limit(options, default: 20, maximum: 100))
                return Self.success(["posts": posts.map(Self.json)])
            case "send":
                guard arguments.count >= 2 else { return Self.failure("Usage: send <channel> <text> [--reply-to <post id>]") }
                return try await send(arguments, options: options, model: model)
            case "open":
                guard let reference = arguments.first else { return Self.failure("Usage: open <channel> [--post <post id>]") }
                let channel = try await model.session.resolvePlainChannel(reference)
                model.select(channel: channel, focusing: options["post"].flatMap(PostID.init(rawValue:)))
                return Self.success(["channel_id": channel.rawValue])
            case "summary":
                return await summary(arguments, model: model)
            default:
                return Self.failure("Unknown command. Run: MatterMac agent help")
            }
        } catch {
            return Self.failure(UserFacingErrorText.describe(error))
        }
    }

    private func send(_ arguments: [String], options: [String: String], model: SessionViewModel)
        async throws(UserFacingError) -> Data {
        let channel = try await model.session.resolvePlainChannel(arguments[0])
        let text = arguments.dropFirst().joined(separator: " ")
        var root: PostID?
        if let reply = options["reply-to"] {
            guard let id = PostID(rawValue: reply) else { return Self.failure("--reply-to needs a post id.") }
            let thread = try await model.session.plainThreadRoot(of: id)
            guard thread.channel == channel else { return Self.failure("That post is in a different channel.") }
            root = thread.root
        }
        switch await model.session.sendPlain(text: text, channel: channel, rootID: root) {
        case .sent(let post):
            return Self.success(["state": "sent", "post_id": post.rawValue, "channel_id": channel.rawValue])
        case .queued(let pending):
            return Self.success(["state": "queued", "pending_id": pending.rawValue,
                                 "note": "Not confirmed by the server yet. MatterMac keeps trying and shows it as pending."])
        case .outcomeUnknown(let pending):
            return Self.failure("The server may or may not have received the message. It is shown in MatterMac for you to retry or discard.",
                                extra: ["state": "unknown", "pending_id": pending.rawValue])
        case .rejected(let rejection):
            return Self.failure(ConversationController.sendRejectionText(rejection))
        case .failed(let error):
            return Self.failure(UserFacingErrorText.describe(error), extra: ["state": "failed"])
        }
    }

    private func summary(_ arguments: [String], model: SessionViewModel) async -> Data {
        let result: Result<AssistantSummary, AssistantFailure>
        switch arguments.first {
        case "today":
            result = await model.summarizeToday()
        case "thread":
            guard arguments.count > 1, let id = PostID(rawValue: arguments[1]) else {
                return Self.failure("Usage: summary thread <post id>")
            }
            do throws(UserFacingError) {
                result = await model.summarizeThread(root: try await model.session.plainThreadRoot(of: id).root)
            } catch {
                return Self.failure(UserFacingErrorText.describe(error))
            }
        default:
            return Self.failure("Usage: summary today | summary thread <post id>")
        }
        switch result {
        case .success(let summary):
            return Self.success(["summary": summary.text, "messages": summary.coveredMessages,
                                 "omitted_messages": summary.omittedMessages])
        case .failure(let failure):
            return Self.failure(failure.message)
        }
    }

    private func status() -> Data {
        let app = environment.appModel
        let info = Bundle.main.infoDictionary ?? [:]
        var body: [String: Any] = [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "",
            "accounts": (app?.slots ?? []).map { slot in
                ["server": slot.endpoint.description, "user": slot.user.username,
                 "active": slot.id == app?.activeSlotID] as [String: Any]
            },
            "assistant": environment.settings.assistant.rawValue,
        ]
        if let model = app?.activeSession {
            body["connection"] = Self.name(model.connection)
            if let header = model.header {
                body["open_channel"] = ["id": header.channelID.rawValue, "display_name": header.displayName]
            }
        }
        return Self.success(body)
    }

    // MARK: JSON

    static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func json(_ post: PlainPost) -> [String: Any] {
        var object: [String: Any] = [
            "id": post.id.rawValue, "channel_id": post.channelID.rawValue, "user": post.username,
            "name": post.displayName, "time": timestamps.string(from: post.createdAt.date), "text": post.message,
        ]
        if let root = post.rootID { object["thread_id"] = root.rawValue }
        if post.fileCount > 0 { object["files"] = post.fileCount }
        if post.replyCount > 0 { object["replies"] = post.replyCount }
        if post.isSystem { object["system"] = true }
        return object
    }

    static func json(_ channel: PlainChannel) -> [String: Any] {
        var object: [String: Any] = [
            "id": channel.id.rawValue, "name": channel.name, "display_name": channel.displayName, "type": channel.kind,
            "unread": channel.unreadMessages, "mentions": channel.mentions,
        ]
        if let team = channel.team { object["team"] = team }
        if !channel.lastPostAt.isZero { object["last_post"] = timestamps.string(from: channel.lastPostAt.date) }
        return object
    }

    static func limit(_ options: [String: String], default value: Int, maximum: Int) -> Int {
        min(max(options["limit"].flatMap(Int.init) ?? value, 1), maximum)
    }

    static func name(_ status: ConnectionStatus) -> String {
        switch status {
        case .connected: "connected"
        case .offline: "offline"
        case .authenticationRequired: "signed out"
        case .disconnected: "disconnected"
        default: "connecting"
        }
    }

    nonisolated static func success(_ body: [String: Any]) -> Data {
        var object = body
        object["ok"] = true
        return encode(object)
    }

    nonisolated static func failure(_ message: String, extra: [String: Any] = [:]) -> Data {
        var object = extra
        object["ok"] = false
        object["error"] = message
        return encode(object)
    }

    private nonisolated static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object,
                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"ok\":false}".utf8)
    }
}

/// Settings › Assistant › agent control.
struct AgentControlSection: View {
    let environment: AppEnvironment

    private var command: String {
        (Bundle.main.executablePath ?? "MatterMac").replacingOccurrences(of: " ", with: "\\ ") + " agent"
    }

    var body: some View {
        Section {
            Toggle("Allow command-line agents", isOn: Binding(get: { environment.settings.agentControlEnabled },
                                                              set: { environment.settings.agentControlEnabled = $0 }))
                .accessibilityIdentifier("agentControlToggle")
            Text("Lets programs you run on this Mac, such as Claude Code or Codex, read your conversations and send messages as you through MatterMac while it is open. They never get your sign-in. Reading this way doesn’t mark anything read.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if environment.settings.agentControlEnabled {
                if case .failed(let reason) = environment.agent.state {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Command") {
                    HStack {
                        Text(command + " help").font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    }
                }
            }
        } header: {
            Label("Agent Control", systemImage: "terminal")
        }
    }
}
