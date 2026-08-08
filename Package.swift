// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Superclip",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Superclip",
            path: "Sources/Superclip",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
