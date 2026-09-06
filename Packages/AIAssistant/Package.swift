// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIAssistant", targets: ["AIAssistant"]),
    ],
    dependencies: [
        .package(name: "Core", path: "../Core"),
        .package(name: "ModelLoading", path: "../ModelLoading"),
        .package(name: "TextInference", path: "../TextInference"),
        .package(name: "ImageInference", path: "../ImageInference"),
    ],
    targets: [
        .target(
            name: "AIAssistant",
            dependencies: [
                "Core",
                "ModelLoading",
                "TextInference",
                "ImageInference",
            ],
            path: "Sources/AIAssistant"
        ),
        .testTarget(
            name: "AIAssistantTests",
            dependencies: ["AIAssistant"],
            path: "Tests/AIAssistantTests"
        ),
    ]
)
