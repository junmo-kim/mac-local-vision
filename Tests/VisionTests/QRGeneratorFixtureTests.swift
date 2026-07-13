#if canImport(Vision)
import Testing
import Foundation
@testable import VisionCore

/// Tier ② (impl §2): the load-bearing test for `make-qr` — a QR is only useful if a
/// real scanner can read it back. Generates through the production `QRGenerator` and
/// re-scans through the production `BarcodeEngine.detect`, proving the two engines agree
/// end-to-end (plan §2.4: "생성한 QR을 자체 BarcodeEngine.detect로 다시 읽어 payload가
/// 일치하는지"). Vision-bound (via BarcodeEngine.detect) so this mirrors
/// BarcodeFixtureTests' CI-skip: hangs on headless CI runners, runs locally.
@Suite("QRGenerator — round-trip through BarcodeEngine.detect (Vision-bound)",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Vision barcode detection needs a real session — hangs on headless CI runners; runs locally."))
struct QRGeneratorFixtureTests {
    static func writeTempPNG(_ data: Data) throws -> String {
        let path = NSTemporaryDirectory() + "macvis-qrgen-fixture-\(UUID().uuidString).png"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("a generated QR round-trips through BarcodeEngine.detect with the same payload")
    func roundTrips() async throws {
        let payload = "https://example.com/ticket/xyz789"
        let result = try QRGenerator.generate(text: payload)
        let path = try Self.writeTempPNG(result.png)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let scan = try await BarcodeEngine.detect(path: path)
        #expect(scan.codes.count == 1)
        let code = try #require(scan.codes.first)
        #expect(code.payload == payload)
        #expect(code.symbologyName == "qr")
        #expect(scan.imageWidth == result.width && scan.imageHeight == result.height)
    }

    @Test("round-trips at every correction level")
    func roundTripsAllCorrectionLevels() async throws {
        for level in ["L", "M", "Q", "H"] {
            let payload = "correction-level-\(level)"
            let result = try QRGenerator.generate(text: payload, correctionLevel: level)
            let path = try Self.writeTempPNG(result.png)
            defer { try? FileManager.default.removeItem(atPath: path) }

            let scan = try await BarcodeEngine.detect(path: path)
            let code = try #require(scan.codes.first, "correction level \(level) failed to round-trip")
            #expect(code.payload == payload)
        }
    }

    @Test("round-trips at the minimum viable module scale (size: 1)")
    func roundTripsAtMinimumSize() async throws {
        // Establishes the floor referenced by QRGenerator.defaultModuleScale's doc comment:
        // even an unmagnified (1px/module) render must still be scannable, so the default
        // is chosen for robustness margin, not because smaller sizes are unreadable.
        let payload = "min-size-check"
        let result = try QRGenerator.generate(text: payload, size: 1)
        let path = try Self.writeTempPNG(result.png)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let scan = try await BarcodeEngine.detect(path: path)
        let code = try #require(scan.codes.first)
        #expect(code.payload == payload)
    }
}
#endif
