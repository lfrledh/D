// swift-tools-version: 6.0
import PackageDescription

// Workbench application services and views. Inference implementation is injected by the app.
let package = Package(
    name: "UI",
    platforms: [.macOS("26.0")],
    products: [.library(name: "UI", targets: ["UI"])],
    dependencies: [.package(name: "DPlatform", path: "../..")],
    targets: [
        .target(name: "UI", dependencies: [.product(name: "DInference", package: "DPlatform")]),
        .testTarget(name: "UITests", dependencies: ["UI", .product(name: "DRuntime", package: "DPlatform")]),
    ],
    swiftLanguageModes: [.v6]
)
