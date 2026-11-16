public import Foundation
public import MatterMacCore

/// Answers by running a script the user installed in MatterMac's Application Scripts
/// folder (`NSUserUnixTask`). macOS runs such scripts outside the app's sandbox, which
/// is how the Claude Code and Codex command-line tools, and with them the user's
/// subscription, can be reached. MatterMac does not write the script itself: a file
/// saved from the sandbox is quarantined and macOS then refuses to run it. Settings
/// offers a Terminal command that installs it; the user may edit the script.
///
/// Protocol: `$1` instructions, `$2` task (`reply`, `summary` or `style`), text on
/// standard input, answer on standard output, exit status 0 on success.
public struct ScriptAssistant: AssistantProvider {
    public enum Kind: String, CaseIterable, Sendable {
        case claudeCode
        case codex

        public var fileName: String {
            switch self {
            case .claudeCode: "assistant-claude.sh"
            case .codex: "assistant-codex.sh"
            }
        }

        /// The script MatterMac offers to install. Tools, project settings and session
        /// history are off: the model only reads the text it is given.
        public var template: String {
            switch self {
            case .claudeCode: """
                #!/bin/zsh
                # MatterMac assistant: answers with Claude Code, using your Claude subscription.
                # $1 = instructions, $2 = task (reply, summary or style), text on stdin, answer on stdout.
                # Replies use the fast model; summaries and learning your style use the stronger one.
                export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"
                cd "${TMPDIR:-/tmp}" || exit 1
                model=sonnet
                [[ "$2" == reply ]] && model=haiku
                exec claude -p --model "$model" --system-prompt "$1" --tools "" --strict-mcp-config \\
                  --disable-slash-commands --no-session-persistence --output-format text

                """
            case .codex: """
                #!/bin/zsh
                # MatterMac assistant: answers with Codex, using your ChatGPT subscription.
                # $1 = instructions, $2 = task (reply, summary or style), text on stdin, answer on stdout.
                export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
                cd "${TMPDIR:-/tmp}" || exit 1
                answer=$(mktemp) || exit 1
                { printf '%s\\n\\n' "$1"; cat; } | codex exec --skip-git-repo-check --ephemeral --sandbox read-only \\
                  --color never -o "$answer" - >/dev/null 2>&1
                code=$?
                cat "$answer"
                rm -f "$answer"
                exit $code

                """
            }
        }
    }

    public static let timeout: Duration = .seconds(180)
    public static let maximumOutputBytes = 256 * 1_024

    public let maximumInputCharacters = 200_000
    private let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    /// `~/Library/Application Scripts/<bundle id>/`, created by macOS on first use.
    public static var scriptsDirectory: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil,
                                     create: true)
    }

    public static func scriptURL(_ kind: Kind) -> URL? {
        scriptsDirectory?.appendingPathComponent(kind.fileName, isDirectory: false)
    }

    /// A Terminal command (any shell) that writes the script and makes it executable.
    /// The script travels base64-encoded so no shell quoting can alter it.
    public static func installCommand(_ kind: Kind) -> String? {
        guard let url = scriptURL(kind) else { return nil }
        let directory = url.deletingLastPathComponent().path
        let encoded = Data(kind.template.utf8).base64EncodedString()
        return "mkdir -p \"\(directory)\" && echo \(encoded) | base64 -d > \"\(url.path)\" && chmod 755 \"\(url.path)\""
    }

    public static func isInstalled(_ kind: Kind) -> Bool {
        guard let url = scriptURL(kind) else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    public func respond(to request: AssistantRequest) async throws(AssistantError) -> String {
        guard let url = Self.scriptURL(kind), Self.isInstalled(kind) else { throw .notConfigured }
        let output = try await Self.run(url, arguments: [request.instructions, request.task.rawValue],
                                        input: Data(request.input.utf8)).get()
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .failed(code: 0) }
        return text
    }

    private enum Outcome: Sendable {
        case finished(Data, exitCode: Int)
        case timedOut
    }

    private struct Launched: Sendable {
        let reader: FileHandle
        let exits: AsyncStream<Int>
    }

    /// Starts the script and feeds it `input`. Synchronous on purpose: the task object
    /// stays in this call, and only the output handle and exit status leave it.
    private static func launch(_ url: URL, arguments: [String], input: Data) -> Launched? {
        guard let task = try? NSUserUnixTask(url: url) else { return nil }
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        task.standardInput = inputPipe.fileHandleForReading
        task.standardOutput = outputPipe.fileHandleForWriting
        // Discarded. (`FileHandle.nullDevice` cannot cross to the script runner.)
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        let writer = inputPipe.fileHandleForWriting
        // A script that exits without reading its input must not kill the app with SIGPIPE.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let childInput = inputPipe.fileHandleForReading
        let childOutput = outputPipe.fileHandleForWriting
        let (exits, exit) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        task.execute(withArguments: arguments) { error in
            // The script has ended: closing this side's copies lets the reader see the end.
            try? childOutput.close()
            try? childInput.close()
            // macOS reports a failed script as an error without a usable exit status.
            exit.yield(error == nil ? 0 : 1)
            exit.finish()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        return Launched(reader: outputPipe.fileHandleForReading, exits: exits)
    }

    /// Runs the script with `input` on its standard input and collects bounded output.
    /// A script cannot be killed from here; on timeout or cancellation its pipes are
    /// closed, which ends a well-behaved command-line tool.
    static func run(_ url: URL, arguments: [String], input: Data, timeout: Duration = ScriptAssistant.timeout)
        async -> Result<Data, AssistantError> {
        guard let launched = launch(url, arguments: arguments, input: input) else { return .failure(.notConfigured) }
        let reader = launched.reader
        let exits = launched.exits
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var data = Data()
                do {
                    for try await byte in reader.bytes {
                        data.append(byte)
                        if data.count >= maximumOutputBytes {
                            // More than any answer needs: stop the script's output.
                            try? reader.close()
                            break
                        }
                    }
                } catch {}
                var code = 1
                for await value in exits { code = value }
                return .finished(data, exitCode: code)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            try? reader.close()
            return first
        }
        if Task.isCancelled { return .failure(.cancelled) }
        switch outcome {
        case .timedOut: return .failure(.timedOut)
        case .finished(let data, 0): return .success(data)
        case .finished(_, let code): return .failure(.failed(code: code))
        }
    }
}
