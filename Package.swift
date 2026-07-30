// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ParrotFlow",
    // macOS 14 is FluidAudio's floor (CoreML + ANE requirements).
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "ParrotFlow",
            dependencies: ["Yams", "FluidAudio"],
            path: "Sources/ParrotFlow"
        )
    ]
)
