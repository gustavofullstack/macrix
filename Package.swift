// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macuse-open",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macuse-open", targets: ["macuse-open"]),
    ],
    targets: [
        .executableTarget(
            name: "macuse-open",
            path: "Sources/macuse-open"
        ),
        .testTarget(
            name: "macuse-openTests",
            dependencies: ["macuse-open"],
            path: "Tests/macuse-openTests"
        ),
    ]
)
