import Testing
import Foundation
@testable import VisionCore

/// Pure validation logic (no Vision session, no CI-skip) — `QRGenerator` wraps
/// `CIFilter("CIQRCodeGenerator")`, a plain CoreImage filter with no Vision dependency
/// (plan §2.3), so unlike `BarcodeFixtureTests`/`BarcodeSymbologyTests` this suite needs
/// no `.enabled(if: CI == nil)` guard.
@Suite("QRGenerator — pure validation logic (no Vision session)")
struct QRGeneratorPureTests {
    @Test("empty text throws bad_request/missing_text")
    func emptyTextThrows() {
        do {
            _ = try QRGenerator.generate(text: "")
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.name == "bad_request")
            #expect(se?.reason == "missing_text")
            #expect(se?.hint == "make-qr requires non-empty text to encode")
        }
    }

    @Test("an invalid correction level throws bad_request/invalid_correction_level")
    func invalidCorrectionLevelThrows() {
        do {
            _ = try QRGenerator.generate(text: "payload", correctionLevel: "Z")
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.name == "bad_request")
            #expect(se?.reason == "invalid_correction_level")
            #expect(se?.detail == "Z")
        }
    }

    @Test("valid correction levels L/M/Q/H all succeed")
    func validCorrectionLevelsSucceed() throws {
        for level in ["L", "M", "Q", "H"] {
            let result = try QRGenerator.generate(text: "ok", correctionLevel: level)
            #expect(result.png.count > 0)
            #expect(result.width > 0 && result.height > 0)
        }
    }

    @Test("size clamps to a minimum of 1 module-pixel rather than a degenerate image")
    func sizeClampsToMinimum() throws {
        let result = try QRGenerator.generate(text: "small", size: 0)
        #expect(result.width > 0 && result.height > 0)
    }

    @Test("a larger size produces a proportionally larger image")
    func sizeScalesOutput() throws {
        let small = try QRGenerator.generate(text: "scale-check", size: 4)
        let large = try QRGenerator.generate(text: "scale-check", size: 8)
        #expect(large.width == small.width * 2)
        #expect(large.height == small.height * 2)
    }

    @Test("an oversized --size throws bad_request/size_too_large instead of allocating a huge image")
    func sizeTooLargeThrows() {
        do {
            _ = try QRGenerator.generate(text: "size-cap-check", size: 20_000)
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.name == "bad_request")
            #expect(se?.reason == "size_too_large")
        }
    }

    @Test("a comfortably large but reasonable size still succeeds (no over-eager clamp)")
    func largeButReasonableSizeSucceeds() throws {
        // ~21x21 modules for a short payload (version 1/M) at size:300 -> 6300x6300px
        // (~39.7MP), comfortably below the 100MP raster cap — confirms the new guard
        // doesn't reject ordinary (if generous) --size values, only pathological ones.
        let result = try QRGenerator.generate(text: "boundary-check", size: 300)
        #expect(result.width > 0 && result.height > 0)
    }

    @Test("writing to a nonexistent directory throws a structured generate_qr_failed/write_failed ServiceError, not a raw Cocoa error")
    func writeToNonexistentDirectoryThrowsStructuredError() {
        let badPath = NSTemporaryDirectory() + "macvis-qrgen-missing-dir-\(UUID().uuidString)/qr.png"
        do {
            try QRGenerator.writePNG(Data([0x1, 0x2, 0x3]), to: badPath)
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.name == "generate_qr_failed")
            #expect(se?.reason == "write_failed")
            #expect(se?.detail == badPath)
            #expect(se?.hint != nil)
        }
    }

    @Test("writing to a valid path succeeds and the bytes round-trip")
    func writeToValidPathSucceeds() throws {
        let path = NSTemporaryDirectory() + "macvis-qrgen-write-ok-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bytes = Data([0x1, 0x2, 0x3])
        try QRGenerator.writePNG(bytes, to: path)
        #expect(FileManager.default.contents(atPath: path) == bytes)
    }
}
