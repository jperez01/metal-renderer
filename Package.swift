// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-metal-renderer",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "swift-metal-renderer",
            path: ".",
            sources: ["src"],
            resources: [
                .process("shaders")
            ]
        )
    ]
)
