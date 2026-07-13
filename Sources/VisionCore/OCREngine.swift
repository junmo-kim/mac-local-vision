import Foundation
import os

#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO

public enum VisionError: Error, CustomStringConvertible {
    case imageLoadFailed(String)
    case noFace(String)

    public var description: String {
        switch self {
        case .imageLoadFailed(let p): return "failed to load image: \(p)"
        case .noFace(let p): return "no face detected in: \(p)"
        }
    }
}

/// A single recognized word with its normalized box.
public struct OCRWord: Sendable {
    public let text: String
    public let rect: NormalizedRect
}

/// A single recognized text line with its normalized box and confidence.
/// `words` is populated only when word-level extraction is requested.
public struct OCRLine: Sendable {
    public let text: String
    public let rect: NormalizedRect
    public let confidence: Double
    public let words: [OCRWord]

    public init(text: String, rect: NormalizedRect, confidence: Double, words: [OCRWord] = []) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.words = words
    }
}

public struct OCRResult: Sendable {
    public let lines: [OCRLine]
    public let fullText: String
    public let imageWidth: Int
    public let imageHeight: Int
}

/// Result of `find`: a pixel-space hit ready for an E2E click/assert.
public struct FindResult: Sendable {
    public let rect: PixelRect
    public let confidence: Double
    public let textFound: String
    /// True when the tight sub-string box was unavailable and `rect` is the whole line
    /// (so the click point is line-center, not word-center).
    public let approximate: Bool
}

/// Vision-bound OCR (`ocr` / `find`). Works on macOS 26 — independent of Apple
/// Intelligence — using the stable `VNRecognizeTextRequest` engine. The word-level
/// `find` path uses `boundingBox(for:)` for sub-string pixel targeting (architecture §5.4).
public enum OCREngine {
    /// Recognition languages derived from the current machine's locale, mapped onto
    /// Vision's supported set (see `Languages.resolve`). Locale-aware, not hardcoded,
    /// so it is correct under global distribution. Overridden per-call via `--lang`.
    public static func systemDefaultLanguages() -> [String] {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        return Languages.resolve(preferred: Locale.preferredLanguages, supported: supported)
    }

    /// Every `.perform()` call this engine makes (`recognize`/`find`'s real work, plus the
    /// two probes below) funnels through this one dedicated queue — see
    /// `VisionSerialQueue`'s type doc for why concurrent `VNImageRequestHandler.perform()`
    /// calls need this (plan `2026-07-13-macvis-vision-concurrency-fix`; Phase 0 of that plan
    /// reproduced this engine deadlocking directly: 15 concurrent `Task`s each calling the
    /// then-synchronous `recognize`, hung indefinitely at ~0% CPU). `faceVisionAvailable()`
    /// also routes through here (rather than through `FaceEngine`'s own queue) purely because
    /// it's physically defined in this file — see its doc comment for why it lives here at
    /// all; correctness doesn't depend on *which* dedicated queue a given probe uses, only
    /// that some dedicated queue is used (per-engine grouping is a throughput choice, not a
    /// safety one).
    private static let visionQueue = VisionSerialQueue(label: "mac-local-vision.ocr")

    /// Real capability probes for `doctor`: can these Vision requests actually execute
    /// here? Each runs over a small blank image — succeeds normally, throws if the
    /// platform/sandbox denies that request. Beats a hardcoded "available". Probe per
    /// request family (text vs face) since their availability is independent. Results are
    /// memoized for the process lifetime (capability doesn't change mid-process; matters
    /// for the long-lived MCP server calling `doctor` repeatedly). Vision rejects ≤2px
    /// images, so use 32×32.
    public static func textVisionAvailable() async -> Bool {
        if let cached = _textProbe.withLock({ $0 }) { return cached }
        let ok = await probe { VNRecognizeTextRequest() }
        _textProbe.withLock { $0 = ok }
        return ok
    }

    public static func faceVisionAvailable() async -> Bool {
        if let cached = _faceProbe.withLock({ $0 }) { return cached }
        let ok = await probe { VNDetectFaceRectanglesRequest() }
        _faceProbe.withLock { $0 = ok }
        return ok
    }

    private static let _textProbe = OSAllocatedUnfairLock(initialState: Optional<Bool>.none)
    private static let _faceProbe = OSAllocatedUnfairLock(initialState: Optional<Bool>.none)

    private static func probe(_ makeRequest: @escaping @Sendable () -> VNRequest) async -> Bool {
        (try? await visionQueue.run {
            guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let img = ctx.makeImage() else { return false }
            do {
                try VNImageRequestHandler(cgImage: img, options: [:]).perform([makeRequest()])
                return true
            } catch {
                return false
            }
        }) ?? false
    }

    // MARK: - Image loading (path)

    public static func loadImage(path: String, page: Int = 1, scale: Double = 2.0) throws -> (cgImage: CGImage, width: Int, height: Int) {
        let url = URL(fileURLWithPath: path)
        // Raster formats (png/jpg/heic/tiff/...) decode natively via ImageIO,
        // with EXIF orientation normalized to upright.
        if let image = loadOriented(path: path) {
            // Physical pixels (architecture §5.1) — never a logical viewport.
            return (image, image.width, image.height)
        }
        // PDFs are vector — CGImageSource can't read them. Rasterize the page.
        if let pdf = renderPDFPage(url: url, page: page, scale: CGFloat(scale)) {
            return (pdf, pdf.width, pdf.height)
        }
        throw VisionError.imageLoadFailed(path)
    }

    /// Decode an image with its EXIF orientation applied (upright). Phone photos are
    /// often stored sideways with an orientation flag; `CGImageSourceCreateImageAtIndex`
    /// ignores it, which rotates faces/text and wrecks OCR and face matching. The
    /// thumbnail API with `WithTransform` bakes the orientation into the pixels.
    static func loadOriented(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        // Bound the decode: a crafted header claiming huge dimensions would otherwise drive an
        // unbounded decode/allocation. Per-dim guards keep `pw * ph` from overflowing Int.
        // Negative dimensions are theoretically possible from malformed network-sourced images.
        guard pw > 0, ph > 0, pw <= maxRasterPixels, ph <= maxRasterPixels,
              pw * ph <= maxRasterPixels else { return nil }
        let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation == 1 {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        let maxDim = max(pw, ph)
        if maxDim > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxDim } // full-res, no downscale
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Bitmap dimensions for a `scale`d PDF box, or nil if the result is non-finite, empty,
    /// or exceeds `maxPixels`. Guards `renderPDFPage` from a crafted mediaBox or an over-large
    /// `--scale`: without this, `Int((box.width * scale).rounded())` can **trap on overflow**
    /// for a huge box, or drive an unbounded `width*height*4`-byte allocation (local DoS).
    /// Cap ~100 MP (≈400 MB premultiplied RGBA); legitimate OCR pages never approach it.
    /// ~100 MP ceiling (≈400 MB premultiplied RGBA) for any rasterized surface — bounds
    /// both PDF rasterization and raster-image decode against crafted/huge inputs.
    static let maxRasterPixels = 100_000_000

    static func clampedRasterSize(boxWidth: CGFloat, boxHeight: CGFloat, scale: CGFloat,
                                  maxPixels: Int = maxRasterPixels) -> (width: Int, height: Int)? {
        let w = (boxWidth * scale).rounded()
        let h = (boxHeight * scale).rounded()
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w * h <= CGFloat(maxPixels) else { return nil }
        return (Int(w), Int(h))
    }

    /// Rasterize a single PDF page to a CGImage at `scale` (2.0 ≈ 144 dpi — a good
    /// OCR default; higher = sharper but slower). Returns nil if the page is invalid
    /// or too large to rasterize safely (see `clampedRasterSize`).
    static func renderPDFPage(url: URL, page: Int, scale: CGFloat) -> CGImage? {
        guard let doc = CGPDFDocument(url as CFURL),
              page >= 1, page <= doc.numberOfPages,
              let pdfPage = doc.page(at: page) else { return nil }

        let box = pdfPage.getBoxRect(.mediaBox)
        guard let (width, height) = clampedRasterSize(
            boxWidth: box.width, boxHeight: box.height, scale: scale) else { return nil }

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White background — PDFs are often transparent, which hurts OCR contrast.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.drawPDFPage(pdfPage)
        return ctx.makeImage()
    }

    // MARK: - Image loading (data — for remote/HTTP callers)

    public static func loadImage(data: Data, page: Int = 1, scale: Double = 2.0) throws -> (cgImage: CGImage, width: Int, height: Int) {
        if let image = loadOriented(data: data) {
            return (image, image.width, image.height)
        }
        if let pdf = renderPDFPage(data: data, page: page, scale: CGFloat(scale)) {
            return (pdf, pdf.width, pdf.height)
        }
        throw VisionError.imageLoadFailed("<base64 data>")
    }

    static func loadOriented(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard pw > 0, ph > 0, pw <= maxRasterPixels, ph <= maxRasterPixels,
              pw * ph <= maxRasterPixels else { return nil }
        let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation == 1 {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        let maxDim = max(pw, ph)
        if maxDim > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxDim }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func renderPDFPage(data: Data, page: Int, scale: CGFloat) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider),
              page >= 1, page <= doc.numberOfPages,
              let pdfPage = doc.page(at: page) else { return nil }
        let box = pdfPage.getBoxRect(.mediaBox)
        guard let (width, height) = clampedRasterSize(
            boxWidth: box.width, boxHeight: box.height, scale: scale) else { return nil }
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.drawPDFPage(pdfPage)
        return ctx.makeImage()
    }

    // MARK: - recognize (path + data)

    public static func recognize(
        path: String,
        fast: Bool = false,
        minConfidence: Double = 0.0,
        languages: [String] = [],
        includeWords: Bool = false,
        page: Int = 1,
        scale: Double = 2.0
    ) async throws -> OCRResult {
        let (cgImage, width, height) = try loadImage(path: path, page: page, scale: scale)
        return try await recognizeCore(cgImage: cgImage, width: width, height: height,
                                  fast: fast, minConfidence: minConfidence,
                                  languages: languages, includeWords: includeWords)
    }

    public static func recognize(
        data: Data,
        fast: Bool = false,
        minConfidence: Double = 0.0,
        languages: [String] = [],
        includeWords: Bool = false,
        page: Int = 1,
        scale: Double = 2.0
    ) async throws -> OCRResult {
        let (cgImage, width, height) = try loadImage(data: data, page: page, scale: scale)
        return try await recognizeCore(cgImage: cgImage, width: width, height: height,
                                  fast: fast, minConfidence: minConfidence,
                                  languages: languages, includeWords: includeWords)
    }

    private static func recognizeCore(
        cgImage: CGImage, width: Int, height: Int,
        fast: Bool, minConfidence: Double, languages: [String], includeWords: Bool
    ) async throws -> OCRResult {
        try await visionQueue.run {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = !fast
            request.recognitionLanguages = languages.isEmpty ? Self.systemDefaultLanguages() : languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            var lines: [OCRLine] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let confidence = Double(candidate.confidence)
                guard confidence >= minConfidence else { continue }

                let bb = observation.boundingBox // normalized, bottom-left origin
                let rect = NormalizedRect(x: bb.origin.x, y: bb.origin.y,
                                          width: bb.size.width, height: bb.size.height)
                guard Geometry.isSane(rect) else { continue }

                var words: [OCRWord] = []
                if includeWords {
                    for range in TextRanges.words(in: candidate.string) {
                        guard let box = try? candidate.boundingBox(for: range) else { continue }
                        let wbb = box.boundingBox
                        let wrect = NormalizedRect(x: wbb.origin.x, y: wbb.origin.y,
                                                   width: wbb.size.width, height: wbb.size.height)
                        guard Geometry.isSane(wrect) else { continue }
                        words.append(OCRWord(text: String(candidate.string[range]), rect: wrect))
                    }
                }
                lines.append(OCRLine(text: candidate.string, rect: rect, confidence: confidence, words: words))
            }

            let fullText = lines.map(\.text).joined(separator: "\n")
            return OCRResult(lines: lines, fullText: fullText, imageWidth: width, imageHeight: height)
        }
    }

    // MARK: - find (path + data)

    /// Locate `target` and return the center pixel of just that sub-string.
    /// Returns `nil` when the target is not found above the confidence threshold.
    public static func find(
        path: String,
        target: String,
        minConfidence: Double = 0.3,
        languages: [String] = [],
        page: Int = 1,
        scale: Double = 2.0
    ) async throws -> FindResult? {
        let (cgImage, width, height) = try loadImage(path: path, page: page, scale: scale)
        return try await findCore(cgImage: cgImage, width: width, height: height,
                            target: target, minConfidence: minConfidence, languages: languages)
    }

    public static func find(
        data: Data,
        target: String,
        minConfidence: Double = 0.3,
        languages: [String] = [],
        page: Int = 1,
        scale: Double = 2.0
    ) async throws -> FindResult? {
        let (cgImage, width, height) = try loadImage(data: data, page: page, scale: scale)
        return try await findCore(cgImage: cgImage, width: width, height: height,
                            target: target, minConfidence: minConfidence, languages: languages)
    }

    private static func findCore(
        cgImage: CGImage, width: Int, height: Int,
        target: String, minConfidence: Double, languages: [String]
    ) async throws -> FindResult? {
        try await visionQueue.run {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate // headless font defense (architecture §5.2)
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages.isEmpty ? Self.systemDefaultLanguages() : languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let confidence = Double(candidate.confidence)
                guard confidence >= minConfidence else { continue }
                guard let range = candidate.string.range(of: target) else { continue }

                // Prefer the tight sub-string box (architecture §5.4). But `boundingBox(for:)`
                // throws for some ranges (ligatures / whitespace spans); the text IS present,
                // so fall back to the line-level box rather than reporting a false not-found.
                func normalized(_ cg: CGRect) -> NormalizedRect {
                    NormalizedRect(x: cg.origin.x, y: cg.origin.y, width: cg.size.width, height: cg.size.height)
                }
                var rect = normalized(observation.boundingBox)
                var approximate = true
                if let box = try? candidate.boundingBox(for: range) {
                    let sub = normalized(box.boundingBox)
                    if Geometry.isSane(sub) { rect = sub; approximate = false }
                }
                guard Geometry.isSane(rect) else { continue }

                let pixel = Geometry.toPixelRect(rect, imageWidth: width, imageHeight: height)
                return FindResult(rect: pixel, confidence: confidence,
                                  textFound: String(candidate.string[range]), approximate: approximate)
            }
            return nil
        }
    }
}
#endif
