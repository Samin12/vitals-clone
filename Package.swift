// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VitalsClone",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "VitalsClone", path: "Sources/VitalsClone", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
