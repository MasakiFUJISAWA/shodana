// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Shodana",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Shodana", targets: ["Shodana"])
    ],
    targets: [
        .executableTarget(
            name: "Shodana",
            path: "Sources/Shodana",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("NetFS")
            ]
        )
    ]
)
