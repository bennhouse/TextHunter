// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TextHunter",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "TextHunter", path: "Sources/TextHunter")
    ],
    swiftLanguageModes: [.v5]
)
