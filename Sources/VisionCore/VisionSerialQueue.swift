import Foundation

/// Reusable serial-queue-plus-continuation pattern that works around a specific Swift
/// concurrency hazard: `VNImageRequestHandler.perform()` (and the equivalent synchronous
/// entry points on Vision's other classic request types) is a *blocking* call that
/// internally dispatches to its own private GCD queue and waits on it. When multiple Swift
/// `Task`s call `perform()` concurrently, each one parks a thread from Swift concurrency's
/// small, fixed-size cooperative thread pool for the duration of that block — with enough
/// concurrent callers, the pool itself is exhausted (no thread left to resume anything,
/// including the very work `perform()` is waiting on) and every caller deadlocks.
///
/// This isn't specific to any one `VNRequest` subclass: the Swift Forums thread ["Cooperative
/// pool deadlock when calling into an opaque
/// subsystem"](https://forums.swift.org/t/cooperative-pool-deadlock-when-calling-into-an-opaque-subsystem/70685)
/// names Vision.framework directly and frames it as a general property of
/// `VNImageRequestHandler.perform()`, not a bug in one request type. It was first reproduced
/// and fixed here against `VNClassifyImageRequest` (`ClassifyEngine`): 13 concurrent
/// `Task {}`s, each just calling `perform()` once, hung indefinitely (killed after 90s at
/// near-zero CPU — genuinely blocked, not slow). Neither an in-place `NSLock` nor
/// `DispatchQueue.sync` around `perform()` fixes it — both still park the calling
/// Swift-concurrency cooperative-pool thread while serialized work runs, and that's exactly
/// what starves the pool. Routing the actual `perform()` call onto a dedicated serial
/// `DispatchQueue` via `.async` + a checked continuation — so the calling `Task` fully
/// *suspends* (freeing its cooperative-pool thread) instead of *blocking* — is the only
/// approach that resolved it in isolation testing (same 13-way concurrency, all complete in
/// well under 100ms).
///
/// Each Vision-bound engine (`ClassifyEngine`, `OCREngine`, `FaceEngine`, `BarcodeEngine`,
/// `DocumentEngine`) owns its own `VisionSerialQueue` instance rather than sharing one
/// process-wide queue: an in-flight `ocr` request should never block a concurrent `barcode`
/// request — only same-engine calls need to serialize against each other. (`DocumentOCREngine`
/// is the one exception — it wraps `RecognizeDocumentsRequest.perform(on:orientation:)`, a
/// Swift-native `async` Vision API rather than `VNImageRequestHandler.perform([VNRequest])`,
/// so it doesn't need this type at all; see its own concurrency regression test.)
public final class VisionSerialQueue: Sendable {
    private let queue: DispatchQueue

    public init(label: String) {
        self.queue = DispatchQueue(label: label)
    }

    /// Runs `work` on this queue's dedicated thread and suspends the caller — rather than
    /// blocking it — until `work` completes. This suspend-not-block behavior (freeing the
    /// calling `Task`'s cooperative-pool thread for the duration) is what actually avoids the
    /// deadlock described in the type doc; a lock or `.sync` around the same `work` would not.
    public func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
