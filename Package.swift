// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ECCFocusQueue",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FocusQueueCore", targets: ["FocusQueueCore"]),
        .executable(name: "ECCFocusQueue", targets: ["ECCFocusQueue"])
    ],
    targets: [
        .target(name: "FocusQueueCore"),
        .executableTarget(
            name: "ECCFocusQueue",
            dependencies: ["FocusQueueCore"]
        ),
        .testTarget(
            name: "FocusQueueCoreTests",
            dependencies: ["FocusQueueCore"]
        )
    ]
)
