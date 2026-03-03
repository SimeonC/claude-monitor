// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ClaudeMonitorCore",
            path: "Sources/ClaudeMonitorCore"
        ),
        .executableTarget(
            name: "ClaudeMonitor",
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
