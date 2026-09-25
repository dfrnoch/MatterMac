# Synthetic native rendering benchmark

This is a development rendering workload, not a whole-app performance acceptance
result. It exercises real PostStore parsing, TimelineBuilder presentation, native
NSTableView application/scrolling, and TextKit rendering/measurement. No server,
network transport or installed MatterMac process is involved.

## Reproduction

```sh
MM_BENCHMARKS=1 swift test -c release --package-path Packages/MatterMacKit \
  -Xswiftc -enable-testing --filter RenderingBenchmarkTests
```

`-enable-testing` is needed by this host's SwiftPM/Xcode backend to compile Release
`@testable` imports. A plain `swift build -c release --build-tests` failed resolving
compatible Core/API/Realtime modules; no measurements were taken from that failure.

Host: Apple M1 Pro, MacBookPro18,3, 16 GiB RAM, macOS 27.0 (26A428), Xcode 27.0
(27A266a), Swift 6.4. Release optimization is `-O`/whole-module optimization with
Swift 6 strict concurrency, arm64, macOS 14 deployment target. No debugger or
profiler. Concurrent development activity may influence results.

The deterministic corpus generates pages on demand (no random seed): 5,000 channel
summaries, 500 user profiles, and 100,000 posts over 200 visited channels, five pages
of 100 posts each, repeated for a second cycle (400 visits, 200,000 processed
posts). Every fifth message is a longer paragraph, interleaved with short
text/mentions, headings/task lists/quotes, fenced Swift code and formatted tables.
Forty snapshots append 50 additional posts. Parsing/snapshot preparation happens
off the main actor; the native window is 900 × 650 points and never brought forward.

Reported switch timing starts when the prepared snapshot reaches the native
controller, then includes apply, layout and the first cell materialization. It
excludes parsing/network and compositor presentation, so it is not click-to-visible
or retained-channel latency. Row samples separate actual render/measurement work
from cache hits. Burst timing measures synchronous snapshot application/layout,
not event-mailbox or run-loop hitch duration. Footprint is `task_info(TASK_VM_INFO)`
`phys_footprint` for the Swift test host, including fixtures and AppKit; it is not
MatterMac's standalone app footprint.

PostStore holds only the currently generated page. Consequently this run checks
native cache behavior under sustained churn, not the production session retention
coordinator or a multi-hour soak. It does not cover images, search, multiple servers,
input latency, file transfers, offline recovery, or display refresh performance.
Normal package test runs skip the benchmark unless `MM_BENCHMARKS=1`.

## Measurements

Measured 2026-09-25, rendering source through `425a1b7`, with this benchmark harness.
No explicit warm-up is excluded; first-use costs remain in the distribution. The
final run took 75.148 seconds and passed every cache-bound assertion.

| Metric | Samples | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Prepared channel snapshot apply/layout | 400 | 9.654 ms | 12.962 ms | 35.065 ms |
| Cold row render/layout | 20,000 | 0.111 ms | 0.402 ms | 3.007 ms |
| 50-post snapshot burst apply/layout | 40 | 2.770 ms | 6.987 ms | 12.143 ms |

All row samples were cache misses. No final-run burst application exceeded 16.7 ms.
A preliminary one-cycle run had one 22.851 ms burst out of 20, so a zero-hitch claim
would be unjustified. It recorded switch p95 10.657 ms and row p95 0.407 ms.

Physical footprint baseline was 22,201,280 bytes. At each subsequent 50 channel
visits: 51,758,040; 54,526,936; 57,836,504; 62,063,576; 63,243,224; 64,029,656;
64,701,400; 65,323,992 bytes. The second cycle grew another 3,260,416 bytes; growth
slowed but this short run does **not** establish a stable plateau or absence of leaks.
Final rendered-text cache accounting: 4,185,692 bytes (4 MiB limit), row-layout cache:
570,880 bytes (4 MiB limit). New native table/decorated blocks are explicitly charged
512 estimated bytes each, once per distinct retained block, in addition to text.

No broad performance rewrite was justified by these measurements. Longer app-level
soaks, genuine presentation/input latency, images and network-backed session
retention measurements remain necessary before claiming the SPEC acceptance gates.
Evidence logs for this run: `/tmp/mm-render-benchmark2.log`; preliminary run:
`/tmp/mm-render-benchmark.log`. Normal tests and test compilation passed without
compiler warnings; the benchmark itself emitted no runtime warnings.
