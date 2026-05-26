// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Epos",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "Epos", targets: ["Epos"])
    ],
    targets: [
        .target(
            name: "Epos",
            path: "Sources/Epos"
        ),
        .testTarget(
            name: "EposTests",
            dependencies: ["Epos"],
            path: "Tests/EposTests"
        )
    ]
)
