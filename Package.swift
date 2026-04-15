// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchPilot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchPilot",
            path: "Sources/NotchPilot"
        )
    ]
)
