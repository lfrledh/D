// swift-tools-version: 6.0
import PackageDescription

// The new runtime has no MLX, UI, network, or model-weight dependency.
// The image workbench lives in Packages/UI; the app injects the MLX integration.
let package = Package(
    name: "DPlatform",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DInference", targets: ["DInference"]),
        .library(name: "DRuntime", targets: ["DRuntime"]),
    ],
    targets: [
        .target(name: "DInference"),
        .target(name: "DRuntime", dependencies: ["DInference"]),
        .testTarget(name: "DRuntimeTests", dependencies: ["DInference", "DRuntime"]),
    ],
    swiftLanguageModes: [.v6]
)
