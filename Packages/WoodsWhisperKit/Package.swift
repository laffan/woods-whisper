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
    // No external dependencies on purpose: this package compiles on BOTH iOS and watchOS.
    // The watchOS-incompatible ML SDKs (FluidAudio, MLX) are added directly to the iOS app
    // target instead — see project.yml. The shared kit only defines the protocols those
    // implementations conform to.
    targets: [
        .target(name: "WoodsWhisperKit"),
        .testTarget(
            name: "WoodsWhisperKitTests",
            dependencies: ["WoodsWhisperKit"]
        )
    ]
)
