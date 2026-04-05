// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-metal-renderer",
    platforms: [
        .macOS(.v14)
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
