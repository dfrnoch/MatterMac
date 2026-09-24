public import Foundation
import CoreGraphics
import ImageIO
public import MatterMacModels
public import MatterMacCore

/// Deterministic identifiers and entities for Core tests.
public enum CoreFixtures {
    /// Encoded image fixture built entirely in memory, with no app/test staging file.
    public static func png(width: Int = 32, height: Int = 32) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    /// A unique 26-character id: the number is terminated by "x" so that e.g. 1 and 10
    /// can never collide after padding.
    public static func id(_ prefix: String, _ n: Int) -> String {
        let base = prefix + String(n) + "x"
        return base + String(repeating: "z", count: max(0, 26 - base.count))
    }

    public static let endpoint = ServerEndpoint(scheme: .https, host: "chat.example.test", port: nil,
                                                pathSegments: ["company", "chat"])
    public static let me = User(id: UserID(unchecked: id("me", 1)), username: "alice", firstName: "Alice")
    public static let bob = User(id: UserID(unchecked: id("bob", 1)), username: "bob", firstName: "Bob")
    public static let team = Team(id: TeamID(unchecked: id("team", 1)), name: "qa", displayName: "QA")

    public static func channel(_ n: Int, type: ChannelType = .open, total: Int64 = 0) -> Channel {
        Channel(id: ChannelID(unchecked: id("ch", n)), teamID: type.isDirectOrGroup ? nil : team.id, type: type,
                name: "channel-\(n)", displayName: "Channel \(n)", totalMessageCount: total, totalMessageCountRoot: total)
    }

    public static func post(_ n: Int, channel: ChannelID, user: UserID = bob.id, message: String? = nil,
                            createAt: Int64? = nil, rootID: PostID? = nil) -> Post {
        let created = createAt ?? Int64(1_700_000_000_000 + n * 1_000)
        return Post(id: PostID(unchecked: id("post", n)), channelID: channel, userID: user, rootID: rootID,
                    message: message ?? "message \(n)", createAt: MattermostTimestamp(milliseconds: created))
    }

    /// A trivial parser for Core tests (paragraph of plain text).
    public static let plainDocuments = PostDocumentBuilder { text, _ in
        MessageDocument(blocks: [.paragraph([.text(text)])])
    }

    public static func dependencies(budget: ResourceBudget = .standard,
                                    realtime: FakeRealtimeConnection,
                                    retention: RetentionLedger? = nil,
                                    unsent: UnsentWorkLedger? = nil,
                                    clock: FixedWallClock = FixedWallClock()) -> SessionDependencies {
        SessionDependencies(
            budget: budget, retention: retention ?? RetentionLedger(budget: budget),
            unsent: unsent ?? UnsentWorkLedger(budget: budget),
            diagnostics: DiagnosticRing(byteBudget: budget.diagnosticRingBytes),
            wallClock: clock, clock: ContinuousClock(), documents: plainDocuments,
            makeRealtime: { _, _, _ in realtime }, timeZone: { TimeZone(secondsFromGMT: 0)! })
    }
}

/// Wall clock that tests can move explicitly.
public final class FixedWallClock: WallClock {
    private let state: OSAllocatedUnfairLockBox

    public init(milliseconds: Int64 = 1_700_000_500_000) {
        self.state = OSAllocatedUnfairLockBox(milliseconds)
    }

    public func now() -> Date { Date(timeIntervalSince1970: TimeInterval(state.value) / 1_000) }
    public func advance(milliseconds: Int64) { state.add(milliseconds) }
}

import os

public final class OSAllocatedUnfairLockBox: Sendable {
    private let lock: OSAllocatedUnfairLock<Int64>
    public init(_ value: Int64) { lock = OSAllocatedUnfairLock(initialState: value) }
    public var value: Int64 { lock.withLock { $0 } }
    public func add(_ delta: Int64) { lock.withLock { $0 += delta } }
}
