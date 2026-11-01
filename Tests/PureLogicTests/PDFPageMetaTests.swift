import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VisionCore

@Suite("PDFPageMeta — page metadata and range errors")
struct PDFPageMetaTests {
    /// Blank pages only: no text drawing, so no CoreText font lookup in the test process.
    static func writeBlankPDF(pages: Int) -> String {
        let path = NSTemporaryDirectory() + "macvis-pdf-meta-\(UUID().uuidString).pdf"
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(mediaBox)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return path
    }

    static func writePNG() -> String {
        let path = NSTemporaryDirectory() + "macvis-pdf-meta-\(UUID().uuidString).png"
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(dest)
        return path
    }

    @Test("pdfPageCount(path:) reports the page count of a PDF file")
    func pageCountFromPath() {
        let path = Self.writeBlankPDF(pages: 3)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(OCREngine.pdfPageCount(path: path) == 3)
    }

    @Test("pdfPageCount(data:) reports the page count of PDF bytes")
    func pageCountFromData() throws {
        let path = Self.writeBlankPDF(pages: 3)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(OCREngine.pdfPageCount(data: data) == 3)
    }

    @Test("a raster image is not a PDF")
    func rasterIsNotPDF() throws {
        let path = Self.writePNG()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(OCREngine.pdfPageCount(path: path) == nil)
        #expect(OCREngine.pdfPageCount(data: try Data(contentsOf: URL(fileURLWithPath: path))) == nil)
    }

    @Test("arbitrary bytes are not a PDF")
    func garbageIsNotPDF() {
        #expect(OCREngine.pdfPageCount(data: Data("not a pdf".utf8)) == nil)
    }

    @Test("a PDF whose header starts after leading bytes is still a PDF")
    func headerAfterLeadingBytes() throws {
        let path = Self.writeBlankPDF(pages: 3)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shifted = Data(repeating: 0x20, count: 2000) + (try Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(OCREngine.pdfPageCount(data: shifted) == 3)
        let shiftedPath = path + ".shifted.pdf"
        defer { try? FileManager.default.removeItem(atPath: shiftedPath) }
        try shifted.write(to: URL(fileURLWithPath: shiftedPath))
        #expect(OCREngine.pdfPageCount(path: shiftedPath) == 3)
    }

    @Test("a decodable raster that also contains a PDF stays a raster, as in the loader")
    func rasterPolyglotIsNotPDF() throws {
        let png = Self.writePNG(), pdf = Self.writeBlankPDF(pages: 3)
        defer {
            try? FileManager.default.removeItem(atPath: png)
            try? FileManager.default.removeItem(atPath: pdf)
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: png)) + Data(contentsOf: URL(fileURLWithPath: pdf))
        #expect(OCREngine.pdfPageCount(data: bytes) == nil)
        let polyglotPath = png + ".polyglot.png"
        defer { try? FileManager.default.removeItem(atPath: polyglotPath) }
        try bytes.write(to: URL(fileURLWithPath: polyglotPath))
        #expect(OCREngine.pdfPageCount(path: polyglotPath) == nil)
    }

    @Test("isInRange accepts 1...pageCount only")
    func range() {
        #expect(PDFPageMeta(page: 1, pageCount: 3).isInRange)
        #expect(PDFPageMeta(page: 3, pageCount: 3).isInRange)
        #expect(!PDFPageMeta(page: 0, pageCount: 3).isInRange)
        #expect(!PDFPageMeta(page: 4, pageCount: 3).isInRange)
    }

    @Test("annotate prepends page and page_count and keeps the exit code")
    func annotate() {
        let meta = PDFPageMeta(page: 2, pageCount: 3)
        let out = meta.annotate(ServiceResult(.dict([("text", .string("x"))]), exitCode: 1))
        #expect(out.value == .dict([("page", .int(2)), ("page_count", .int(3)), ("text", .string("x"))]))
        #expect(out.exitCode == 1)
        #expect(meta.annotate(ServiceResult(.string("s"))).value == .string("s"))
    }

    @Test("outOfRangeError is a bad_request/page_out_of_range usage error naming the page count")
    func outOfRangeError() {
        let e = PDFPageMeta(page: 9, pageCount: 3).outOfRangeError()
        #expect(e.name == "bad_request")
        #expect(e.reason == "page_out_of_range")
        #expect(e.detail == "page 9 requested; this PDF has 3 page(s)")
        #expect(e.hint == "use a page from 1 to 3")
        #expect(e.exitCode == ExitCode.usage.rawValue)
    }
}
