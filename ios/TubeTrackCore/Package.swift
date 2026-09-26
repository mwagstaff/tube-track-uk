// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TubeTrackCore",
    platforms: [.iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "TubeTrackCore", targets: ["TubeTrackCore"]),
    ],
    targets: [
        .target(
            name: "TubeTrackCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TubeTrackCoreTests",
            dependencies: ["TubeTrackCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
