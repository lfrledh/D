// swift-tools-version: 6.0
import PackageDescription

// An executable hardware experiment, deliberately outside the production backend.
let package = Package(
    name: "DFlux2Probe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "d-flux2-probe", targets: ["Flux2Probe"])],
    dependencies: [
        .package(url: "https://github.com/mzbac/flux2.swift", revision: "959a4af7c0721c800851c84431ffd3fa1f353f1f"),
        .package(path: "../../Vendor/mlx-swift"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.8"),
    ],
    targets: [
        .executableTarget(name: "Flux2Probe", dependencies: [
            .product(name: "Flux2", package: "flux2.swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXRandom", package: "mlx-swift"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
