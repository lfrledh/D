// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TextInference",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TextInference", targets: ["TextInference"]),
    ],
    dependencies: [
        .package(name: "Core", path: "../Core"),
        .package(name: "ModelLoading", path: "../ModelLoading"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.15.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.1.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "2.30.6")),
    ],
    targets: [
        .target(
            name: "TextInference",
            dependencies: [
                "Core",
                "ModelLoading",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/TextInference"
        ),
        .testTarget(
            name: "TextInferenceTests",
            dependencies: ["TextInference"],
            path: "Tests/TextInferenceTests"
        ),
    ]
)
