// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ECCFocusQueue",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FocusQueueCore", targets: ["FocusQueueCore"]),
        .library(name: "FocusQueueMap", targets: ["FocusQueueMap"]),
        .executable(name: "focus-queue-map", targets: ["FocusQueueMapCLI"]),
        .executable(name: "ECCFocusQueue", targets: ["ECCFocusQueue"]),
        .executable(name: "focus-queue-session", targets: ["FocusQueueSession"])
    ],
    dependencies: [
        .package(url: "https://github.com/JohnSundell/Ink.git", exact: "0.6.0")
    ],
    targets: [
        .target(
            name: "FocusQueueCore",
            dependencies: [.product(name: "Ink", package: "Ink")]
        ),
        .executableTarget(
            name: "ECCFocusQueue",
            dependencies: ["FocusQueueCore", "FocusQueueMap"]
        ),
        .target(name: "FocusQueueMap", dependencies: ["FocusQueueCore"]),
        .executableTarget(name: "FocusQueueMapCLI", dependencies: ["FocusQueueMap", "FocusQueueCore"]),
        .testTarget(name: "FocusQueueMapTests", dependencies: ["FocusQueueMap", "FocusQueueCore"]),
        .executableTarget(
            name: "FocusQueueSession",
            dependencies: ["FocusQueueCore"]
        ),
        .testTarget(
            name: "FocusQueueCoreTests",
            dependencies: ["FocusQueueCore"]
        ),
        .testTarget(
            name: "ECCFocusQueueTests",
            dependencies: ["ECCFocusQueue", "FocusQueueCore", "FocusQueueMap"]
        )
    ]
)
