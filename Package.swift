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
        name: "OhmLabSimulationProtocol",
        path: "Sources/OhmLabSimulationProtocol"
    ),
    .target(
        name: "OhmLabCore",
        dependencies: [
            "OhmLabSimulationProtocol",
            .product(name: "NumericCoreOptimization", package: "Swift-NumericCore"),
        ],
        path: "Sources/OhmLabCore"
    ),
    .target(
        name: "OhmLabSimulationHost",
        dependencies: ["OhmLabSimulationProtocol", "OhmLabCore"],
        path: "Sources/OhmLabSimulationHost"
    ),
    .executableTarget(
        name: "OhmLab",
        dependencies: ["OhmLabCore", "OhmLabSimulationHost"],
        path: "Sources/OhmLab"
    ),
    .executableTarget(
        name: "OhmLabCLI",
        dependencies: ["OhmLabCore", "OhmLabSimulationHost"],
        path: "Sources/OhmLabCLI"
    ),
    .testTarget(
        name: "OhmLabTests",
        dependencies: ["OhmLabCore", "OhmLabSimulationHost", "OhmLabSimulationProtocol"],
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
        .library(name: "OhmLabSimulationProtocol", targets: ["OhmLabSimulationProtocol"]),
        .library(name: "OhmLabSimulationHost", targets: ["OhmLabSimulationHost"]),
        // Compatibility product retained for 2.x embedders that imported the
        // original core-backed platform product.
        .library(name: "OhmLabSimulationPlatform", targets: ["OhmLabCore"]),
        .executable(name: "OhmLab", targets: ["OhmLab"]),
        .executable(name: "ohm", targets: ["OhmLabCLI"]),
    ],

    // ── Dependencies ─────────────────────────────────────────────────────────
    dependencies: [
        // NumericCore 1.x is the stable Swift circuit/transport contract. Its
        // package supplies the reviewed Rust-NumericCore binary transport.
        .package(
            url: "https://github.com/hakkabon/Swift-NumericCore.git",
            .upToNextMajor(from: "1.0.0")
        ),
    ],

    // ── Targets ──────────────────────────────────────────────────────────────
    targets: packageTargets
)
