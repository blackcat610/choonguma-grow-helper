// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ChoongumaGrowHelper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ChoongumaGrowHelper", targets: ["ChoongumaGrowHelper"])
    ],
    targets: [
        .executableTarget(
            name: "ChoongumaGrowHelper",
            path: "Sources/ChoongumaGrowHelper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
