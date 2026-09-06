// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.15.0"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/Core"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
    ]
)
