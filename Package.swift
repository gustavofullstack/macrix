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
            path: "Sources/macrix",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist so TCC accepts the mic/speech requests of a bare CLI binary.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/macrix/Info.plist"]),
            ]
        ),
        .testTarget(
            name: "macrixTests",
            dependencies: ["macrix"],
            path: "Tests/macrixTests"
        ),
    ]
)
