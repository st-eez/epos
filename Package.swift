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
        ),
        .target(
            name: "EposEval",
            dependencies: ["Epos"],
            path: "Sources/EposMacApp",
            exclude: ["main.swift"]
        ),
        .testTarget(
            name: "EposEvalTests",
            dependencies: ["EposEval"],
            path: "Tests/EposEvalTests"
        )
    ]
)
