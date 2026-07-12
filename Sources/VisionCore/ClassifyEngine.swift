import Foundation
import os

#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO

/// One classification label: a taxonomy identifier (unlocalized technical name — e.g.
/// "cat", "hotdog" — not for direct UI display, per `VNClassificationObservation`'s
/// header docs) plus its confidence.
public struct ClassificationResult: Sendable {
    public let identifier: String
    public let confidence: Double
}

/// All labels above the confidence threshold for one image, plus its physical dimensions
/// (mirrors `OCRResult`/`BarcodeScanResult`'s pairing of results with `imageWidth`/`imageHeight`).
public struct ClassificationScanResult: Sendable {
    public let labels: [ClassificationResult]
    public let imageWidth: Int
    public let imageHeight: Int
}

/// Vision-bound image classification (`classify`), wrapping `VNClassifyImageRequest`
/// (`VNClassifyImageRequestRevision2` — macOS 14.0+, "improved accuracy, reduced latency
/// and memory"; baseline 26.0 is well above that). 1,303-identifier taxonomy.
///
/// Unlike `VNDetectBarcodesRequest`/`VNRecognizeTextRequest`, Vision does *not* return only
/// actual detections here — `request.results` always carries all 1,303 taxonomy entries,
/// most at confidence ≈ 0 (verified: plan §2.6 Phase 0 spike, 2026-07-12). So this engine
/// (not just an incidental filter, as for barcode/ocr) applies `minConfidence` itself and
/// caps at `top`, or every call would return a 1,303-line response. Defaults (0.1 / 20) are
/// the spike's measured separation: synthetic (non-photographic) images topped out under
/// 0.1 confidence, while real photos' meaningful labels sat well above it.
///
/// **Every entry point is `async` — this is not optional.** Concurrent
/// `VNClassifyImageRequest.perform()` calls deadlock: reproduced directly with plain Swift
/// `Task` concurrency (13 concurrent `Task {}`s, each just calling `perform()` once, hang
/// indefinitely — killed after 90s at near-zero CPU, i.e. genuinely blocked, not slow; no
/// comparable issue exists for `BarcodeEngine`/`OCREngine`, which don't route through a
/// CoreML-backed model the same way). Neither an in-place `NSLock` nor
/// `DispatchQueue.sync` around `perform()` fixes it — both still park the calling
/// Swift-concurrency cooperative-pool thread while serialized work runs, and with enough
/// concurrent callers that starves the (small, fixed-size) cooperative pool, which itself
/// deadlocks. Routing the actual `perform()` call onto a dedicated serial `DispatchQueue`
/// via `.async` + a checked continuation — so the calling `Task` fully *suspends* (frees
/// its cooperative-pool thread) instead of *blocking* — is the only approach that resolved
/// it in isolation testing (same 13-way concurrency, all complete in well under 100ms).
/// This matters in production, not just tests: `macvis serve` (`HTTPServer`) spawns an
/// independent `Task` per accepted connection and can route concurrent `classify` requests
/// straight into this engine.
public enum ClassifyEngine {
    public static let defaultMinConfidence = 0.1
    public static let defaultTop = 20

    /// Clamp `--top` to a floor of 1 (never 0 or negative — a `--top 0` request still gets
    /// its single best label, not an artificially-forced-empty result). Pure logic, no
    /// Vision session — mirrors `QRGenerator.generate`'s `max(1, size ?? default)` clamp.
    public static func effectiveTop(_ top: Int?) -> Int {
        max(1, top ?? defaultTop)
    }

    /// Every `VNClassifyImageRequest` invocation in this process — both the real `classify`
    /// path and the `doctor` probe below — funnels through this one dedicated queue, so no
    /// two ever run concurrently (see the type doc for why that's required).
    private static let visionQueue = DispatchQueue(label: "mac-local-vision.classify")

    /// Runs `work` on `visionQueue` and suspends the caller (not blocks) until it completes.
    private static func runSerialized<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            visionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Real capability probe for `doctor` (see `OCREngine.textVisionAvailable` for the
    /// pattern this mirrors): does `VNClassifyImageRequest` actually execute here? Runs
    /// over a small blank image; memoized for the process lifetime. Note: this only checks
    /// that the request *executes* without throwing — it says nothing about whether the
    /// image classifies to anything meaningful (see the type doc: Vision always returns all
    /// 1,303 identifiers, so a "does it throw" probe is the same shape as barcode/OCR's even
    /// though classify's result *quality* on a blank image is itself near-zero confidence,
    /// not a throw). Routed through `visionQueue` like every other call here, so a `doctor`
    /// call racing an in-flight `classify` call can't hit the same deadlock.
    public static func classifyVisionAvailable() async -> Bool {
        if let cached = _probe.withLock({ $0 }) { return cached }
        let ok = (try? await runSerialized(probe)) ?? false
        _probe.withLock { $0 = ok }
        return ok
    }

    private static let _probe = OSAllocatedUnfairLock(initialState: Optional<Bool>.none)

    private static func probe() throws -> Bool {
        guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage() else { return false }
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([makeRequest()])
        return true
    }

    private static func makeRequest() -> VNClassifyImageRequest {
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        return request
    }

    // MARK: - classify (path + data)

    public static func classify(
        path: String,
        minConfidence: Double = defaultMinConfidence,
        top: Int? = nil
    ) async throws -> ClassificationScanResult {
        let (cgImage, width, height) = try OCREngine.loadImage(path: path)
        return try await classifyCore(cgImage: cgImage, width: width, height: height,
                                      minConfidence: minConfidence, top: top)
    }

    public static func classify(
        data: Data,
        minConfidence: Double = defaultMinConfidence,
        top: Int? = nil
    ) async throws -> ClassificationScanResult {
        let (cgImage, width, height) = try OCREngine.loadImage(data: data)
        return try await classifyCore(cgImage: cgImage, width: width, height: height,
                                      minConfidence: minConfidence, top: top)
    }

    private static func classifyCore(
        cgImage: CGImage, width: Int, height: Int,
        minConfidence: Double, top: Int?
    ) async throws -> ClassificationScanResult {
        // Map to the Sendable ClassificationResult *inside* the closure, before crossing
        // back over the queue boundary — VNClassificationObservation itself isn't Sendable.
        let results: [ClassificationResult] = try await runSerialized {
            let request = makeRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            return (request.results ?? []).map {
                ClassificationResult(identifier: $0.identifier, confidence: Double($0.confidence))
            }
        }

        let cap = effectiveTop(top)
        let labels = results
            .filter { $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(cap)
        return ClassificationScanResult(labels: Array(labels), imageWidth: width, imageHeight: height)
    }
}
#endif
