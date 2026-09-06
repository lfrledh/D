// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImageInference",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImageInference", targets: ["ImageInference"]),
    ],
    dependencies: [
        .package(name: "Core", path: "../Core"),
        .package(name: "ModelLoading", path: "../ModelLoading"),  // 新增依赖
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.15.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.1.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", branch: "main"),
    ],
    targets: [
        .target(
            name: "ImageInference",
            dependencies: [
                "Core",
                "ModelLoading",  // 新增
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "StableDiffusion", package: "mlx-swift-examples"),
            ],
            path: "Sources/ImageInference"
        ),
        .testTarget(
            name: "ImageInferenceTests",
            dependencies: ["ImageInference"],
            path: "Tests/ImageInferenceTests"
        ),
    ]
)
