// swift-tools-version: 6.0
import PackageDescription

// Batch runner for Parakeet TDT 0.6B v3 (FluidAudio, Core ML). Loads the model once,
// transcribes every file from a TSV list and writes JSONL with per-file timings.
let package = Package(
    name: "parakeet-runner",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../../vendor/FluidAudio")],
    targets: [
        .executableTarget(
            name: "parakeet-runner",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "canary-runner",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
