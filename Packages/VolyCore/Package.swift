// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolyCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "VolyCore", targets: ["VolyProtocol", "VolyModels", "VolyCodables"]),
        .library(name: "VolyAgent", targets: ["VolyAgent"]),
    ],
    targets: [
        .target(
            name: "VolyCodables",
            path: "Sources/VolyCodables"
        ),
        .target(
            name: "VolyModels",
            dependencies: ["VolyCodables"],
            path: "Sources/VolyModels"
        ),
        .target(
            name: "VolyProtocol",
            dependencies: ["VolyModels", "VolyCodables"],
            path: "Sources/VolyProtocol"
        ),
        .target(
            name: "VolyAgent",
            dependencies: ["VolyProtocol", "VolyModels", "VolyCodables"],
            path: "Sources/VolyAgent"
        ),
        .testTarget(
            name: "VolyCoreTests",
            dependencies: ["VolyAgent", "VolyProtocol", "VolyModels", "VolyCodables"],
            path: "Tests/VolyCoreTests"
        ),
    ]
)
