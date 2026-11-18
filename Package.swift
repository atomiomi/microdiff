// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MicroDiff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MicroDiff", targets: ["MicroDiff"])
    ],
    targets: [
        // Pure logic: git parsing, diff model, trees, syntax. No AppKit.
        .target(name: "MicroDiffCore"),
        // AppKit views and app wiring. Everything here runs on the main actor.
        .target(
            name: "MicroDiffUI",
            dependencies: ["MicroDiffCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "MicroDiff", dependencies: ["MicroDiffUI"]),

        // Helpers shared by the test targets: temp folders and throwaway git repositories.
        .target(name: "MicroDiffTestSupport", dependencies: ["MicroDiffCore"], path: "Tests/MicroDiffTestSupport"),
        .testTarget(name: "MicroDiffCoreTests", dependencies: ["MicroDiffCore", "MicroDiffTestSupport"]),
        .testTarget(name: "MicroDiffUITests", dependencies: ["MicroDiffUI", "MicroDiffCore", "MicroDiffTestSupport"]),
        // Speed and memory budgets. Only meaningful in release: `scripts/perf.sh`.
        .testTarget(name: "MicroDiffPerfTests", dependencies: ["MicroDiffCore", "MicroDiffUI", "MicroDiffTestSupport"]),
    ]
)
