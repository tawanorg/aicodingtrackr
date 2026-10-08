// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AICodingTrackr",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TrackrCore"),
        .executableTarget(name: "trackr", dependencies: ["TrackrCore"]),
        .executableTarget(name: "TrackrBar", dependencies: ["TrackrCore"]),
    ]
)
