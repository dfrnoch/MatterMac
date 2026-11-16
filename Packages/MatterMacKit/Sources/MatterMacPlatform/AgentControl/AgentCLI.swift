public import Foundation

/// `MatterMac agent <command> …`: the command-line side of agent control. The app's
/// own executable runs this instead of starting the app, sends one request to the
/// running app and prints its JSON answer. It holds no credentials and talks to no
/// server itself.
public enum AgentCLI {
    public static let usage = """
        MatterMac agent: read and send in the running MatterMac app from the command line.

        Turn on "Allow command-line agents" in MatterMac > Settings > Assistant first.
        Answers are JSON on standard output. Failures have "ok": false and exit status 1.

          status                               accounts, connection, the open conversation
          channels [--unread] [--limit N]      conversations, most recently active first
          read <channel> [--limit N] [--before <post id>]
                                               messages, oldest first (does not mark them read)
          thread <post id>                     a whole thread
          search <terms> [--limit N]           search messages in the current team
          send <channel> <text> [--reply-to <post id>]
                                               send a message ("-" reads the text from standard input)
          open <channel> [--post <post id>]    show a conversation in the app window
          summary today                        the assistant's briefing of today's activity
          summary thread <post id>             the assistant's summary of a thread

        <channel> is an id, a name (town-square) or @username for a direct message.

        """

    public struct Invocation: Hashable, Sendable {
        public var command: String
        public var arguments: [String]
        public var options: [String: String]
    }

    /// Splits `read town-square --limit 5` into command, positional arguments and
    /// options. An option without a value is the flag "true".
    public static func parse(_ tokens: [String]) -> Invocation? {
        guard let command = tokens.first, !command.hasPrefix("-") else { return nil }
        var arguments: [String] = []
        var options: [String: String] = [:]
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--"), token.count > 2 {
                let name = String(token.dropFirst(2))
                if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    options[name] = tokens[index + 1]
                    index += 1
                } else {
                    options[name] = "true"
                }
            } else {
                arguments.append(token)
            }
            index += 1
        }
        return Invocation(command: command, arguments: arguments, options: options)
    }

    public static func requestData(_ invocation: Invocation) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "version": 1, "command": invocation.command, "arguments": invocation.arguments,
            "options": invocation.options,
        ])
    }

    /// Runs one command. `tokens` are the arguments after `agent`.
    public static func run(_ tokens: [String], socketPath: String = AgentControl.socketPath) -> Int32 {
        guard var invocation = parse(tokens), invocation.command != "help" else {
            print(usage, terminator: "")
            return tokens.isEmpty || tokens.first == "help" || tokens.first == "--help" ? 0 : 64
        }
        // "send <channel> -": the message comes from standard input.
        if invocation.command == "send", invocation.arguments.count == 2, invocation.arguments[1] == "-" {
            let input = FileHandle.standardInput.readData(ofLength: AgentControl.maximumRequestBytes / 2)
            invocation.arguments[1] = String(decoding: input, as: UTF8.self)
        }
        guard let request = requestData(invocation), request.count <= AgentControl.maximumRequestBytes else {
            return fail("The request is too large.")
        }
        switch AgentControl.request(request, path: socketPath) {
        case .success(let response):
            FileHandle.standardOutput.write(response)
            FileHandle.standardOutput.write(Data("\n".utf8))
            let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
            return object?["ok"] as? Bool == true ? 0 : 1
        case .failure(.notRunning):
            return fail("MatterMac is not running, or agent control is off. Open MatterMac and turn on "
                        + "\"Allow command-line agents\" in Settings > Assistant.")
        case .failure:
            return fail("MatterMac did not answer.")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        let object: [String: Any] = ["ok": false, "error": message]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        return 2
    }
}
