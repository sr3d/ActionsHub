// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ActionsHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ActionsHub", path: "Sources/ActionsHub")
    ]
)
