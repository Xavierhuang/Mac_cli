// swift-tools-version:5.7
import PackageDescription

// LingCodeServer uses NWListener (Darwin-only) and isn't ported to Linux yet,
// so the `lingcode serve` subcommand and its package dep are gated on macOS.
// Linux CI evaluates this Package.swift on a Linux host, so #if os(macOS) is
// false there and the LingCodeServer path dep is skipped at resolution time.
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(path: "../LingCodeAgentCore"),
    .package(path: "../LingCodeACP"),
]
var lingcodeTargetDependencies: [Target.Dependency] = [
    "LingCodeIPC",
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
    .product(name: "LingCodeAgentCore", package: "LingCodeAgentCore"),
    .product(name: "LingCodeACP", package: "LingCodeACP"),
]
#if os(macOS)
packageDependencies.append(.package(path: "../LingCodeServer"))
lingcodeTargetDependencies.append(.product(name: "LingCodeServer", package: "LingCodeServer"))
#endif

let package = Package(
    name: "LingCodeCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Shared IPC protocol — the app side imports this too.
        .library(
            name: "LingCodeIPC",
            targets: ["LingCodeIPC"]
        ),
        // The `lingcode` terminal binary.
        .executable(
            name: "lingcode",
            targets: ["lingcode"]
        ),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "LingCodeIPC",
            dependencies: [],
            path: "Sources/LingCodeIPC"
        ),
        .executableTarget(
            name: "lingcode",
            dependencies: lingcodeTargetDependencies,
            path: "Sources/lingcode",
            resources: [
                // Bundles bridge.mjs + sdk-bundle.mjs alongside the binary so
                // `lingcode ask --provider claude` works without LingCode.app
                // installed. The symlink at Resources/agent-bridge points at
                // the canonical files in LingCode/agent-bridge so the in-app
                // path stays the source of truth.
                .copy("Resources/agent-bridge"),
            ]
        ),
        .testTarget(
            name: "LingCodeIPCTests",
            dependencies: ["LingCodeIPC"],
            path: "Tests/LingCodeIPCTests"
        ),
    ]
)
