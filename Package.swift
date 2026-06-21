// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Mihako",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mihako", targets: ["Mihako"])
    ],
    targets: [
        .executableTarget(
            name: "Mihako",
            path: "Sources/Mihako",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("NetFS")
            ]
        )
    ]
)
