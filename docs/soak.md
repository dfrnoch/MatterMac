# Native application soak

`LiveSoakUITests` runs the actual built MatterMac.app test variant against the repository's
local Mattermost server at port 8065. It requires the existing Design Demo seed
(`LiveSeedDemoTests`) with an image and replies. It repeatedly changes channels,
opens channel members and a profile, opens/closes the image viewer, opens a thread,
then replaces it with message search. A five-second pause separates cycles. No posts
or account settings are changed by this test.

Use an exclusive foreground automation lane: other tests or user interaction can
move focus and invalidate this UI workload. The target app is identified by its exact
bundle URL, and UI-test launch flags prevent restoring/saving real Keychain accounts.
Credentials come only from the ignored local environment, never command-line values.

```sh
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMacUITests \
  -configuration Release -derivedDataPath build SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG build-for-testing
set -a
. ./.local/test-server.env
set +a
export TEST_RUNNER_MM_LIVE_SOAK=1
export TEST_RUNNER_MM_SOAK_SECONDS=7200
export TEST_RUNNER_MM_SOAK_IDLE_SECONDS=300
export TEST_RUNNER_MM_SOAK_APP_PATH="$PWD/build/Build/Products/Release/MatterMac.app"
export TEST_RUNNER_MM_TEST_ALICE_PASSWORD="$MM_TEST_ALICE_PASSWORD"
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMacUITests \
  -configuration Release -derivedDataPath build SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG -parallel-testing-enabled NO \
  -only-testing:MatterMacUITests/LiveSoakUITests \
  -maximum-test-execution-time-allowance 10000 test-without-building
```

For a smoke run, set duration to 120 and idle seconds to 5. A full five-minute idle
phase follows an additional 30-second settling pause. Duration defaults to two
hours and is capped at six. At most 1,024 numeric samples are retained by the test.
The `native-app-soak-numeric-samples` XCTest attachment records phase, uptime,
elapsed time and cycle counts. The `active-start` marker separates the complete idle
interval from the repeated workload, whose final cycle can finish after the requested
deadline. Requested active duration includes the five-second pauses between cycles. Run the standalone Swift sampler in a second terminal
before launching the test (the XCUITest runner itself receives EPERM when attempting
cross-process resource sampling):

```sh
swift Tools/NativeSoakSampler.swift "$PWD/build/Build/Products/Release/MatterMac.app" 7800 > build/soak-resources.csv
```

The sampler waits up to three minutes for that exact app URL and exits when its PID
terminates. It records cumulative CPU seconds, physical footprint, RSS and a descriptor
count estimate every ten seconds (-1 when unavailable). Monotonic uptime aligns the resource CSV with the
XCTest phase attachment. CPU times are converted from Mach absolute ticks with
`mach_timebase_info`, following [XNU’s task resource accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).
`proc_pid_rusage` samples the app PID, not the test runner. CPU percent
for an interval is 100 × change in CPU seconds / change in elapsed seconds. RSS and
physical footprint are separate metrics; do not add them together. The sample peak
is the peak observed at checkpoints, not a continuous high-water measurement.

The commands use Release optimization with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`
solely to enable development-only loopback and Keychain-isolation flags in
`AppComposition.swift` (currently the only runtime `#if DEBUG` site). Report this
exact optimized test variant, not an unmodified Release build. For a quicker Debug
smoke, change the configuration and app path to Debug. Neither variant certifies
minimum-OS behavior. It exercises a fixed mixed-content fixture, not a large account,
and cannot inspect internal cache/task budgets across the process boundary. A shown
Reconnect button is exercised, but a stable-server run with zero reconnects does not
prove recovery. Forced recovery and internal budget assertions require the separate
live native session tests. An official browser peer is a separate interoperability
gate. Record actual duration, cycles, failures and numeric results in progress.md;
building this harness or passing the smoke is not multi-hour-soak evidence.

Before and after sampling, the tool records metadata for Caches, Preferences, Saved
Application State and HTTPStorages paths owned by the app, under both host Library
(root 0) and the app sandbox's Data/Library (root 1). Path indices 0–3 follow that
order. Only existence, regular-file count, total bytes, latest modification time and
access/traversal errors are recorded; child names are not printed. Separately, up to
1 MiB of the app preference plist is read to compare the single native geometry
key `NSSplitView Subview Frames main, SidebarNavigationSplitView` in each root.
The comma is part of that key. Only valid/changed flags are printed, never its value or hash.
Each traversal is capped at 10,000 entries. These snapshots can detect changes in those
paths, but cannot establish that no transient writes or writes elsewhere occurred.
They are not a replacement for a privileged filesystem syscall audit.

## Measured baseline — September 25, 2026

Source `fe5c06e` (runtime `5af680b`), Release optimization with the development
flags described above, Apple M1 Pro / 16 GiB / macOS 27.0 / Xcode 27.0. This used
the fixed Design Demo fixture on local Mattermost 11.11.1, not a large production
account. Display refresh was not fixed. The run completed **252 cycles** with no
workflow assertion failures: **7,223.092 seconds active** after **300.008 seconds
idle**, plus setup. There were 757 external resource samples.

| Measurement | Baseline result |
| --- | --- |
| Idle physical footprint, median | 79.75 MiB |
| Idle CPU, one-core percentage | 0.0311% over the 290.122-second sampled interval inside the idle phase |
| Active footprint, sampled peak | 154.91 MiB |
| Consecutive 30-minute active medians | 104.33 / 114.20 / 125.64 / 136.34 MiB |
| First / last five-minute active medians | 99.67 / 140.95 MiB |
| Active CPU, one-core percentage | 15.636%, including UI automation and profiling interruptions |
| File descriptors | 45 throughout |

This **failed memory acceptance**: idle exceeded the proposed 70 MiB target,
active exceeded 140 MiB, and the run showed sustained growth rather than a plateau.
Content-free heap inspection found `TimelineRowView` counts growing from **810 to
1,458**, while the main conversation, timeline and composer controllers remained
at one each. Native KVO dependencies grew with the rows. The custom row type never
assigned its declared reuse identifier; `2d3e831` fixes that. A local scrolling
regression reproduced live rows growing to 220 against a 22-row bound without the
assignment, then passed with it restored. The final app requires a separate patched
workload measurement; this baseline is not evidence for that newer binary.

Profiler interruptions were `vmmap -summary` around 02:33:12 UTC, a content-free
fork-corpse leak scan at 02:44:56–02:45:03, a heap summary at 02:53:15–02:53:23,
and final heap/vmmap summaries at 03:45:02–03:45:14. The leak scan found only 63,968
unreachable bytes, mostly native menu objects; it did not account for the reachable
row growth. No allocation contents were printed. The sampled peak above differs
from the 155.5 MiB lifetime peak reported by the final vmmap snapshot.

Both storage roots reported the correct native geometry key unchanged and valid.
The existing 994-byte preference plist retained its size and modification time;
the other sampled paths remained absent. This is scoped evidence, not proof of
no transient or unrelated filesystem writes. Raw local artifacts are
`/tmp/mattermac-soak-final.xcresult`, `/tmp/mattermac-soak-final-resources.csv`, and
`/tmp/mattermac-soak-baseline-summary.json`.

## Patched validation limit

The final runtime `b94c7df` includes the row-reuse correction plus the late
notification, sending and navigation fixes. Its combined live/Keychain package run
passed 428 reported tests, and hosted CI passed. A 15-minute patched actual-app
comparison was prepared but **not run**: macOS automatically locked, and XCUITest
could not activate the application. `ioreg` reported
`CGSSessionScreenIsLocked=Yes`. The final UI suite was stopped after that activation
failure; it is not a passing run. The earlier 13-enabled-test UI pass belongs to
the pre-fix runtime, as recorded in progress.md.

The native scrolling regression establishes that the identifier fixes excessive
live row retention in that fixture. It does not establish the corrected app's
whole-process memory plateau, startup/input latency, or a two-hour patched soak.
Repeat the commands above from an unlocked desktop before claiming those gates.

As a narrower check, the native scrolling fixture ran **1,000 cycles in 45.014
seconds** while locked, keeping weakly tracked live rows within twice the observed
visible viewport throughout, with no issues or warnings. Only its loop count was
temporarily changed from 20 to 1,000; the original source and worktree were restored
afterward. Command: `swift test --package-path Packages/MatterMacKit --filter
scrollingKeepsNativeRowRetentionBounded`; log `/tmp/mm-row-retention-1000.log`.
This is a focused AppKit retention stress test, not a whole-app memory measurement.
