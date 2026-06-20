// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MyFinder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MyFinder", targets: ["MyFinder"])
    ],
    targets: [
        .executableTarget(
            name: "MyFinder",
            path: "Sources/MyFinder",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
