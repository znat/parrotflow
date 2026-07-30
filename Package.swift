// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ParrotFlow",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .executableTarget(
            name: "ParrotFlow",
            dependencies: ["Yams"],
            path: "Sources/ParrotFlow"
        )
    ]
)
