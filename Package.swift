// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tacho",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Tacho",
            path: "Sources/Tacho",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
