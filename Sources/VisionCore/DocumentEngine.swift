import Foundation
import os

#if canImport(Vision)
import Vision
import CoreGraphics
import CoreImage
import ImageIO

/// One pixel-space corner (top-left origin, physical pixels) — matches `find`/`barcode`'s
/// coordinate convention (`Geometry.toPixelPoint`).
public struct DocumentCorner: Sendable {
    public let x: Int
    public let y: Int
}

/// The four corners of a detected document quad, pixel-space, top-left origin.
public struct DocumentCorners: Sendable {
    public let topLeft: DocumentCorner
    public let topRight: DocumentCorner
    public let bottomRight: DocumentCorner
    public let bottomLeft: DocumentCorner
}

/// Result of `document-bounds`: corner coordinates only (no rectification) — mirrors
/// `BarcodeScanResult`'s "detect, don't produce" shape. `corners`/`confidence` are nil when
/// no document was found: `found: false` is a valid outcome (not an error) — `barcode`'s
/// semantics (`code_count: 0`), not `find`'s (exit 1).
public struct DocumentBoundsResult: Sendable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let corners: DocumentCorners?
    public let confidence: Double?
}

/// Result of `rectify-document`: the perspective-corrected, cropped PNG.
public struct RectifyResult: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
}

/// Vision-bound document boundary detection (`document-bounds`) + CoreImage perspective
/// correction (`rectify-document`). `VNDetectDocumentSegmentationRequest` only returns the
/// four corners of the document quad (plan §2.3) — turning that into a flattened scan
/// requires a separate `CIPerspectiveCorrection` pass, which `rectify` layers on top of the
/// same detection `detectBounds` uses (both funnel through `detectQuad` below).
public enum DocumentEngine {
    /// Default `minConfidence` for `document-bounds`/`rectify-document` (hostile-review fix,
    /// 2026-07-12). `Geometry.pickLargestQuad`'s exact-zero-confidence sentinel filter only
    /// covers `VNDetectDocumentSegmentationRequest`'s "no document" response for *some* gray
    /// values — empirically swept on this machine (step 0.01 across gray 0.60...1.00), bright
    /// blank scenes (plain white paper, a whiteboard, an overexposed photo) return a
    /// **false-positive confidence band from ~0.54 up to a measured peak of 0.598** (at gray
    /// 0.74), never landing on exactly 0. A `minConfidence: 0.0` default (the prior value)
    /// therefore let a blank bright background masquerade as a full-frame "detected document".
    /// Real document fixtures (flat, rotated, perspective-warped) measured ~0.99 in the same
    /// sweep, so `0.7` sits with ~0.10 margin above the false-positive ceiling and ~0.29 margin
    /// below genuine detections — comfortably inside the gap. Callers can still override via
    /// `--min-confidence`/`minConfidence` (e.g. to accept lower-confidence detections at their
    /// own risk); this only changes what happens when they don't.
    public static let defaultMinConfidence: Double = 0.7

    /// Real capability probe for `doctor` (mirrors `OCREngine.textVisionAvailable`/
    /// `BarcodeEngine.barcodeVisionAvailable`). `CIPerspectiveCorrection` (the other half of
    /// `rectify`) is a plain CoreImage filter with no availability gate (plan §2.3), so this
    /// single probe represents both `document-bounds` and `rectify-document`.
    public static func documentVisionAvailable() -> Bool {
        _probe.withLock { cached in
            if let v = cached { return v }
            let ok = probe()
            cached = ok; return ok
        }
    }

    private static let _probe = OSAllocatedUnfairLock(initialState: Optional<Bool>.none)

    private static func probe() -> Bool {
        guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage() else { return false }
        do {
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([VNDetectDocumentSegmentationRequest()])
            return true
        } catch {
            return false
        }
    }

    // MARK: - detectBounds (path + data)

    public static func detectBounds(
        path: String, minConfidence: Double = defaultMinConfidence, page: Int = 1, scale: Double = 2.0
    ) throws -> DocumentBoundsResult {
        let (cgImage, width, height) = try OCREngine.loadImage(path: path, page: page, scale: scale)
        let quad = try detectQuad(cgImage: cgImage, minConfidence: minConfidence)
        return boundsResult(quad: quad, width: width, height: height)
    }

    public static func detectBounds(
        data: Data, minConfidence: Double = defaultMinConfidence, page: Int = 1, scale: Double = 2.0
    ) throws -> DocumentBoundsResult {
        let (cgImage, width, height) = try OCREngine.loadImage(data: data, page: page, scale: scale)
        let quad = try detectQuad(cgImage: cgImage, minConfidence: minConfidence)
        return boundsResult(quad: quad, width: width, height: height)
    }

    private static func boundsResult(quad: NormalizedQuad?, width: Int, height: Int) -> DocumentBoundsResult {
        guard let quad else {
            return DocumentBoundsResult(imageWidth: width, imageHeight: height, corners: nil, confidence: nil)
        }
        func corner(_ p: NormalizedPoint) -> DocumentCorner {
            let px = Geometry.toPixelPoint(x: p.x, y: p.y, imageWidth: width, imageHeight: height)
            return DocumentCorner(x: px.x, y: px.y)
        }
        let corners = DocumentCorners(
            topLeft: corner(quad.topLeft), topRight: corner(quad.topRight),
            bottomRight: corner(quad.bottomRight), bottomLeft: corner(quad.bottomLeft))
        return DocumentBoundsResult(imageWidth: width, imageHeight: height, corners: corners, confidence: quad.confidence)
    }

    // MARK: - rectify (path + data)

    public static func rectify(
        path: String, minConfidence: Double = defaultMinConfidence, page: Int = 1, scale: Double = 2.0
    ) throws -> RectifyResult {
        let (cgImage, width, height) = try OCREngine.loadImage(path: path, page: page, scale: scale)
        return try rectifyCore(cgImage: cgImage, width: width, height: height, minConfidence: minConfidence)
    }

    public static func rectify(
        data: Data, minConfidence: Double = defaultMinConfidence, page: Int = 1, scale: Double = 2.0
    ) throws -> RectifyResult {
        let (cgImage, width, height) = try OCREngine.loadImage(data: data, page: page, scale: scale)
        return try rectifyCore(cgImage: cgImage, width: width, height: height, minConfidence: minConfidence)
    }

    private static func rectifyCore(cgImage: CGImage, width: Int, height: Int, minConfidence: Double) throws -> RectifyResult {
        guard let quad = try detectQuad(cgImage: cgImage, minConfidence: minConfidence) else {
            // Unlike detectBounds (a detection-only command where "nothing found" is a valid
            // barcode-style outcome), rectify *produces* an image — nothing to produce means
            // this is a bad_request, matching make-qr's "reject empty text" precedent (plan §2.5).
            throw ServiceError(name: "bad_request", reason: "no_document_detected",
                               hint: "no document boundary was found in this image; try a clearer photo of the document with visible edges against a contrasting background",
                               exitCode: ExitCode.usage.rawValue)
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw ServiceError(name: "rectify_failed", reason: "filter_unavailable",
                               hint: "CIPerspectiveCorrection is unavailable on this system",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        // CoreImage positions are bottom-left origin, same as Vision's normalized corners
        // (plan §2.3 introspection) — scale straight to pixel size, no y-flip (unlike
        // Geometry.toPixelPoint, which flips for the document-bounds *output* contract).
        func vector(_ p: NormalizedPoint) -> CIVector {
            CIVector(x: CGFloat(p.x) * CGFloat(width), y: CGFloat(p.y) * CGFloat(height))
        }
        filter.setValue(CIImage(cgImage: cgImage), forKey: kCIInputImageKey)
        filter.setValue(vector(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(vector(quad.topRight), forKey: "inputTopRight")
        filter.setValue(vector(quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(vector(quad.bottomLeft), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else {
            throw ServiceError(name: "rectify_failed", reason: "no_output",
                               hint: "the filter produced no output for this input",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        let ciContext = CIContext()
        guard let outCG = ciContext.createCGImage(output, from: output.extent) else {
            throw ServiceError(name: "rectify_failed", reason: "render_failed",
                               hint: "failed to rasterize the corrected image",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        let png = try encodePNG(outCG)
        return RectifyResult(png: png, width: outCG.width, height: outCG.height)
    }

    /// Writes a rectified PNG to `path`, translating write failures into the shared
    /// `ServiceError` contract (mirrors `QRGenerator.writePNG`, with its own `rectify_failed`
    /// error name so a write failure here isn't misattributed to `make-qr`).
    public static func writePNG(_ data: Data, to path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw ServiceError(name: "rectify_failed", reason: "write_failed", detail: path,
                               hint: "check the destination directory exists and is writable",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        // "public.png" is the UTType.png identifier spelled as a literal — see
        // QRGenerator.encodePNG for the rationale (avoids a UniformTypeIdentifiers import).
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ServiceError(name: "rectify_failed", reason: "encode_failed",
                               hint: "failed to create a PNG image destination",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ServiceError(name: "rectify_failed", reason: "encode_failed",
                               hint: "failed to finalize the PNG encode",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        return data as Data
    }

    // MARK: - shared detection core

    /// Normalized (bottom-left origin) quad candidates + confidence, straight from Vision —
    /// then delegates ranking to `Geometry.pickLargestQuad` (Vision-independent, unit-tested
    /// in `PureLogicTests`), which resolves the "multiple documents in one frame" policy
    /// question (plan risk #3: prefer the largest by area).
    private static func detectQuad(cgImage: CGImage, minConfidence: Double) throws -> NormalizedQuad? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let candidates = (request.results ?? []).map { obs in
            NormalizedQuad(
                topLeft: NormalizedPoint(x: Double(obs.topLeft.x), y: Double(obs.topLeft.y)),
                topRight: NormalizedPoint(x: Double(obs.topRight.x), y: Double(obs.topRight.y)),
                bottomRight: NormalizedPoint(x: Double(obs.bottomRight.x), y: Double(obs.bottomRight.y)),
                bottomLeft: NormalizedPoint(x: Double(obs.bottomLeft.x), y: Double(obs.bottomLeft.y)),
                confidence: Double(obs.confidence))
        }
        return Geometry.pickLargestQuad(candidates, minConfidence: minConfidence)
    }
}
#endif
