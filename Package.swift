// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quill",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Quill",
            path: "Sources/Quill",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
