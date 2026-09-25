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
