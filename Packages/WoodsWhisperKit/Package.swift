// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WoodsWhisperKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "WoodsWhisperKit", targets: ["WoodsWhisperKit"])
    ],
    dependencies: [
        // On-device ASR (Parakeet TDT v3 via CoreML / ANE). iOS/iPadOS only at runtime.
        // Pinned loosely; verify the exact API against the resolved version in Xcode.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.4.0"),

        // On-device LLM (Gemma 3) via MLX. iOS/iPadOS only at runtime.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", branch: "main")
    ],
    targets: [
        .target(
            name: "WoodsWhisperKit",
            dependencies: [
                // FluidAudio and MLX are linked only into the iOS app target, not the watch.
                // They are referenced here via conditional compilation (#if canImport(...)).
                .product(name: "FluidAudio", package: "FluidAudio",
                         condition: .when(platforms: [.iOS])),
                .product(name: "MLXLLM", package: "mlx-swift-examples",
                         condition: .when(platforms: [.iOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples",
                         condition: .when(platforms: [.iOS]))
            ]
        ),
        .testTarget(
            name: "WoodsWhisperKitTests",
            dependencies: ["WoodsWhisperKit"]
        )
    ]
)
