// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Topbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Topbar",
            path: "Sources/Topbar",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])],
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("ApplicationServices")]
        )
    ]
)
