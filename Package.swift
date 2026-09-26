// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopPet",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "DesktopPet",
            path: "Sources/DesktopPet"
        )
    ]
)
