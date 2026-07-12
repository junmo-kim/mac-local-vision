import Foundation
import CoreImage
import CoreGraphics
import ImageIO

/// Output of `QRGenerator.generate`: the encoded PNG bytes plus the pixel dimensions of
/// the image actually produced (module count × module scale — see `generate`'s doc).
public struct QRGenerateResult: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
}

/// Encodes text into a scannable QR code PNG via `CIFilter("CIQRCodeGenerator")` — the
/// generation counterpart to `BarcodeEngine.detect`'s decoding (`make-qr` vs.
/// `barcode`). Unlike `BarcodeEngine` (which wraps `VNDetectBarcodesRequest` and is gated
/// behind `#if canImport(Vision)`), `CIQRCodeGenerator` is a plain CoreImage filter that
/// has existed since macOS 10.9 — no Vision framework dependency, no availability gate
/// (plan §2.3).
public enum QRGenerator {
    public static let validCorrectionLevels: Set<String> = ["L", "M", "Q", "H"]

    /// Default per-module pixel magnification when `size` isn't given. `CIQRCodeGenerator`
    /// natively emits one point per module (e.g. 25×25pt for a typical URL payload), which
    /// is well below `BarcodeEngine.detect`'s effective read resolution, so the output must
    /// be magnified before re-scanning reliably. 10px/module round-trips cleanly through
    /// `BarcodeEngine.detect` (verified in `QRGeneratorFixtureTests`, including a size:1
    /// floor case), matching the module-scale approach `BarcodeFixtureTests.renderQRFixture`
    /// already proved reliable (that fixture used 12; 10 keeps a comfortable margin above
    /// the size:1 floor while staying compact).
    public static let defaultModuleScale = 10

    /// Generate a QR code PNG encoding `text`. `size` is the per-module pixel
    /// magnification (not the overall image side length) — clamped to a minimum of 1.
    /// The produced image's actual `width`/`height` (module count × scale) are reported
    /// back since the module count varies with payload length and correction level and
    /// isn't knowable in advance.
    public static func generate(text: String, correctionLevel: String = "M", size: Int? = nil) throws -> QRGenerateResult {
        guard !text.isEmpty else {
            throw ServiceError(name: "bad_request", reason: "missing_text",
                               hint: "make-qr requires non-empty text to encode",
                               exitCode: ExitCode.usage.rawValue)
        }
        guard validCorrectionLevels.contains(correctionLevel) else {
            throw ServiceError(name: "bad_request", reason: "invalid_correction_level", detail: correctionLevel,
                               hint: "correction level must be one of: L, M, Q, H",
                               exitCode: ExitCode.usage.rawValue)
        }
        let moduleScale = max(1, size ?? defaultModuleScale)

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw ServiceError(name: "generate_qr_failed", reason: "filter_unavailable",
                               hint: "CIQRCodeGenerator is unavailable on this system",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let nativeOutput = filter.outputImage else {
            throw ServiceError(name: "generate_qr_failed", reason: "no_output", detail: text,
                               hint: "the filter produced no output for this input",
                               exitCode: ExitCode.runtimeError.rawValue)
        }

        // Reject before rasterizing rather than after: `moduleScale` only floors at 1 above,
        // and module count grows with payload length/correction level, so `size * moduleCount`
        // can produce an arbitrarily large image (17920x17920px/5.6MB observed from a ~90-char
        // URL at --size 512) — the same "unbounded width*height*4-byte allocation (local DoS)"
        // class OCREngine.clampedRasterSize already guards against for decode, reusing its cap
        // (OCREngine.maxRasterPixels, ~100MP/400MB) so generation and decoding share one limit.
        // `nativeOutput.extent` is cheap (a CIImage graph, not yet rendered), so this check runs
        // before any real allocation happens. Float math (not Int) avoids an overflow trap for
        // pathological --size values.
        let nativeExtent = nativeOutput.extent
        let projectedWidth = nativeExtent.width * CGFloat(moduleScale)
        let projectedHeight = nativeExtent.height * CGFloat(moduleScale)
        guard projectedWidth.isFinite, projectedHeight.isFinite,
              projectedWidth * projectedHeight <= CGFloat(OCREngine.maxRasterPixels) else {
            throw ServiceError(name: "bad_request", reason: "size_too_large", detail: "\(moduleScale)",
                               hint: "reduce --size or payload length; the generated image would exceed the \(OCREngine.maxRasterPixels)-pixel raster cap",
                               exitCode: ExitCode.usage.rawValue)
        }

        // Nearest-neighbor sampling before the scale-up keeps module edges crisp — bilinear
        // interpolation on the native ~1px/module QR image would blur modules past the
        // detector's read threshold (see BarcodeFixtureTests.renderQRFixture, the origin of
        // this logic, now promoted here as the production implementation).
        let output = nativeOutput.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(moduleScale), y: CGFloat(moduleScale)))

        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(output, from: output.extent) else {
            throw ServiceError(name: "generate_qr_failed", reason: "render_failed", detail: text,
                               hint: "failed to rasterize the generated QR code",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        let png = try encodePNG(cgImage)
        return QRGenerateResult(png: png, width: cgImage.width, height: cgImage.height)
    }

    /// Writes `data` (a generated QR PNG) to `path`, translating any Cocoa/POSIX write
    /// failure (missing parent directory, permissions, ...) into the same structured
    /// `ServiceError` contract every other `make-qr` failure path already uses
    /// (Wire.swift's "name/reason/hint" `ServiceError`) instead of letting a raw
    /// `NSCocoaErrorDomain` dump reach the CLI/MCP caller.
    public static func writePNG(_ data: Data, to path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw ServiceError(name: "generate_qr_failed", reason: "write_failed", detail: path,
                               hint: "check the destination directory exists and is writable",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        // "public.png" is the UTType.png identifier spelled as a literal — avoids an
        // UniformTypeIdentifiers import to keep this file's dependency surface to exactly
        // CoreImage/CoreGraphics/ImageIO (plan §2.3).
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ServiceError(name: "generate_qr_failed", reason: "encode_failed",
                               hint: "failed to create a PNG image destination",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ServiceError(name: "generate_qr_failed", reason: "encode_failed",
                               hint: "failed to finalize the PNG encode",
                               exitCode: ExitCode.runtimeError.rawValue)
        }
        return data as Data
    }
}
