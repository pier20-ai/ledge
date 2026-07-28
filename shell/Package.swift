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
            dependencies: ["LedgeShellCore"],
            resources: [
                // `.copy`, not `.process`: the editor bundle is already built
                // (scripts/build-editor.sh) and its index.html references its
                // siblings by relative path. `.process` flattens the directory
                // and renames assets, which breaks those references and — worse
                // — breaks them only in a release build.
                .copy("Resources/editor"),
            ]
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
