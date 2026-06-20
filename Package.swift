// swift-tools-version: 6.2
import PackageDescription

// mac-local-vision — 100% Pure Swift single binary. No third-party dependencies.
// Deployment target is macOS 26; the `ask` (multimodal) path is guarded behind a
// compile flag (-D MACVIS_ASK_IMAGE) + @available(macOS 27, *).
let package = Package(
    name: "mac-local-vision",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "VisionCore"),
        .target(name: "SemanticEngine", dependencies: ["VisionCore"]),
        .testTarget(name: "PureLogicTests", dependencies: ["VisionCore"]),
        .testTarget(name: "SemanticEngineTests", dependencies: ["SemanticEngine"]),
        .testTarget(name: "VisionTests", dependencies: ["VisionCore"]),
    ]
)
