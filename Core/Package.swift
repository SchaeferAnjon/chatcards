// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnkiLearnCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnkiLearnCore", targets: ["AnkiLearnCore"]),
    ],
    targets: [
        .target(name: "AnkiLearnCore", path: "Sources/AnkiLearnCore"),
        .testTarget(
            name: "AnkiLearnCoreTests",
            dependencies: ["AnkiLearnCore"],
            path: "Tests/AnkiLearnCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
