// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LedgeShell",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LedgeShellCore", targets: ["LedgeShellCore"]),
        .executable(name: "LedgeShell", targets: ["LedgeShell"]),
    ],
    targets: [
        .target(
            name: "LedgeShellCore"
        ),
        .executableTarget(
            name: "LedgeShell",
            dependencies: ["LedgeShellCore"]
        ),
        .testTarget(
            name: "LedgeShellCoreTests",
            dependencies: ["LedgeShellCore"]
        ),
        .testTarget(
            name: "LedgeShellTests",
            dependencies: ["LedgeShell", "LedgeShellCore"]
        ),
    ]
)
