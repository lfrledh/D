// swift-tools-version: 6.0
import PackageDescription

// Workbench application services and views. Inference implementation is injected by the app.
let package = Package(
    name: "UI",
    platforms: [.macOS("26.0")],
    products: [.library(name: "UI", targets: ["UI"]),
               .library(name: "DWorkbench", targets: ["DWorkbench"])],
    dependencies: [.package(name: "DPlatform", path: "../.."),
        .package(name: "DMCPSDK", path: "../../Vendor/mcp-swift-sdk"),
        .package(url: "https://github.com/microsoft/SwiftStreamingMarkdown", revision: "5f7c04e0558df6146f90d482edb62cb456986bda"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d")],
    targets: [
        .target(name: "DWorkbench", dependencies: [.product(name: "DInference", package: "DPlatform"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "MCP", package: "DMCPSDK")],
                resources: [.process("Models/Resources")]),
        .target(name: "UI", dependencies: ["DWorkbench", .product(name: "DInference", package: "DPlatform"),
                .product(name: "SwiftStreamingMarkdown", package: "SwiftStreamingMarkdown")],
                resources: [.process("Resources/Localization"), .copy("Resources/Chat-Third-Party-Notices.txt"), .copy("Resources/Mermaid")]),
        .testTarget(name: "DWorkbenchTests", dependencies: ["DWorkbench", .product(name: "DRuntime", package: "DPlatform")]),
        .testTarget(name: "UITests", dependencies: ["UI", "DWorkbench"]),
        .testTarget(name: "ModelLibraryTests", dependencies: ["DWorkbench", .product(name: "DInference", package: "DPlatform")]),
    ],
    swiftLanguageModes: [.v6]
)
