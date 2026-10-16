// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NiimBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NiimBar", path: "Sources/NiimBar",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NiimBarTests", dependencies: ["NiimBar"], path: "Tests/NiimBarTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
