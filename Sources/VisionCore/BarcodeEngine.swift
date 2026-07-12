import Foundation
import os

#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO

/// One detected barcode/QR code: decoded payload (nil when the symbology/data combination
/// can't produce a string), symbology, and pixel box (already converted to top-left/physical,
/// matching `find`'s convention).
public struct BarcodeResult: Sendable {
    public let payload: String?
    public let symbologyName: String
    public let rect: PixelRect
    public let confidence: Double
}

/// All codes detected in one image, plus the physical dimensions of that image
/// (mirrors `OCRResult`'s pairing of results with `imageWidth`/`imageHeight`).
public struct BarcodeScanResult: Sendable {
    public let codes: [BarcodeResult]
    public let imageWidth: Int
    public let imageHeight: Int
}

/// Vision-bound barcode/QR detection (`barcode`). `VNDetectBarcodesRequest` is a single
/// request family that covers every 1D/2D symbology Vision supports, including QR — so,
/// matching the project's "1 Vision request family = 1 command" architecture (`ocr`,
/// `sort-faces`), there is one `barcode` command rather than a separate `qr` command.
public enum BarcodeEngine {
    /// Bidirectional name <-> `VNBarcodeSymbology` mapping. Vision's Swift-bridged
    /// (`NS_SWIFT_NAME`) constant names, verified against the SDK header
    /// (`VNTypes.h`, Xcode 26.4.1) — see plan §2.3. Kept as a static table (rather than
    /// derived from `supportedSymbologiesAndReturnError`, which the header calls
    /// "potentially expensive") so CLI/MCP short names are cheap to validate and stable
    /// across OS versions.
    static let symbologyByName: [String: VNBarcodeSymbology] = [
        "aztec": .aztec,
        "code39": .code39,
        "code39Checksum": .code39Checksum,
        "code39FullASCII": .code39FullASCII,
        "code39FullASCIIChecksum": .code39FullASCIIChecksum,
        "code93": .code93,
        "code93i": .code93i,
        "code128": .code128,
        "dataMatrix": .dataMatrix,
        "ean8": .ean8,
        "ean13": .ean13,
        "i2of5": .i2of5,
        "i2of5Checksum": .i2of5Checksum,
        "itf14": .itf14,
        "pdf417": .pdf417,
        "qr": .qr,
        "upce": .upce,
        "codabar": .codabar,
        "gs1DataBar": .gs1DataBar,
        "gs1DataBarExpanded": .gs1DataBarExpanded,
        "gs1DataBarLimited": .gs1DataBarLimited,
        "microPDF417": .microPDF417,
        "microQR": .microQR,
        "msiPlessey": .msiPlessey,
    ]

    static let nameBySymbology: [VNBarcodeSymbology: String] =
        Dictionary(uniqueKeysWithValues: symbologyByName.map { ($1, $0) })

    /// All valid CLI/MCP `--symbology` names, sorted for stable error messages/help text.
    public static var allSymbologyNames: [String] { symbologyByName.keys.sorted() }

    /// Look up a `VNBarcodeSymbology` by its CLI/MCP short name, or nil if unknown.
    public static func symbology(forName name: String) -> VNBarcodeSymbology? {
        symbologyByName[name]
    }

    /// The CLI/MCP short name for a `VNBarcodeSymbology`. Falls back to the raw Vision
    /// constant string for forward-compat: a future OS could add a symbology this table
    /// doesn't know about yet — better to surface *something* than silently drop the result.
    public static func name(for symbology: VNBarcodeSymbology) -> String {
        nameBySymbology[symbology] ?? symbology.rawValue
    }

    /// Resolve `--symbology` names to `VNBarcodeSymbology` values (pure logic, no Vision
    /// session — safe to call from PureLogicTests). Throws the same structured
    /// `bad_request`/`unknown_symbology` shape as `InputSource.resolve`'s `missing_input`,
    /// so CLI/MCP error handling is uniform across ops.
    static func resolveSymbologies(_ names: [String]) throws -> [VNBarcodeSymbology] {
        try names.map { name in
            guard let sym = symbology(forName: name) else {
                throw ServiceError(name: "bad_request", reason: "unknown_symbology", detail: name,
                                   hint: "known symbologies: \(allSymbologyNames.joined(separator: ", "))",
                                   exitCode: ExitCode.usage.rawValue)
            }
            return sym
        }
    }

    /// Real capability probe for `doctor` (see `OCREngine.textVisionAvailable` for the
    /// pattern this mirrors): does `VNDetectBarcodesRequest` actually execute here? Runs
    /// over a small blank image; memoized for the process lifetime.
    public static func barcodeVisionAvailable() -> Bool {
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
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([VNDetectBarcodesRequest()])
            return true
        } catch {
            return false
        }
    }

    // MARK: - detect (path + data)

    public static func detect(
        path: String,
        symbologies: [String] = [],
        minConfidence: Double = 0.0,
        page: Int = 1,
        scale: Double = 2.0
    ) throws -> BarcodeScanResult {
        let syms = try resolveSymbologies(symbologies)
        let (cgImage, width, height) = try OCREngine.loadImage(path: path, page: page, scale: scale)
        return try detectCore(cgImage: cgImage, width: width, height: height,
                              symbologies: syms, minConfidence: minConfidence)
    }

    public static func detect(
        data: Data,
        symbologies: [String] = [],
        minConfidence: Double = 0.0,
        page: Int = 1,
        scale: Double = 2.0
    ) throws -> BarcodeScanResult {
        let syms = try resolveSymbologies(symbologies)
        let (cgImage, width, height) = try OCREngine.loadImage(data: data, page: page, scale: scale)
        return try detectCore(cgImage: cgImage, width: width, height: height,
                              symbologies: syms, minConfidence: minConfidence)
    }

    private static func detectCore(
        cgImage: CGImage, width: Int, height: Int,
        symbologies: [VNBarcodeSymbology], minConfidence: Double
    ) throws -> BarcodeScanResult {
        let request = VNDetectBarcodesRequest()
        if !symbologies.isEmpty {
            request.symbologies = symbologies
        } // else: leave Vision's default — scan every known symbology.

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        var codes: [BarcodeResult] = []
        for observation in request.results ?? [] {
            let confidence = Double(observation.confidence)
            guard confidence >= minConfidence else { continue }

            let bb = observation.boundingBox // normalized, bottom-left origin
            let rect = NormalizedRect(x: bb.origin.x, y: bb.origin.y,
                                      width: bb.size.width, height: bb.size.height)
            guard Geometry.isSane(rect) else { continue }
            let pixel = Geometry.toPixelRect(rect, imageWidth: width, imageHeight: height)

            codes.append(BarcodeResult(
                payload: observation.payloadStringValue,
                symbologyName: name(for: observation.symbology),
                rect: pixel, confidence: confidence))
        }
        return BarcodeScanResult(codes: codes, imageWidth: width, imageHeight: height)
    }
}
#endif
