// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodeMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ClaudeMonitorCore",
            path: "Sources/ClaudeMonitorCore"
        ),
        .executableTarget(
            name: "ClaudeCodeMonitor",
            dependencies: ["ClaudeMonitorCore"],
            path: "Sources/ClaudeMonitorApp",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Combine"),
            ]
        ),
        .testTarget(
            name: "ClaudeMonitorCoreTests",
            dependencies: ["ClaudeMonitorCore"],
            path: "Tests/ClaudeMonitorCoreTests"
        ),
    ]
)
