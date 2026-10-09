// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ParrotFlow",
    // The slot gate reads fp16 logits, and Float16 conforms to
    // MLShapedArrayScalar only from macOS 15. See SlotProbe.swift.
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "ParrotFlow", targets: ["ParrotFlow"]),
        // The accessibility kit. It imports only AppKit and ApplicationServices,
        // so its folders can move to their own repository.
        .library(name: "AXKit", targets: ["AXKit"]),
        .executable(name: "axkit", targets: ["AXKitCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.7"),
        // Qwen3-Embedding, for the vectors the vocabulary stage compares. MLX
        // is the only local path that returns per-token states: Ollama's embed
        // endpoint returns one pooled vector per text, and pooling loses the
        // signal (6/8 correct per-token, 2/8 pooled).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        // The tokenizer only. `MLXHuggingFace` would bring the same thing behind
        // a macro, and swift-syntax with it; the two protocols it fills are four
        // methods, and the download is already `HubDownload`.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.24"),
    ],
    targets: [
        .target(name: "AXKit", path: "Sources/AXKit"),
        .executableTarget(name: "AXKitCLI", dependencies: ["AXKit"], path: "Sources/AXKitCLI"),
        .testTarget(name: "AXKitTests", dependencies: ["AXKit"], path: "tests/AXKitTests"),
        .executableTarget(
            name: "ParrotFlow",
            dependencies: [
                "Yams", "FluidAudio",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/ParrotFlow"
        )
    ]
)
