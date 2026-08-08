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
        // The icon generator. It depends on SuperclipKit rather than carrying
        // its own copy of the mark, so the app icon and the menu bar icon are
        // the same drawing by construction and cannot drift apart.
        .executableTarget(
            name: "IconGen",
            dependencies: ["SuperclipKit"],
            path: "Sources/IconGen",
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
