// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotosSync",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    ],
    targets: [
        // Core library with testable logic
        .target(
            name: "PhotosSyncLib",
            path: "Sources/PhotosSyncLib",
            linkerSettings: [
                .linkedFramework("Photos"),
                .linkedFramework("Foundation"),
            ]
        ),
        // CLI executable
        .executableTarget(
            name: "photos-sync",
            dependencies: [
                "PhotosSyncLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/PhotosSync",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        // Tests (swift-testing built into Swift 6)
        .testTarget(
            name: "PhotosSyncTests",
            dependencies: [
                "PhotosSyncLib",
            ],
            path: "Tests/PhotosSyncTests"
        ),
    ]
)
