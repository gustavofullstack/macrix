// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macrix",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macrix", targets: ["macrix"]),
    ],
    targets: [
        .executableTarget(
            name: "macrix",
            path: "Sources/macrix"
        ),
        .testTarget(
            name: "macrixTests",
            dependencies: ["macrix"],
            path: "Tests/macrixTests"
        ),
    ]
)
