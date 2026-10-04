// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PurrCore",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PurrCoreCore", targets: ["PurrCoreCore"]),
        .executable(name: "PurrCore", targets: ["PurrCore"]),
        .executable(name: "purrcorectl", targets: ["PurrCoreCLI"])
    ],
    targets: [
        .target(
            name: "PurrCoreCore",
            path: "Sources/PurrCoreCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "PurrCore",
            dependencies: ["PurrCoreCore"],
            path: "Sources/PurrCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "PurrCoreCLI",
            dependencies: ["PurrCoreCore"],
            path: "Sources/PurrCoreCLI"
        ),
        .testTarget(
            name: "PurrCoreCoreTests",
            dependencies: ["PurrCoreCore"],
            path: "Tests/PurrCoreCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
