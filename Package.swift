// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SteezFlow",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "SteezFlow", targets: ["SteezFlow"]),
        .executable(name: "SteezFlowMacApp", targets: ["SteezFlowMacApp"])
    ],
    targets: [
        .target(
            name: "SteezFlow",
            path: "Sources/SteezFlow"
        ),
        .executableTarget(
            name: "SteezFlowMacApp",
            dependencies: ["SteezFlow"],
            path: "Sources/SteezFlowMacApp"
        ),
        .testTarget(
            name: "SteezFlowTests",
            dependencies: ["SteezFlow"],
            path: "Tests/SteezFlowTests"
        )
    ]
)
