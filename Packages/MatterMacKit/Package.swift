// swift-tools-version: 6.2
// MatterMacKit: the local package behind the MatterMac app. Targets are split by
// responsibility (see docs/architecture.md). Zero external dependencies.
import PackageDescription

let strict: [SwiftSetting] = [
    // Swift 6 language mode already implies complete strict concurrency checking.
    // NonisolatedNonsendingByDefault is intentionally NOT enabled: nonisolated async
    // functions hop off the caller's actor, and CPU-heavy entry points are
    // additionally marked @concurrent so intent is explicit (docs/architecture.md).
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "MatterMacKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MatterMacUI", targets: ["MatterMacUI"]),
        .library(name: "MatterMacPlatform", targets: ["MatterMacPlatform"]),
        .library(name: "MatterMacCore", targets: ["MatterMacCore"]),
        // Linked by the app's embedded update installer XPC service as well.
        .library(name: "MatterMacUpdateSupport", targets: ["MatterMacUpdateSupport"]),
    ],
    targets: [
        .target(name: "MatterMacModels", swiftSettings: strict),
        .target(name: "MattermostAPI", dependencies: ["MatterMacModels"], swiftSettings: strict),
        .target(name: "MattermostRealtime", dependencies: ["MatterMacModels", "MattermostAPI"], swiftSettings: strict),
        .target(
            name: "MatterMacCore",
            dependencies: ["MatterMacModels", "MattermostAPI", "MattermostRealtime"],
            swiftSettings: strict
        ),
        // Update validation and installation shared with the installer XPC service:
        // Foundation and Security only.
        .target(name: "MatterMacUpdateSupport", swiftSettings: strict),
        .target(
            name: "MatterMacPlatform",
            dependencies: ["MatterMacModels", "MatterMacCore", "MatterMacUpdateSupport"],
            swiftSettings: strict
        ),
        .target(
            name: "MatterMacUI",
            dependencies: ["MatterMacModels", "MatterMacCore", "MatterMacPlatform"],
            swiftSettings: strict + [.defaultIsolation(MainActor.self)]
        ),
        // Test-only fakes (transport, clock, IDs, fixtures, event replay). Never linked
        // into the app target.
        .target(
            name: "TestSupport",
            dependencies: ["MatterMacModels", "MattermostAPI", "MattermostRealtime", "MatterMacCore"],
            swiftSettings: strict
        ),
        .testTarget(name: "ModelsTests", dependencies: ["MatterMacModels", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "APITests", dependencies: ["MattermostAPI", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "RealtimeTests", dependencies: ["MattermostRealtime", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "CoreTests", dependencies: ["MatterMacCore", "TestSupport"], swiftSettings: strict),
        .testTarget(
            name: "UITestsSupport",
            dependencies: ["MatterMacUI", "MatterMacPlatform", "TestSupport"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
