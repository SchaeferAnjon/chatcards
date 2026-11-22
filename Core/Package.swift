// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChatCardsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChatCardsCore", targets: ["ChatCardsCore"]),
    ],
    targets: [
        .target(name: "ChatCardsCore", path: "Sources/ChatCardsCore"),
        .testTarget(
            name: "ChatCardsCoreTests",
            dependencies: ["ChatCardsCore"],
            path: "Tests/ChatCardsCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
