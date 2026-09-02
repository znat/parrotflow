// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ParrotFlow",
    // macOS 14 is FluidAudio's floor (CoreML + ANE requirements).
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
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
        // Three lines of Objective-C, for the one thing Swift cannot do:
        // catch an NSException. See Sources/ObjCExceptions/include.
        .target(
            name: "ObjCExceptions",
            path: "Sources/ObjCExceptions"
        ),
        .executableTarget(
            name: "ParrotFlow",
            dependencies: [
                "Yams", "FluidAudio", "ObjCExceptions",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/ParrotFlow"
        )
    ]
)
