// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchWidget",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchWidget",
            path: "Sources/NotchWidget",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
