// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Autoping",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (ICMP packets, scoring, statistics) – no AppKit, unit-tested.
        .target(name: "AutopingCore", path: "Sources/AutopingCore"),
        .executableTarget(
            name: "Autoping",
            dependencies: ["AutopingCore"],
            path: "Sources/Autoping"
        ),
        .testTarget(
            name: "AutopingCoreTests",
            dependencies: ["AutopingCore"],
            path: "Tests/AutopingCoreTests"
        ),
    ]
)
