// swift-tools-version: 6.0
import PackageDescription

// Keep the Metal toolchain and remote dependencies out of the portable runtime package.
let package = Package(
    name: "DMLXIntegration",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DMLXBackend", targets: ["DMLXBackend"]),
        .executable(name: "d-infer", targets: ["DInferenceCLI"]),
        .executable(name: "mlx-allocation-probe", targets: ["MLXAllocationProbe"]),
    ],
    dependencies: [
        .package(name: "DPlatform", path: "../.."),
        .package(path: "../../Vendor/mlx-swift"),
        .package(path: "../../Vendor/flux2-swift"),
        .package(path: "../../Vendor/mlx-swift-lm"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.8"),
        .package(url: "https://github.com/huggingface/swift-jinja.git",
                 exact: "2.3.2"),
    ],
    targets: [
        .target(name: "DMLXBackend", dependencies: [
            .product(name: "DInference", package: "DPlatform"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "Flux2", package: "flux2-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "Jinja", package: "swift-jinja"),
        ], resources: [.process("Resources")]),
        .executableTarget(name: "DInferenceCLI", dependencies: [
            "DMLXBackend",
            .product(name: "DInference", package: "DPlatform"),
            .product(name: "DRuntime", package: "DPlatform"),
        ]),
        // Independent reproduction of an upstream allocator issue; deliberately no D dependency.
        .executableTarget(name: "MLXAllocationProbe", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .testTarget(name: "DMLXBackendTests", dependencies: [
            "DMLXBackend",
            .product(name: "DRuntime", package: "DPlatform"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "Flux2", package: "flux2-swift"),
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
