#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import VisionCore

/// Tier ② (impl §2): exercise the real Vision OCR path against a rendered fixture, so
/// `ocr`/`find` regressions are caught automatically rather than only by hand. Assertions
/// are deliberately loose (contains / in-bounds) — Vision output varies slightly by OS, so
/// exact-string matching would be flaky.
@Suite("OCREngine — fixture OCR (Vision-bound)")
struct OCRFixtureTests {
    /// Render `text` (black on white) to a unique temp PNG; returns its path.
    static func renderFixture(_ text: String, width: Int = 480, height: Int = 140) -> String {
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
        let img = ctx.makeImage()!
        // Unique name so parallel tests don't collide on the same path.
        let path = NSTemporaryDirectory() + "macvis-fixture-\(UUID().uuidString).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    @Test("recognize reads the rendered text and reports physical dimensions")
    func recognizesText() throws {
        let path = Self.renderFixture("Submit")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try OCREngine.recognize(path: path, languages: ["en-US"])
        #expect(result.fullText.contains("Submit"))
        #expect(result.imageWidth == 480 && result.imageHeight == 140)
        #expect(result.lines.count >= 1)
    }

    @Test("find returns an in-bounds center and the matched substring")
    func findsWord() throws {
        let path = Self.renderFixture("Submit")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let hit = try #require(try OCREngine.find(path: path, target: "Submit", languages: ["en-US"]))
        #expect(hit.textFound.contains("Submit"))
        #expect(hit.rect.centerX > 0 && hit.rect.centerX < 480)
        #expect(hit.rect.centerY > 0 && hit.rect.centerY < 140)
        #expect(hit.confidence > 0)
    }

    @Test("find returns nil for an absent word")
    func findsNothing() throws {
        let path = Self.renderFixture("Submit")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try OCREngine.find(path: path, target: "Cancel", languages: ["en-US"]) == nil)
    }

    @Test("loading a missing file throws imageLoadFailed")
    func missingFileThrows() {
        #expect(throws: VisionError.self) {
            _ = try OCREngine.recognize(path: "/no/such/file.png")
        }
    }
}
#endif
