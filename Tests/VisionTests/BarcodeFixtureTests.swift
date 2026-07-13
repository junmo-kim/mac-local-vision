#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import VisionCore

/// Tier ② (impl §2): exercise the real Vision barcode/QR path against CIFilter-rendered
/// fixtures — no static image assets in the repo, mirroring `OCRFixtureTests.renderFixture`.
@Suite("BarcodeEngine — fixture detection (Vision-bound)",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Vision barcode detection needs a real session — hangs on headless CI runners; runs locally."))
struct BarcodeFixtureTests {
    static let ciContext = CIContext()

    /// Render a QR code carrying `payload` to a unique temp PNG; returns its path.
    /// Delegates to the production `QRGenerator` (promoted from this fixture helper's
    /// original CIFilter/nearest-neighbor logic in a prior commit — see QRGenerator.swift
    /// for the module-scale rationale) so the fixture and the `make-qr` command stay
    /// on one code path.
    static func renderQRFixture(_ payload: String, moduleScale: CGFloat = 12) -> String {
        let result = try! QRGenerator.generate(text: payload, correctionLevel: "M", size: Int(moduleScale))
        let path = NSTemporaryDirectory() + "macvis-barcode-fixture-\(UUID().uuidString).png"
        try! result.png.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Render a Code128 1D barcode carrying `payload` to a unique temp PNG.
    static func renderCode128Fixture(_ payload: String, scale: CGFloat = 4) -> String {
        let filter = CIFilter(name: "CICode128BarcodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let output = filter.outputImage!.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return writePNG(output)
    }

    /// A blank white image with no barcode of any kind.
    static func renderBlankFixture(width: Int = 200, height: Int = 200) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let path = NSTemporaryDirectory() + "macvis-barcode-fixture-\(UUID().uuidString).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    static func writePNG(_ image: CIImage) -> String {
        let cgImage = ciContext.createCGImage(image, from: image.extent)!
        let path = NSTemporaryDirectory() + "macvis-barcode-fixture-\(UUID().uuidString).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    @Test("detect reads a rendered QR payload back and reports physical dimensions")
    func detectsQR() async throws {
        let payload = "https://example.com/ticket/abc123"
        let path = Self.renderQRFixture(payload)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await BarcodeEngine.detect(path: path)
        #expect(result.codes.count == 1)
        let code = try #require(result.codes.first)
        #expect(code.payload == payload)
        #expect(code.symbologyName == "qr")
        #expect(code.confidence > 0)
        #expect(result.imageWidth > 0 && result.imageHeight > 0)
    }

    @Test("detect reads a rendered Code128 payload back")
    func detectsCode128() async throws {
        let payload = "ABC12345"
        let path = Self.renderCode128Fixture(payload)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await BarcodeEngine.detect(path: path)
        #expect(result.codes.count == 1)
        let code = try #require(result.codes.first)
        #expect(code.payload == payload)
        #expect(code.symbologyName == "code128")
    }

    @Test("code_count is 0 (not an error) when no barcode is present")
    func noBarcodeIsEmptyNotError() async throws {
        let path = Self.renderBlankFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await BarcodeEngine.detect(path: path)
        #expect(result.codes.isEmpty)
        #expect(result.imageWidth == 200 && result.imageHeight == 200)
    }

    @Test("--symbology filter narrows detection to the requested symbologies")
    func symbologyFilterNarrowsResults() async throws {
        let path = Self.renderCode128Fixture("FILTERED1")
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Restricting to qr must not find the code128 barcode present in the image.
        let filtered = try await BarcodeEngine.detect(path: path, symbologies: ["qr"])
        #expect(filtered.codes.isEmpty)
        // Restricting to code128 (the actual symbology) still finds it.
        let matched = try await BarcodeEngine.detect(path: path, symbologies: ["code128"])
        #expect(matched.codes.count == 1)
    }

    @Test("an unknown --symbology name throws bad_request/unknown_symbology")
    func unknownSymbologyThrows() async throws {
        let path = Self.renderQRFixture("irrelevant")
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            _ = try await BarcodeEngine.detect(path: path, symbologies: ["not-a-real-symbology"])
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.reason == "unknown_symbology")
        }
    }

    // MARK: - qr command contract (VisionService.qr forces symbologies: ["qr"])

    // The `qr` CLI/MCP command has no --symbology flag: VisionService.qr(_:) always calls
    // through to this exact `symbologies: ["qr"]` filtered detect (VisionService itself has
    // no test target — see Package.swift — so this is the closest testable proxy for its
    // contract; the dispatch wiring itself is verified via release-binary E2E).

    @Test("symbologies: [\"qr\"] finds a QR code — the qr command's happy path")
    func qrOnlyFilterFindsQR() async throws {
        let payload = "qr-command-contract-check"
        let path = Self.renderQRFixture(payload)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await BarcodeEngine.detect(path: path, symbologies: ["qr"])
        #expect(result.codes.count == 1)
        #expect(result.codes.first?.payload == payload)
        #expect(result.codes.first?.symbologyName == "qr")
    }

    @Test("symbologies: [\"qr\"] reports code_count: 0 on a non-QR barcode — the qr command must not fall back to barcode's full scan")
    func qrOnlyFilterExcludesOtherSymbologies() async throws {
        let path = Self.renderCode128Fixture("qr-command-should-not-see-this")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await BarcodeEngine.detect(path: path, symbologies: ["qr"])
        #expect(result.codes.isEmpty)
        // Meanwhile the unrestricted scan (what `barcode` does) still finds it — proves the
        // qr/barcode divergence is the filter, not a broken fixture.
        let unrestricted = try await BarcodeEngine.detect(path: path)
        #expect(unrestricted.codes.count == 1)
    }

    // MARK: - data (base64) path — same logic, in-memory instead of disk

    @Test("detect(data:) reads the same QR payload as detect(path:)")
    func detectsFromData() async throws {
        let payload = "DataPathQR"
        let path = Self.renderQRFixture(payload)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try await BarcodeEngine.detect(data: data)
        #expect(result.codes.count == 1)
        #expect(result.codes.first?.payload == payload)
    }

    @Test("loading a missing file throws imageLoadFailed")
    func missingFileThrows() async {
        await #expect(throws: VisionError.self) {
            _ = try await BarcodeEngine.detect(path: "/no/such/file.png")
        }
    }

    @Test("garbage bytes → imageLoadFailed (not valid raster or PDF)")
    func garbageDataThrows() async {
        let garbage = Data(repeating: 0xAB, count: 64)
        await #expect(throws: VisionError.self) {
            _ = try await BarcodeEngine.detect(data: garbage)
        }
    }
}
#endif
