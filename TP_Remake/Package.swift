// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TPRemake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TPRemake", path: "Sources/TPRemake"),
        .testTarget(name: "TPRemakeTests", dependencies: ["TPRemake"], path: "Tests/TPRemakeTests"),
    ]
)
