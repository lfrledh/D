// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        .package(name: "Core", path: "../Core"),
        .package(name: "TextInference", path: "../TextInference"),  // 添加依赖
        .package(name: "ImageInference", path: "../ImageInference"), // 新增依赖
    ],
    targets: [
        .target(
            name: "UI",
            dependencies: ["Core", "TextInference", "ImageInference"],
            path: "Sources/UI"
        ),
        .testTarget(
            name: "UITests",
            dependencies: ["UI"],
            path: "Tests/UITests"
        ),
    ]
)
