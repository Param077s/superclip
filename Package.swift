// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Superclip",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        // Everything the app is. Split out from the executable so it can be
        // imported by tests — top-level code in an executable target cannot be.
        .target(
            name: "SuperclipKit",
            path: "Sources/SuperclipKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Superclip",
            dependencies: ["SuperclipKit"],
            path: "Sources/Superclip",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SuperclipKitTests",
            dependencies: ["SuperclipKit"],
            path: "Tests/SuperclipKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
