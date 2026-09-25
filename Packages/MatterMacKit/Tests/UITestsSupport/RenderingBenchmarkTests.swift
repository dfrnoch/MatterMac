import AppKit
import Darwin
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

/// Development-only synthetic benchmark. Reports numbers, never message content.
@MainActor @Suite("Rendering benchmarks")
struct RenderingBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM_BENCHMARKS"] == "1"))
    func largeAccount() async throws {
        let directory = await Self.directory()
        let controller = TimelineViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = controller
        defer { controller.removeAllContent(); window.close() }
        let clock = ContinuousClock()
        var switches: [Double] = [], layouts: [Double] = [], bursts: [Double] = []
        var coldLayouts: [Double] = []
        let baseline = try Self.footprint()
        var checkpoints: [UInt64] = []
        for visit in 0..<400 {
            let channel = visit % 200
            for page in 0..<5 {
                let snapshot = await Self.snapshot(channel: channel, page: page, directory: directory)
                let start = clock.now
                controller.apply(snapshot)
                window.contentView?.layoutSubtreeIfNeeded()
                _ = controller.tableView.view(atColumn: 0, row: min(2, snapshot.items.count - 1), makeIfNecessary: true)
                if page == 0 { switches.append(Self.milliseconds(start.duration(to: clock.now))) }
                // Sample 10 rows per page, separating cache hits from actual measurements.
                for item in snapshot.items.suffix(10) {
                    let measurements = controller.layouter.counters.measurements
                    let start = clock.now
                    _ = controller.layouter.exactLayout(for: item, bucket: 112)
                    let elapsed = Self.milliseconds(start.duration(to: clock.now))
                    layouts.append(elapsed)
                    if controller.layouter.counters.measurements > measurements { coldLayouts.append(elapsed) }
                }
                controller.tableView.scrollRowToVisible(max(0, snapshot.items.count - 1))
            }
            if channel % 10 == 0 {
                let burst = await Self.snapshot(channel: channel, page: 4, directory: directory, extra: 50)
                let start = clock.now
                controller.apply(burst)
                window.contentView?.layoutSubtreeIfNeeded()
                bursts.append(Self.milliseconds(start.duration(to: clock.now)))
            }
            if visit % 50 == 49 { checkpoints.append(try Self.footprint()) }
            #expect(controller.layoutCaches.renderCost <= controller.layoutCaches.renderCostLimit)
            #expect(controller.layoutCaches.rowLayoutCost <= controller.layoutCaches.rowLayoutCostLimit)
        }
        func report(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            print("BENCH \(name) n=\(sorted.count) median_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]) max_ms=\(sorted.last!)")
        }
        report("switch_apply_layout", switches)
        report("row_layout", layouts)
        if !coldLayouts.isEmpty { report("row_layout_cold", coldLayouts) }
        report("burst50_apply_layout", bursts)
        print("BENCH phys_footprint_bytes baseline=\(baseline) every50_channel_visits=\(checkpoints)")
        print("BENCH bursts_over_16_7ms=\(bursts.filter { $0 > 16.7 }.count) render_cache_bytes=\(controller.layoutCaches.renderCost) layout_cache_bytes=\(controller.layoutCaches.rowLayoutCost)")
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    nonisolated static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(result)) }
        return info.phys_footprint
    }

    @concurrent nonisolated static func directory() async -> DirectoryStore {
        var directory = DirectoryStore(budget: .standard)
        directory.replaceTeams([CoreFixtures.team])
        for n in 0..<5_000 { directory.upsertChannel(CoreFixtures.channel(n)) }
        for n in 0..<500 {
            directory.upsertUser(User(id: UserID(unchecked: CoreFixtures.id("user", n)), username: "user\(n)"))
        }
        return directory
    }

    @concurrent nonisolated static func snapshot(channel n: Int, page: Int, directory: DirectoryStore,
                                                extra: Int = 0) async -> TimelineSnapshot {
        let channel = CoreFixtures.channel(n)
        let scope = AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id)
        let corpus = ["A short message with **bold** and @alice.",
            "## Update\n\n- [x] finished\n- [ ] next\n\n> A quoted response",
            "```swift\nlet result = values.map { $0 + 1 }\n```",
            "| Name | Result |\n| :--- | ---: |\n| **Checks** | 42 |",
            String(repeating: "A longer paragraph with [a link](https://example.org). ", count: 20)]
        var store = PostStore(render: PostDocumentBuilder(parse: { MarkupParser.parse($0, limits: $1) }).document)
        var entries: [HistoryWindow.Entry] = []
        for offset in 0..<(100 + extra) {
            let number = n * 1_000 + page * 100 + offset
            let post = CoreFixtures.post(number, channel: channel.id,
                user: UserID(unchecked: CoreFixtures.id("user", number % 500)), message: corpus[number % corpus.count])
            store.upsert(post)
            entries.append(.init(id: post.id, createAt: post.createAt))
        }
        var history = HistoryWindow(target: .channel(channel.id))
        _ = history.replace(with: entries, hasOlder: true, hasNewer: false)
        let context = TimelineBuildContext(scope: scope, me: CoreFixtures.me.id, channel: channel,
            teamName: "qa", endpoint: CoreFixtures.endpoint, collapsedThreads: false,
            editTimeLimitSeconds: nil, canDeleteOthers: false, now: .zero,
            collapsedMessageCharacters: ResourceBudget.standard.collapsedMessageCharacters)
        let output = TimelineBuilder.build(window: history, store: store, directory: directory, pending: [], context: context)
        return TimelineSnapshot(scope: scope, target: history.target, generation: UInt64(n * 10 + page + (extra > 0 ? 1 : 0)),
            items: output.items, isAtLiveEdge: true, isStale: false, scrollRequest: nil)
    }
}
