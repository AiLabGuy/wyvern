// swift-tools-version:5.9
// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "Wyvern",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "WyvernCore", targets: ["WyvernCore"]),
        .executable(name: "Wyvern", targets: ["Wyvern"]),
        .executable(name: "WyvernUITestRunner", targets: ["WyvernUITestRunner"]),
        .executable(name: "WyvernBench", targets: ["WyvernBench"]),
        .executable(name: "WyvernDiag", targets: ["WyvernDiag"]),
        .executable(name: "WyvernUpdateSigner", targets: ["WyvernUpdateSigner"]),
        .executable(name: "WyvernUpdateVerify", targets: ["WyvernUpdateVerify"])
    ],
    dependencies: [
        // SwiftTerm 1.11.2. Commit b1262db5b6bea699a8260a8c66999436c508ca56.
        // GitHub tag archive sha256 dd4bd355903a900c0af66095c6c8d3cb5ec94cc4e6358af6e4aac033fce351b7
        // (https://github.com/migueldeicaza/SwiftTerm/archive/refs/tags/v1.11.2.tar.gz).
        // Pinned below 1.12 because 1.19.0's Metal shader (Shaders.metal) failed to compile on the build Mac.
        // 1.11.2 has no Metal files. The library product is linked. The command-line targets,
        // the benchmark target, and the docc plugin are not. The package tools version is 5.9.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2")
    ],
    targets: [
        .target(
            name: "WyvernCore",
            path: "Sources/WyvernCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "Wyvern",
            dependencies: [
                "WyvernCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Wyvern",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "WyvernCoreTests",
            dependencies: ["WyvernCore"],
            path: "Tests/WyvernCoreTests",
            resources: [
                .copy("Fixtures")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "WyvernUITestRunner",
            path: "Sources/WyvernUITestRunner"
        ),
        .executableTarget(
            name: "WyvernBench",
            dependencies: ["WyvernCore"],
            path: "Sources/WyvernBench"
        ),
        .executableTarget(
            name: "WyvernDiag",
            dependencies: ["WyvernCore"],
            path: "Sources/WyvernDiag"
        ),
        .executableTarget(
            name: "WyvernUpdateSigner",
            dependencies: ["WyvernCore"],
            path: "Sources/WyvernUpdateSigner",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "WyvernUpdateVerify",
            dependencies: ["WyvernCore"],
            path: "Sources/WyvernUpdateVerify"
        )
    ],
    swiftLanguageVersions: [.v5]
)
