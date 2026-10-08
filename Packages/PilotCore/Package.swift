// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PilotCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PilotCore", targets: ["PilotCore"])
    ],
    targets: [
        .target(name: "PilotCore"),
        .testTarget(name: "PilotCoreTests", dependencies: ["PilotCore"])
    ]
)
