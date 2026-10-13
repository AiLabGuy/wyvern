// swift-tools-version:5.9
// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "App1",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "App1Core", targets: ["App1Core"]),
        .executable(name: "App1", targets: ["App1"]),
        .executable(name: "App1UITestRunner", targets: ["App1UITestRunner"]),
        .executable(name: "App1Bench", targets: ["App1Bench"]),
        .executable(name: "App1Diag", targets: ["App1Diag"]),
        .executable(name: "App1UpdateSigner", targets: ["App1UpdateSigner"]),
        .executable(name: "App1UpdateVerify", targets: ["App1UpdateVerify"])
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
            name: "App1Core",
            path: "Sources/App1Core",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "App1",
            dependencies: [
                "App1Core",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/App1",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "App1CoreTests",
            dependencies: ["App1Core"],
            path: "Tests/App1CoreTests",
            resources: [
                .copy("Fixtures")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "App1UITestRunner",
            path: "Sources/App1UITestRunner"
        ),
        .executableTarget(
            name: "App1Bench",
            dependencies: ["App1Core"],
            path: "Sources/App1Bench"
        ),
        .executableTarget(
            name: "App1Diag",
            dependencies: ["App1Core"],
            path: "Sources/App1Diag"
        ),
        .executableTarget(
            name: "App1UpdateSigner",
            dependencies: ["App1Core"],
            path: "Sources/App1UpdateSigner",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "App1UpdateVerify",
            dependencies: ["App1Core"],
            path: "Sources/App1UpdateVerify"
        )
    ],
    swiftLanguageVersions: [.v5]
)
