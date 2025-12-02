// swift-tools-version:5.9
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
        .executableTarget(
            name: "photos-sync",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/PhotosSync",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("Photos"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
