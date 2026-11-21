// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "it2cli",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "it2", targets: ["it2"]),
        .executable(name: "it2-browser-mcp", targets: ["it2-browser-mcp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(
            name: "ProtobufRuntime",
            path: "Sources/ProtobufRuntime",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-fno-objc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "it2core",
            dependencies: [
                "ProtobufRuntime",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/it2core"
        ),
        .executableTarget(
            name: "it2",
            dependencies: [
                "it2core"
            ],
            path: "Sources/it2"
        ),
        .executableTarget(
            name: "it2-browser-mcp",
            dependencies: ["it2core", .product(name: "MCP", package: "swift-sdk")],
            path: "Sources/it2-browser-mcp"
        ),
        .testTarget(
            name: "BrowserMCPTests",
            dependencies: ["it2-browser-mcp", "it2core", .product(name: "MCP", package: "swift-sdk")],
            path: "Tests/BrowserMCPTests"
        ),
        .testTarget(
            name: "it2coreTests",
            dependencies: [
                "it2core",
                "ProtobufRuntime"
            ],
            path: "Tests/it2coreTests",
            resources: [
                // Recorded hook payloads for AgentHookScenarioTests.
                .copy("Resources/agent-hooks")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
