// swift-tools-version: 6.0
import PackageDescription

// MonitorCore is plain Foundation code, so it also builds and tests on Linux.
// Everything that talks to macOS (libproc, IOKit, AppKit, SwiftUI) is only
// declared when the package is built on a Mac.
var products: [Product] = []
var targets: [Target] = [
    .target(name: "MonitorCore"),
    .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
]

#if os(macOS)
products.append(.executable(name: "ProcessMonitor", targets: ["ProcessMonitor"]))
targets += [
    .target(
        name: "MonitorDarwin",
        dependencies: ["MonitorCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "ProcessMonitor",
        dependencies: ["MonitorCore", "MonitorDarwin"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "MonitorDarwinTests",
        dependencies: ["MonitorCore", "MonitorDarwin"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#endif

let package = Package(
    name: "ProcessMonitor",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
