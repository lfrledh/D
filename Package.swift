// swift-tools-version: 6.0
import PackageDescription

// The new runtime has no MLX, UI, network, or model-weight dependency.
// Legacy Packages/* remain in the app until each backend is migrated and verified.
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
