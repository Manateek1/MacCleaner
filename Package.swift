// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacCleaner", targets: ["MacCleaner"])
    ],
    targets: [
        .executableTarget(
            name: "MacCleaner",
            path: "MacCleaner",
            exclude: ["Assets.xcassets"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacCleanerTests",
            dependencies: ["MacCleaner"],
            path: "Tests/MacCleanerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
