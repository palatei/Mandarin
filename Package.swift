// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mandarin",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Mandarin", path: "Sources/Mandarin")
    ],
    swiftLanguageModes: [.v5]
)
