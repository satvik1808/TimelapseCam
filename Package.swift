// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimelapseCam",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TimelapseCam",
            path: "Sources/TimelapseCam"
        )
    ]
)
