// swift-tools-version: 6.0
import PackageDescription

// Batch runner for Qwen3-ASR 0.6B (Core ML int8) using the last FluidAudio commit that still
// shipped the Qwen3 backend (2b6564251dc2, parent of 1708125 "remove experimental Qwen3 ASR backend").
let package = Package(
    name: "qwen3-runner",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../../vendor/FluidAudio-qwen3")],
    targets: [
        .executableTarget(
            name: "qwen3-runner",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio-qwen3")]
        )
    ]
)
