// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BG3ModManagerMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BG3ModManagerMac", targets: ["BG3ModManagerMac"])
    ],
    targets: [
        .executableTarget(
            name: "BG3ModManagerMac",
            path: "Sources/BG3ModManager"
        ),
        .testTarget(
            name: "BG3ModManagerTests",
            dependencies: ["BG3ModManagerMac"],
            path: "Tests/BG3ModManagerTests"
        )
    ]
)
