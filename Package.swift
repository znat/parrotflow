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
        // Three lines of Objective-C, for the one thing Swift cannot do:
        // catch an NSException. See Sources/ObjCExceptions/include.
        .target(
            name: "ObjCExceptions",
            path: "Sources/ObjCExceptions"
        ),
        .executableTarget(
            name: "ParrotFlow",
            dependencies: ["Yams", "FluidAudio", "ObjCExceptions"],
            path: "Sources/ParrotFlow"
        )
    ]
)
