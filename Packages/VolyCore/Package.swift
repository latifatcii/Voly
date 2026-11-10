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
        .library(name: "VolyHost", targets: ["VolyHost"]),
    ],
    targets: [
        .target(name: "VolyCodables", path: "Sources/VolyCodables"),
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
        .target(
            name: "VolyHost",
            dependencies: ["VolyProtocol", "VolyModels"],
            path: "Sources/VolyHost"
        ),
        // macOS command-line client for scripting the simulator integration
        // and agents end to end (see scripts/integration-test.sh).
        .executableTarget(
            name: "volyctl",
            dependencies: ["VolyHost", "VolyProtocol", "VolyModels"],
            path: "Sources/volyctl"
        ),
        .testTarget(
            name: "VolyCoreTests",
            dependencies: ["VolyAgent", "VolyProtocol", "VolyModels", "VolyCodables"],
            path: "Tests/VolyCoreTests"
        ),
        .testTarget(
            name: "VolyHostTests",
            dependencies: ["VolyHost"],
            path: "Tests/VolyHostTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
