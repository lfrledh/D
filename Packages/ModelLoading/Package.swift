// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ModelLoading",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ModelLoading", targets: ["ModelLoading"]),
    ],
    dependencies: [
        .package(name: "Core", path: "../Core"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.15.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "2.30.6")),
    ],
    targets: [
        .target(
            name: "ModelLoading",
            dependencies: [
                "Core",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
            ],
            path: "Sources/ModelLoading"
        ),
        .testTarget(
            name: "ModelLoadingTests",
            dependencies: ["ModelLoading"],
            path: "Tests/ModelLoadingTests"
        ),
    ]
)
