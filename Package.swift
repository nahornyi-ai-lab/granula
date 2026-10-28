// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Granula",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Granula", targets: ["Granula"]),
    ],
    dependencies: [
        // Pinned to the revision measured in bench/ (Parakeet TDT v3 Ultra).
        // No traits: ASR only, without TTS, diarization or the NeMo text engine.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "2d6c42ca5f3accc0faf9fee9e0fff5b9b2cf6042",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "GranulaCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/GranulaCore"
        ),
        .executableTarget(
            name: "Granula",
            dependencies: ["GranulaCore"],
            path: "Sources/Granula"
        ),
        .testTarget(
            name: "GranulaCoreTests",
            dependencies: ["GranulaCore"],
            path: "Tests/GranulaCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
