// swift-tools-version: 6.2
import PackageDescription

// mac-local-vision — 100% Pure Swift single binary. No third-party dependencies.
// Deployment target is macOS 26 (Vision modes). The `ask` (multimodal) path is
// guarded behind @available(macOS 27, *) + runtime availability checks, so the
// same binary runs on 26 (Vision-only) and 27 (full `ask`).

// Optimize release builds for size. Every macvis invocation is a fresh, short-lived process
// whose latency is dominated by the Vision/FoundationModels frameworks and process launch,
// not by macvis's own thin Swift glue — so -Osize measured the same command latency as -O
// (doctor/ocr/find within noise) while shrinking the stripped binary ~15%. `.unsafeFlags` is
// fine here: macvis is a standalone executable, never a versioned SwiftPM dependency.
let releaseSizeOpt: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "mac-local-vision",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "macvis", targets: ["macvis"]),
    ],
    targets: [
        .executableTarget(
            name: "macvis",
            dependencies: ["VisionCore", "SemanticEngine"],
            swiftSettings: releaseSizeOpt
        ),
        // Vision-bound code (ocr/find/faces) + the pure logic it shares.
        .target(name: "VisionCore", swiftSettings: releaseSizeOpt),
        // `ask` abstraction: protocol + Mock (CI) + AFM (macOS 27, guarded).
        // Depends on VisionCore to reuse the shared image loader (page/scale/PDF/EXIF),
        // so `ask` honors the same input contract as ocr/find.
        .target(name: "SemanticEngine", dependencies: ["VisionCore"], swiftSettings: releaseSizeOpt),
        // Pure logic only — runs on any macOS runner (and conceptually Linux).
        .testTarget(name: "PureLogicTests", dependencies: ["VisionCore"]),
        // `ask` plumbing (MockEngine / AskOutcome / SemanticError / mapCallError) without a model.
        // VisionCore dependency: JSONSchemaMapperTests asserts on ServiceError/ExitCode directly.
        .testTarget(name: "SemanticEngineTests", dependencies: ["SemanticEngine", "VisionCore"]),
        // Tier ②: Vision-bound OCR/find against rendered fixtures (macOS-gated).
        .testTarget(name: "VisionTests", dependencies: ["VisionCore"]),
    ]
)
