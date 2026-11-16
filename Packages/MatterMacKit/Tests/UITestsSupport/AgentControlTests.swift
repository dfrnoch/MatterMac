import Foundation
import Testing
import MatterMacCore
@testable import MatterMacPlatform

@Suite("Agent control socket, command line and assistant providers", .serialized)
struct AgentControlTests {
    /// A short socket path (sun_path holds 104 bytes; the test temp folder is long).
    func socketPath() -> String { "/tmp/mm-agent-\(UInt32.random(in: 0...UInt32.max)).sock" }

    @Test func requestsRoundTripAndTheSocketIsPrivateAndRemovedOnStop() async throws {
        let path = socketPath()
        let server = AgentControlServer(path: path) { request in
            Data("echo:".utf8) + request
        }
        try server.start()
        #expect(server.isRunning)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        let reply = await Task.detached { AgentControl.request(Data("hello".utf8), path: path) }.value
        #expect(try reply.get() == Data("echo:hello".utf8))
        // A second copy of the app must not take over a socket that is being served.
        let second = AgentControlServer(path: path) { $0 }
        #expect(throws: AgentControlServer.StartError.inUse) { try second.start() }
        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: path))
        let after = await Task.detached { AgentControl.request(Data("hello".utf8), path: path) }.value
        #expect(after == .failure(.notRunning))
    }

    @Test func oversizedRequestsAreRefusedBeforeSending() {
        let big = Data(count: AgentControl.maximumRequestBytes + 1)
        #expect(AgentControl.request(big, path: socketPath()) == .failure(.failed))
        #expect(AgentControl.address(String(repeating: "a", count: 200)) == nil)
    }

    @Test func commandLineSplitsArgumentsOptionsAndFlags() throws {
        let read = try #require(AgentCLI.parse(["read", "town-square", "--limit", "5", "--unread"]))
        #expect(read == AgentCLI.Invocation(command: "read", arguments: ["town-square"],
                                            options: ["limit": "5", "unread": "true"]))
        let send = try #require(AgentCLI.parse(["send", "@bob", "on my way", "--reply-to", "abc"]))
        #expect(send.arguments == ["@bob", "on my way"] && send.options == ["reply-to": "abc"])
        #expect(AgentCLI.parse([]) == nil && AgentCLI.parse(["--help"]) == nil)
        let data = try #require(AgentCLI.requestData(send))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "send" && object["version"] as? Int == 1)
        // With nothing listening the command explains itself and exits with status 2.
        #expect(AgentCLI.run(["status"], socketPath: socketPath()) == 2)
    }

    @Test func claudeRequestShapeAndAnswerParsing() throws {
        let request = AssistantRequest(task: .reply, instructions: "sys", input: "hello")
        let body = ClaudeAPIAssistant.body(for: request, model: .opus)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["system"] as? String == "sys")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["thinking"] == nil && body["temperature"] == nil)
        let summary = ClaudeAPIAssistant.body(for: AssistantRequest(task: .summary, instructions: "s", input: "i"), model: .haiku)
        #expect(summary["fallbacks"] == nil && (summary["output_config"] as? [String: String])?["effort"] == "medium")
        #expect(summary["max_tokens"] as? Int == 16_000)
        // Replies are always Haiku, learning the user's style is always Sonnet, and
        // only summaries follow the model chosen in Settings.
        #expect(ClaudeAPIAssistant.model(for: .reply, summaryModel: .opus) == .haiku)
        #expect(ClaudeAPIAssistant.model(for: .style, summaryModel: .opus) == .sonnet)
        #expect(ClaudeAPIAssistant.model(for: .summary, summaryModel: .opus) == .opus)
        #expect(ClaudeAPIAssistant.Model.sonnet.rawValue == "claude-sonnet-5-5"
            && ClaudeAPIAssistant.Model.haiku.rawValue == "claude-haiku-5-5")

        let answer = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hi "},{"type":"text","text":"there"}]}"#.utf8)
        #expect(try ClaudeAPIAssistant.answer(from: answer).get() == "Hi there")
        let refusal = Data(#"{"stop_reason":"refusal","content":[]}"#.utf8)
        #expect(ClaudeAPIAssistant.answer(from: refusal) == .failure(.refused))
        #expect(ClaudeAPIAssistant.answer(from: Data("not json".utf8)) == .failure(.failed(code: 200)))
    }

    @Test func scriptsGetInstructionsAndInputAndReportFailureAndTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mm-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func script(_ name: String, _ body: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(("#!/bin/zsh\n" + body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let echo = try script("echo.sh", #"printf '%s|%s|' "$1" "$2"; cat"#)
        let output = await ScriptAssistant.run(echo, arguments: ["be brief", "reply"], input: Data("the conversation".utf8))
        #expect(try String(decoding: output.get(), as: UTF8.self) == "be brief|reply|the conversation")
        let failing = try script("fail.sh", "cat >/dev/null; exit 3")
        #expect(await ScriptAssistant.run(failing, arguments: [], input: Data("x".utf8)) == .failure(.failed(code: 1)))
        let slow = try script("slow.sh", "cat >/dev/null; sleep 5; echo late")
        let started = ContinuousClock.now
        #expect(await ScriptAssistant.run(slow, arguments: [], input: Data(), timeout: .milliseconds(300)) == .failure(.timedOut))
        #expect(ContinuousClock.now - started < .seconds(3), "a timeout does not wait for the script")
        // The install command reproduces the template exactly, whatever the shell.
        let command = try #require(ScriptAssistant.installCommand(.codex))
        let encoded = try #require(command.split(separator: " ").first { $0.count > 200 })
        #expect(Data(base64Encoded: String(encoded)) == Data(ScriptAssistant.Kind.codex.template.utf8))
        #expect(command.contains("base64 -d") && command.hasSuffix("assistant-codex.sh\""))
        // The templates name the tools and keep them from using tools or project settings.
        #expect(ScriptAssistant.Kind.claudeCode.template.contains(#"--tools """#))
        #expect(ScriptAssistant.Kind.codex.template.contains("--sandbox read-only"))
    }
}
