#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import VisionCore

/// Tier ② (impl §2): exercise the real `RecognizeDocumentsRequest` path against
/// CoreText/CoreGraphics-rendered fixtures — no static image assets in the repo,
/// mirroring `OCRFixtureTests.renderFixture`/`BarcodeFixtureTests.renderQRFixture`.
///
/// Phase 0 spike (plan §Phase 0, 2026-07-12) confirmed `.tables`/`.lists` are populated
/// correctly from exactly this kind of synthetic fixture (grid lines + cell text; bullet +
/// text) — no fallback fixture strategy was needed.
@Suite("DocumentOCREngine — fixture document OCR (Vision-bound)",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Vision document OCR needs a real session — it hangs on headless CI runners; runs locally."))
struct DocumentOCRFixtureTests {
    static func drawText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat) {
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, size, nil),
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    static func writePNG(_ ctx: CGContext) -> String {
        let path = NSTemporaryDirectory() + "macvis-dococr-fixture-\(UUID().uuidString).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    /// A 2-column x 3-row grid (header + 2 data rows) with cell text — renders the same
    /// layout validated by the Phase 0 spike.
    static func renderTableFixture(width: Int = 600, height: Int = 400) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(ctx, "Invoice 1234", x: 30, y: 350, size: 28)

        let originX: CGFloat = 40, originY: CGFloat = 100
        let cellW: CGFloat = 260, cellH: CGFloat = 60
        let cols = 2, rows = 3
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(2)
        for r in 0...rows {
            let y = originY + CGFloat(r) * cellH
            ctx.move(to: CGPoint(x: originX, y: y))
            ctx.addLine(to: CGPoint(x: originX + CGFloat(cols) * cellW, y: y))
        }
        for c in 0...cols {
            let x = originX + CGFloat(c) * cellW
            ctx.move(to: CGPoint(x: x, y: originY))
            ctx.addLine(to: CGPoint(x: x, y: originY + CGFloat(rows) * cellH))
        }
        ctx.strokePath()

        let content = [["Item", "Price"], ["Widget", "9.99"], ["Gadget", "19.99"]]
        for (rIdx, row) in content.enumerated() {
            let cellTopY = originY + CGFloat(rows - rIdx) * cellH
            let textY = cellTopY - cellH * 0.6
            for (cIdx, text) in row.enumerated() {
                let cellX = originX + CGFloat(cIdx) * cellW
                drawText(ctx, text, x: cellX + 20, y: textY, size: 22)
            }
        }
        return writePNG(ctx)
    }

    /// A table whose top row is a single cell merged across the full width (a title/header
    /// banner, no internal vertical divider in that row) sitting above a normal 2-column data
    /// grid — the shape a real invoice/receipt header commonly takes. Regression fixture for
    /// the hostile-review finding that using row 0's cell count for the column count silently
    /// dropped every column beyond 1 for exactly this layout (§Phase 1 fix, plan).
    static func renderMergedHeaderTableFixture(width: Int = 600, height: Int = 400) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let originX: CGFloat = 40, originY: CGFloat = 100
        let cellW: CGFloat = 260, cellH: CGFloat = 60
        let cols = 2, dataRows = 2, totalRows = dataRows + 1  // + merged header row
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(2)
        // Horizontal lines: one per row boundary, full width — including the header row.
        for r in 0...totalRows {
            let y = originY + CGFloat(r) * cellH
            ctx.move(to: CGPoint(x: originX, y: y))
            ctx.addLine(to: CGPoint(x: originX + CGFloat(cols) * cellW, y: y))
        }
        // Vertical lines: outer border spans the full table height, but the internal
        // column divider only spans the data rows — the header row has no vertical line
        // through it, so it reads as one merged cell.
        for c in 0...cols {
            let x = originX + CGFloat(c) * cellW
            let topY = (c == 0 || c == cols) ? originY + CGFloat(totalRows) * cellH : originY + CGFloat(dataRows) * cellH
            ctx.move(to: CGPoint(x: x, y: originY))
            ctx.addLine(to: CGPoint(x: x, y: topY))
        }
        ctx.strokePath()

        drawText(ctx, "INVOICE SUMMARY", x: originX + 30, y: originY + CGFloat(dataRows) * cellH + cellH * 0.35, size: 20)
        let content = [["Item", "Price"], ["Widget", "9.99"]]
        for (rIdx, row) in content.enumerated() {
            let cellTopY = originY + CGFloat(dataRows - rIdx) * cellH
            let textY = cellTopY - cellH * 0.6
            for (cIdx, text) in row.enumerated() {
                let cellX = originX + CGFloat(cIdx) * cellW
                drawText(ctx, text, x: cellX + 20, y: textY, size: 22)
            }
        }
        return writePNG(ctx)
    }

    /// Three bullet ("\u{2022}") items — renders the same layout validated by the Phase 0 spike.
    static func renderListFixture(width: Int = 500, height: Int = 300) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let items = ["First item", "Second item", "Third item"]
        var y: CGFloat = 240
        for item in items {
            drawText(ctx, "\u{2022}", x: 30, y: y, size: 24)
            drawText(ctx, item, x: 55, y: y, size: 24)
            y -= 50
        }
        return writePNG(ctx)
    }

    // MARK: - tables

    @Test("recognize extracts a table's row/column structure and exact cell text")
    func recognizesTable() async throws {
        let path = Self.renderTableFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await DocumentOCREngine.recognize(path: path)
        #expect(result.imageWidth == 600 && result.imageHeight == 400)
        #expect(result.tables.count == 1)
        let table = try #require(result.tables.first)
        #expect(table.rows == 3 && table.columns == 2)
        let cellTexts = Set(table.cells.map { "\($0.row),\($0.col):\($0.text)" })
        let expected: Set<String> = [
            "0,0:Item", "0,1:Price", "1,0:Widget", "1,1:9.99", "2,0:Gadget", "2,1:19.99",
        ]
        #expect(cellTexts == expected)
        #expect(Geometry.isSane(table.rect))
    }

    @Test("recognize(data:) reads the same table as recognize(path:)")
    func recognizesTableFromData() async throws {
        let path = Self.renderTableFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try await DocumentOCREngine.recognize(data: data)
        #expect(result.tables.count == 1)
        #expect(result.tables.first?.cells.count == 6)
    }

    /// Regression: a merged full-width header row above a normal 2-column data grid used to
    /// make `colCount` (derived from row 0's cell count) collapse to 1, silently dropping the
    /// second column ("Price"/"9.99") from every row and misreporting `columns`. Fixed by
    /// reading `table.columns.count` (the SDK's authoritative per-column view) instead.
    @Test("recognize does not drop columns for a table with a merged full-width header row")
    func recognizesTableWithMergedHeaderRow() async throws {
        let path = Self.renderMergedHeaderTableFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await DocumentOCREngine.recognize(path: path)
        #expect(result.tables.count == 1)
        let table = try #require(result.tables.first)
        #expect(table.columns == 2, "column count must come from table.columns, not row 0's width")
        let texts = Set(table.cells.map(\.text))
        #expect(texts.contains("Price"), "second column must not be dropped because the header row is merged")
        #expect(texts.contains("9.99"), "second column must not be dropped because the header row is merged")
    }

    // MARK: - lists

    @Test("recognize extracts a bulleted list's marker and item text")
    func recognizesList() async throws {
        let path = Self.renderListFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await DocumentOCREngine.recognize(path: path)
        #expect(result.lists.count == 1)
        let list = try #require(result.lists.first)
        #expect(list.items.count == 3)
        #expect(list.items.map { $0.text } == ["First item", "Second item", "Third item"])
        // itemString (not content.text.transcript) is used — marker is not duplicated into text.
        #expect(list.items.allSatisfy { !$0.text.contains("\u{2022}") })
        #expect(list.items.allSatisfy { $0.marker.contains("\u{2022}") })
    }

    // MARK: - paragraphs / title / full text

    @Test("recognize reports a title and the full transcript for a table image")
    func recognizesTitleAndText() async throws {
        let path = Self.renderTableFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await DocumentOCREngine.recognize(path: path)
        #expect(result.title?.contains("Invoice") == true)
        #expect(result.text.contains("Widget"))
        #expect(result.paragraphs.count >= 1)
    }

    // MARK: - errors

    @Test("loading a missing file throws imageLoadFailed")
    func missingFileThrows() async {
        do {
            _ = try await DocumentOCREngine.recognize(path: "/no/such/file.png")
            Issue.record("expected throw")
        } catch is VisionError {
            // expected
        } catch {
            Issue.record("expected VisionError, got \(error)")
        }
    }

    @Test("garbage bytes → imageLoadFailed (not valid raster or PDF)")
    func garbageDataThrows() async {
        let garbage = Data(repeating: 0xAB, count: 64)
        do {
            _ = try await DocumentOCREngine.recognize(data: garbage)
            Issue.record("expected throw")
        } catch is VisionError {
            // expected
        } catch {
            Issue.record("expected VisionError, got \(error)")
        }
    }
}
#endif
