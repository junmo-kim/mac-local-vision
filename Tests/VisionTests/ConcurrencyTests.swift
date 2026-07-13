#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import os
@testable import VisionCore

/// Concurrency regression suite for plan `2026-07-13-macvis-vision-concurrency-fix`.
///
/// Background: `VNImageRequestHandler.perform()` (and friends) blocks its calling thread
/// while internally dispatching to its own GCD queue. Concurrent Swift `Task`s calling it
/// directly can starve Swift concurrency's small, fixed-size cooperative thread pool —
/// every caller deadlocks (see `VisionSerialQueue`'s type doc for the full mechanism, first
/// diagnosed and fixed against `ClassifyEngine`/`VNClassifyImageRequest`). Every engine now
/// routes its `.perform()` calls through a dedicated `VisionSerialQueue`; this suite is the
/// regression test for that fix, built up incrementally as each engine was fixed (plan
/// Phase 2: OCR/Face below; Phase 3 adds Barcode/Document; Phase 4 adds DocumentOCR as a
/// safety confirmation, not a fix — see each phase's own commit).
///
/// **Phase 0 findings** (plan §Phase 0, this exact methodology, run against the
/// then-still-synchronous engines before this suite's fix landed):
/// - OCR (n=15) and Face (n=15) **genuinely deadlocked** — confirmed via external process
///   inspection (`ps`: 0.0% CPU, 5m46s/45s elapsed) after being killed, not via an in-process
///   timeout. That's a deliberate finding, not an oversight: when the cooperative pool is
///   *totally* exhausted, even a `Task.sleep`-based timeout racer can't fire, because
///   resuming that timer also needs a cooperative-pool thread that will never free up. So
///   the in-process timeout guard below is a best-effort fast-fail for *partial* regressions
///   (some, not all, pool threads exhausted) — it is not a guaranteed safety net against a
///   *total* deadlock reappearing. The actual guarantee is the fix itself (suspend, not
///   block); an external process-level timeout (as used in Phase 0 and in CI generally) is
///   still the backstop of last resort.
/// - Barcode and Document did **not** reproduce even at n=200 with much larger synthetic
///   images (3 escalating attempts: n=25/80/200). The fix is still applied to both — per
///   community documentation (Swift Forums "Cooperative pool deadlock when calling into an
///   opaque subsystem"), this is a general property of `VNImageRequestHandler.perform()`,
///   not conditional on having reproduced it for a specific request type on this machine.
/// - DocumentOCR (Swift-native `async` API, not `VNImageRequestHandler.perform()`) did not
///   reproduce, as expected — included here as a permanent safety confirmation, not because
///   it was changed.
@Suite("Vision engines — concurrency regression (all 5 engines route through VisionSerialQueue)",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Vision requests need a real session — hangs on headless CI runners; runs locally."))
struct ConcurrencyTests {
    static func writePNG(_ image: CGImage, tag: String) -> String {
        let path = NSTemporaryDirectory() + "macvis-concurrency-\(tag)-\(UUID().uuidString).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    static func renderTextFixture(_ text: String, width: Int = 480, height: Int = 140) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 56, nil),
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 30, y: 45)
        CTLineDraw(line, ctx)
        return writePNG(ctx.makeImage()!, tag: "ocr")
    }

    /// A blank (no face) fixture is enough for this suite's purpose — it only needs to
    /// exercise `.perform()` under concurrency, not actually find a face.
    static func renderBlankFixture(width: Int = 300, height: Int = 300, tag: String) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return writePNG(ctx.makeImage()!, tag: tag)
    }

    static func renderQRFixture(_ payload: String, moduleScale: CGFloat = 24) -> String {
        let result = try! QRGenerator.generate(text: payload, correctionLevel: "M", size: Int(moduleScale))
        let path = NSTemporaryDirectory() + "macvis-concurrency-barcode-\(UUID().uuidString).png"
        try! result.png.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func renderDocumentFixture(width: Int = 1600, height: Int = 2000) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let margin = 100
        ctx.fill(CGRect(x: margin, y: margin, width: width - 2 * margin, height: height - 2 * margin))
        return ctx.makeImage()!
    }

    /// Runs `concurrency` `Task`s of `body`, racing a `timeoutSeconds` wall-clock deadline —
    /// see the suite doc for why this guard is best-effort, not a total-deadlock guarantee.
    static func assertNoDeadlock(
        concurrency: Int, timeoutSeconds: Double, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async throws -> Void
    ) async {
        let completedBox = OSAllocatedUnfairLock(initialState: 0)
        let allCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { inner in
                        for _ in 0..<concurrency {
                            inner.addTask {
                                try await body()
                                completedBox.withLock { $0 += 1 }
                            }
                        }
                        for try await _ in inner {}
                    }
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(allCompleted, "timed out or threw before all \(concurrency) concurrent calls completed",
                sourceLocation: sourceLocation)
        #expect(completedBox.withLock { $0 } == concurrency, sourceLocation: sourceLocation)
    }

    @Test("OCR: 15 concurrent recognize() calls all complete (regression: used to deadlock)")
    func ocrConcurrencyDoesNotDeadlock() async throws {
        let path = Self.renderTextFixture("concurrency check")
        defer { try? FileManager.default.removeItem(atPath: path) }
        await Self.assertNoDeadlock(concurrency: 15, timeoutSeconds: 20) {
            _ = try await OCREngine.recognize(path: path)
        }
    }

    @Test("Face: 15 concurrent detectFacePrints() calls all complete (regression: used to deadlock)")
    func faceConcurrencyDoesNotDeadlock() async throws {
        let path = Self.renderBlankFixture(tag: "face")
        defer { try? FileManager.default.removeItem(atPath: path) }
        await Self.assertNoDeadlock(concurrency: 15, timeoutSeconds: 20) {
            _ = try await FaceEngine.detectFacePrints(path: path)
        }
    }

    @Test("Barcode: 25 concurrent detect() calls all complete (preventive — did not reproduce a deadlock even at n=200 in Phase 0)")
    func barcodeConcurrencyDoesNotDeadlock() async throws {
        let path = Self.renderQRFixture("concurrency-check-payload")
        defer { try? FileManager.default.removeItem(atPath: path) }
        await Self.assertNoDeadlock(concurrency: 25, timeoutSeconds: 20) {
            _ = try await BarcodeEngine.detect(path: path)
        }
    }

    @Test("Document: 25 concurrent detectBounds() calls all complete (preventive — did not reproduce a deadlock even at n=200 in Phase 0)")
    func documentConcurrencyDoesNotDeadlock() async throws {
        let img = Self.renderDocumentFixture()
        let path = Self.writePNG(img, tag: "document")
        defer { try? FileManager.default.removeItem(atPath: path) }
        await Self.assertNoDeadlock(concurrency: 25, timeoutSeconds: 20) {
            _ = try await DocumentEngine.detectBounds(path: path)
        }
    }
}
#endif
