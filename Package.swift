// swift-tools-version: 6.0
// OhmLab Package.swift
//
// Layout:
//   • OhmLabCore   — the platform-agnostic core: schematic model, connectivity,
//                    netlist parser/builder, the native MNA engine, diagnostics,
//                    persistence, and interchange. Shared by the app, the CLI,
//                    and the tests.
//   • OhmLab       — the SwiftUI app (a thin shell over OhmLabCore).
//   • ohm          — the headless/batch command-line front end.
//
// Engine:
//   • The built-in pure-Swift MNA engine is the full-coverage default.
//   • Swift-NumericCore is the independent linear/nonlinear production backend;
//     its binary transport is supplied by Rust-NumericCore.

import PackageDescription
let packageTargets: [Target] = [
    .target(
        name: "OhmLabCore",
        dependencies: [.product(name: "NumericCoreOptimization", package: "Swift-NumericCore")],
        path: "Sources/OhmLabCore"
    ),
    .executableTarget(
        name: "OhmLab",
        dependencies: ["OhmLabCore"],
        path: "Sources/OhmLab"
    ),
    .executableTarget(
        name: "OhmLabCLI",
        dependencies: ["OhmLabCore"],
        path: "Sources/OhmLabCLI"
    ),
    .testTarget(
        name: "OhmLabTests",
        dependencies: ["OhmLabCore"],
        path: "Tests/OhmLabTests",
        resources: [.copy("Fixtures")]
    ),
]

let package = Package(
    name: "OhmLab",

    // ── Supported platforms ──────────────────────────────────────────────────
    platforms: [
        .macOS(.v14),   // Charts, NavigationSplitView, Grid
        .iOS(.v17),     // iPadOS SwiftUI app target
    ],

    // ── Products ─────────────────────────────────────────────────────────────
    products: [
        .library(name: "OhmLabCore", targets: ["OhmLabCore"]),
        .library(name: "OhmLabSimulationPlatform", targets: ["OhmLabCore"]),
        .executable(name: "OhmLab", targets: ["OhmLab"]),
        .executable(name: "ohm", targets: ["OhmLabCLI"]),
    ],

    // ── Dependencies ─────────────────────────────────────────────────────────
    dependencies: [
        // NumericCore's circuit-analysis API is currently provisional and has
        // not reached a tagged release. Pin the reviewed revision exactly until
        // the API ships in a stable release, then move this to a semantic range.
        .package(
            url: "https://github.com/hakkabon/Swift-NumericCore.git",
            revision: "7318e8c470079b5255142d223750c251e9b2cfe7"
        ),
    ],

    // ── Targets ──────────────────────────────────────────────────────────────
    targets: packageTargets
)
