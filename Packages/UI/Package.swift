// swift-tools-version: 6.0
import PackageDescription

// Workbench application services and views. Inference implementation is injected by the app.
let package = Package(
    name: "UI",
    platforms: [.macOS("26.0")],
    products: [.library(name: "UI", targets: ["UI"]),
               .library(name: "DWorkbench", targets: ["DWorkbench"])],
    dependencies: [.package(name: "DPlatform", path: "../..")],
    targets: [
        .target(name: "DWorkbench", dependencies: [.product(name: "DInference", package: "DPlatform")],
                resources: [.process("Models/Resources")]),
        .target(name: "UI", dependencies: ["DWorkbench", .product(name: "DInference", package: "DPlatform")]),
        .testTarget(name: "DWorkbenchTests", dependencies: ["DWorkbench", .product(name: "DRuntime", package: "DPlatform")]),
        .testTarget(name: "UITests", dependencies: ["UI", "DWorkbench"]),
        .testTarget(name: "ModelLibraryTests", dependencies: ["DWorkbench", .product(name: "DInference", package: "DPlatform")]),
    ],
    swiftLanguageModes: [.v6]
)
