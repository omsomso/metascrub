// swift-tools-version: 6.2
import PackageDescription

// MetaScrub: view, edit and remove the metadata inside files (images, audio, video, PDFs, Office documents).
let package = Package(
    name: "MetaScrub",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "MetaScrubCore",
            path: "Sources/MetaScrubCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MetaScrub",
            dependencies: ["MetaScrubCore"],
            path: "Sources/MetaScrub",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MetaScrubCoreTests",
            dependencies: ["MetaScrubCore"],
            path: "Tests/MetaScrubCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
