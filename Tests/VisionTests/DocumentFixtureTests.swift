#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import VisionCore

/// Tier ② (impl §2): exercise the real Vision document-segmentation + CoreImage
/// perspective-correction path against CIFilter/CoreText-rendered fixtures — no static
/// image assets in the repo, mirroring `OCRFixtureTests.renderFixture` and
/// `BarcodeFixtureTests.renderQRFixture`.
///
/// Phase 0 spike (plan §2.6) established that `VNDetectDocumentSegmentationRequest`
/// reliably detects purely synthetic composites (flat, rotated, and true-perspective-warped
/// white "documents" on a neutral gray background) with ~0.99 confidence and corner error
/// within ~2%p — no camera shadow/lighting cues needed. These fixtures reuse that approach.
@Suite("DocumentEngine — fixture detection + rectify (Vision-bound)",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Vision document segmentation needs a real session — hangs on headless CI runners; runs locally."))
struct DocumentFixtureTests {
    static let ciContext = CIContext()

    /// Render a flat "document": white rect (with a faint border) + black text, no warp.
    static func renderFlatDocument(width: Int, height: Int, text: String) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 32, nil),
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        var y = height - 60
        for line in text.split(separator: "\n") {
            let ctLine = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, String(line) as CFString, attrs as CFDictionary)!)
            ctx.textPosition = CGPoint(x: 30, y: CGFloat(y))
            CTLineDraw(ctLine, ctx)
            y -= 50
        }
        return ctx.makeImage()!
    }

    /// Composite `doc` onto a neutral gray canvas via true perspective warp
    /// (`CIPerspectiveTransform`) to 4 explicit corners — simulates a document photographed
    /// at an angle. Corners are in CoreImage's coordinate system (bottom-left origin,
    /// pixels) — the same convention `rectify`'s `CIPerspectiveCorrection` input expects
    /// (plan §2.3: no flip needed, Vision/CoreImage are both bottom-left).
    static func compositePerspective(_ doc: CGImage, canvasSize: Int,
                                      topLeft: CGPoint, topRight: CGPoint,
                                      bottomRight: CGPoint, bottomLeft: CGPoint) -> CGImage {
        let ciDoc = CIImage(cgImage: doc)
        let filter = CIFilter(name: "CIPerspectiveTransform")!
        filter.setValue(ciDoc, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        let warped = filter.outputImage!

        let ctx = CGContext(data: nil, width: canvasSize, height: canvasSize, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.42, alpha: 1)) // neutral "desk" gray
        ctx.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        let canvasRect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        guard let warpedCG = ciContext.createCGImage(warped, from: canvasRect) else {
            fatalError("perspective composite render failed")
        }
        ctx.draw(warpedCG, in: canvasRect)
        return ctx.makeImage()!
    }

    /// A blank neutral-gray canvas with no document-like shape at all. `VNDetectDocumentSegmentationRequest`
    /// happens to report confidence exactly 0.0 for this particular gray value (0.4/0.4/0.42) —
    /// see `renderBrightBlankFixture` below for the (much more common) bright-background regime
    /// where that isn't true.
    static func renderBlankFixture(size: Int = 600) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.42, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// A blank bright/overexposed-looking canvas with no document-like shape — the false-positive
    /// regime that `renderBlankFixture`'s single gray value (confidence exactly 0.0) fails to
    /// cover. Empirically swept on this machine (`/tmp/macvis-threshold-spike/spike.swift`,
    /// 2026-07-12, step 0.01 across gray 0.60...1.00): confidence is 0.0 up through gray 0.73,
    /// then jumps to a false-positive band peaking at **0.598 at gray 0.74** and decaying smoothly
    /// to ~0.54 at pure white (1.0) — never returning to 0 anywhere in that range. Off-white color
    /// tints (warm paper ~0.587, cool whiteboard ~0.586) land in the same band. `gray: 0.74` is
    /// the empirically worst (highest-confidence) point in that band, so it's the strongest single
    /// fixture to pin the false-positive-rejection regression to.
    static func renderBrightBlankFixture(size: Int = 600, gray: CGFloat = 0.74) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    static func writePNG(_ image: CGImage) -> String {
        let path = NSTemporaryDirectory() + "macvis-document-fixture-\(UUID().uuidString).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    /// A perspective-warped document fixture + the normalized (bottom-left origin) quad it
    /// was composited at, so tests can assert detected corners against ground truth.
    struct PerspectiveFixture {
        let path: String
        let canvasSize: Int
        let normalizedTopLeft: (x: Double, y: Double)
        let normalizedTopRight: (x: Double, y: Double)
        let normalizedBottomRight: (x: Double, y: Double)
        let normalizedBottomLeft: (x: Double, y: Double)
    }

    static func makePerspectiveFixture(text: String, canvasSize: Int = 1000) -> PerspectiveFixture {
        let doc = renderFlatDocument(width: 600, height: 800, text: text)
        let cs = CGFloat(canvasSize)
        // Same quad shape verified in the Phase 0 spike (confidence 0.99, corner error ~1.5%p).
        let tl = CGPoint(x: cs * 0.15, y: cs * 0.75)
        let tr = CGPoint(x: cs * 0.80, y: cs * 0.85)
        let br = CGPoint(x: cs * 0.88, y: cs * 0.15)
        let bl = CGPoint(x: cs * 0.10, y: cs * 0.20)
        let composited = compositePerspective(doc, canvasSize: canvasSize, topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
        let path = writePNG(composited)
        return PerspectiveFixture(
            path: path, canvasSize: canvasSize,
            normalizedTopLeft: (tl.x / cs, tl.y / cs), normalizedTopRight: (tr.x / cs, tr.y / cs),
            normalizedBottomRight: (br.x / cs, br.y / cs), normalizedBottomLeft: (bl.x / cs, bl.y / cs))
    }

    // MARK: - detectBounds

    @Test("detectBounds finds a perspective-warped document within tolerance of the composited quad")
    func detectsPerspectiveQuad() throws {
        let fixture = Self.makePerspectiveFixture(text: "RECEIPT")
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }

        let result = try DocumentEngine.detectBounds(path: fixture.path)
        #expect(result.imageWidth == fixture.canvasSize)
        #expect(result.imageHeight == fixture.canvasSize)
        let corners = try #require(result.corners)
        let confidence = try #require(result.confidence)
        #expect(confidence > 0.5)

        // Tolerance: Phase 0 spike measured ~1.5%p max corner error; allow 3%p (30px on a
        // 1000px canvas) margin for OS/model variance.
        let tolerance = Int(Double(fixture.canvasSize) * 0.03)
        func assertNear(_ actual: (x: Int, y: Int), _ expectedNormalized: (x: Double, y: Double), _ label: String) {
            let expected = Geometry.toPixelPoint(x: expectedNormalized.x, y: expectedNormalized.y,
                                                 imageWidth: fixture.canvasSize, imageHeight: fixture.canvasSize)
            #expect(abs(actual.x - expected.x) <= tolerance, "\(label).x: got \(actual.x), expected ~\(expected.x)")
            #expect(abs(actual.y - expected.y) <= tolerance, "\(label).y: got \(actual.y), expected ~\(expected.y)")
        }
        assertNear((corners.topLeft.x, corners.topLeft.y), fixture.normalizedTopLeft, "topLeft")
        assertNear((corners.topRight.x, corners.topRight.y), fixture.normalizedTopRight, "topRight")
        assertNear((corners.bottomRight.x, corners.bottomRight.y), fixture.normalizedBottomRight, "bottomRight")
        assertNear((corners.bottomLeft.x, corners.bottomLeft.y), fixture.normalizedBottomLeft, "bottomLeft")
    }

    @Test("found: false (not an error) when no document is present — barcode-style semantics")
    func noDocumentIsNotAnError() throws {
        let image = Self.renderBlankFixture(size: 600)
        let path = Self.writePNG(image)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try DocumentEngine.detectBounds(path: path)
        #expect(result.corners == nil)
        #expect(result.confidence == nil)
        #expect(result.imageWidth == 600 && result.imageHeight == 600)
    }

    @Test("found: false (not a false positive) on a bright/overexposed blank background — hostile-review fix: the exact-zero sentinel alone doesn't cover this regime")
    func brightBlankBackgroundIsNotFalsePositive() throws {
        let image = Self.renderBrightBlankFixture()
        let path = Self.writePNG(image)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try DocumentEngine.detectBounds(path: path)
        #expect(result.corners == nil)
        #expect(result.confidence == nil)
        #expect(result.imageWidth == 600 && result.imageHeight == 600)
    }

    @Test("detectBounds(data:) matches detectBounds(path:) for the same image")
    func detectsFromData() throws {
        let fixture = Self.makePerspectiveFixture(text: "DATA PATH")
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture.path))

        let fromPath = try DocumentEngine.detectBounds(path: fixture.path)
        let fromData = try DocumentEngine.detectBounds(data: data)
        #expect(fromPath.corners != nil)
        #expect(fromData.corners != nil)
        #expect(fromPath.corners?.topLeft.x == fromData.corners?.topLeft.x)
        #expect(fromPath.corners?.topLeft.y == fromData.corners?.topLeft.y)
    }

    @Test("loading a missing file throws imageLoadFailed")
    func missingFileThrows() {
        #expect(throws: VisionError.self) {
            _ = try DocumentEngine.detectBounds(path: "/no/such/file.png")
        }
    }

    @Test("garbage bytes → imageLoadFailed (not valid raster or PDF)")
    func garbageDataThrows() {
        let garbage = Data(repeating: 0xAB, count: 64)
        #expect(throws: VisionError.self) {
            _ = try DocumentEngine.detectBounds(data: garbage)
        }
    }

    // MARK: - rectify

    @Test("rectify throws bad_request/no_document_detected when no document is present")
    func rectifyThrowsWhenNoDocument() throws {
        let image = Self.renderBlankFixture(size: 600)
        let path = Self.writePNG(image)
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            _ = try DocumentEngine.rectify(path: path)
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.name == "bad_request")
            #expect(se?.reason == "no_document_detected")
        }
    }

    @Test("rectify throws bad_request/no_document_detected on a bright/overexposed blank background")
    func rectifyThrowsOnBrightBlankBackground() throws {
        let image = Self.renderBrightBlankFixture()
        let path = Self.writePNG(image)
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            _ = try DocumentEngine.rectify(path: path)
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.name == "bad_request")
            #expect(se?.reason == "no_document_detected")
        }
    }

    @Test("rectify(data:) succeeds on the same fixture as rectify(path:)")
    func rectifiesFromData() throws {
        let fixture = Self.makePerspectiveFixture(text: "DATA RECTIFY")
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture.path))

        let result = try DocumentEngine.rectify(data: data)
        #expect(result.width > 0 && result.height > 0)
        #expect(!result.png.isEmpty)
    }

    // MARK: - core E2E: rectify's output is actually OCR-readable (round-trip, plan §2.4)

    @Test("rectify corrects a perspective-warped document and OCREngine reads the original text back")
    func rectifyRoundTripsThroughOCR() async throws {
        let expectedText = "INVOICE 4471"
        let fixture = Self.makePerspectiveFixture(text: expectedText)
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }

        // Note: Vision's OCR is robust enough to read this fixture's mild synthetic warp
        // even *without* rectification — so this test does not prove rectify was necessary
        // for this specific fixture's text to be legible. What it does verify is regression
        // protection across the full real pipeline (Vision detect -> CoreImage correct ->
        // Vision OCR re-read): deliberately breaking the coordinate math in `rectifyCore`
        // (e.g. flipping the Y axis fed to CIPerspectiveCorrection, which should NOT be
        // flipped — see its doc comment) makes this assertion fail with garbled OCR output,
        // confirmed during review. A stronger warp that defeats raw OCR would make the
        // "rectify was necessary" property directly observable, but isn't required for this
        // test to catch geometry regressions.
        let rectified = try DocumentEngine.rectify(path: fixture.path)
        #expect(rectified.width > 0 && rectified.height > 0)

        let outPath = NSTemporaryDirectory() + "macvis-document-rectified-\(UUID().uuidString).png"
        try rectified.png.write(to: URL(fileURLWithPath: outPath))
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let ocr = try await OCREngine.recognize(path: outPath, languages: ["en-US"])
        #expect(ocr.fullText.contains("INVOICE"), "rectified OCR text was: \(ocr.fullText)")
        #expect(ocr.fullText.contains("4471"), "rectified OCR text was: \(ocr.fullText)")
    }
}
#endif
