// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BeaconHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BeaconHub",
            path: "Sources/BeaconHub"
        )
    ]
)
