// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GlimmerIOS",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "GlimmerIOS",
            targets: ["GlimmerIOS"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Vendor/CLiteRTLM.xcframework"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: ["CLiteRTLM"],
            path: "Vendor/LiteRTLM"
        ),
        .target(
            name: "GlimmerIOS",
            dependencies: ["LiteRTLM"],
            path: "Sources/GlimmerIOS"
        )
    ]
)
