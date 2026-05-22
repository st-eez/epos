// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SteezFlow",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "SteezFlow", targets: ["SteezFlow"])
    ],
    targets: [
        .target(
            name: "SteezFlow",
            path: "Sources/SteezFlow"
        ),
        .testTarget(
            name: "SteezFlowTests",
            dependencies: ["SteezFlow"],
            path: "Tests/SteezFlowTests"
        )
    ]
)
