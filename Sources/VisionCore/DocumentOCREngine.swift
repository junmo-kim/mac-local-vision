import Foundation
import os

#if canImport(Vision)
import Vision
import CoreGraphics

/// A text block (title/paragraph) with its normalized box.
public struct DocumentTextBlock: Sendable {
    public let text: String
    public let rect: NormalizedRect
}

/// A single table cell's grid position and text (MVP scope — flattened, no recursive
/// content; see plan §2.4 Scope-out).
public struct DocumentTableCell: Sendable {
    public let row: Int
    public let col: Int
    public let text: String
}

public struct DocumentTable: Sendable {
    public let rows: Int
    public let columns: Int
    public let rect: NormalizedRect
    public let cells: [DocumentTableCell]
}

/// A single list item: its marker (e.g. "1.", "\u{2022} ") and item text with the marker
/// already stripped (`itemString`, not `content.text.transcript` which repeats the marker —
/// see Phase 0 spike finding, plan §Phase 0).
public struct DocumentListItem: Sendable {
    public let marker: String
    public let text: String
}

public struct DocumentList: Sendable {
    public let rect: NormalizedRect
    public let items: [DocumentListItem]
}

public struct DocumentOCRResult: Sendable {
    public let title: String?
    public let text: String
    public let paragraphs: [DocumentTextBlock]
    public let tables: [DocumentTable]
    public let lists: [DocumentList]
    public let imageWidth: Int
    public let imageHeight: Int
}

/// Vision-bound structured document OCR (`document-ocr`). Wraps `RecognizeDocumentsRequest`
/// (macOS 26.0+ — exactly this project's deployment baseline, no extra `@available` gate
/// needed; verified against the Vision.swiftinterface, plan §2.3). Unlike every other engine
/// in this file (`OCREngine`/`BarcodeEngine`, both synchronous `throws`), this request's
/// `perform(on:orientation:)` is `async throws` — a Swift-native Vision API, not the
/// `VNImageRequestHandler.perform([VNRequest])` pattern the others use. Mirrors `AFMEngine`'s
/// existing async shape rather than introducing a new one.
///
/// MVP scope (plan §2.4 Scope-out): title / full text / paragraphs / tables / lists only.
/// `detectedData` (entity extraction), per-word coordinates, and recursive nested
/// tables/lists-within-cells are out of scope — nested table-cell content is flattened to its
/// text via `content.text.transcript` rather than walked recursively. List items are the one
/// exception to that flattening rule: they read `itemString` instead (see `DocumentListItem`'s
/// doc comment) because `content.text.transcript` there duplicates the marker into the text.
public enum DocumentOCREngine {
    /// Real capability probe for `doctor` (mirrors `OCREngine.textVisionAvailable` /
    /// `BarcodeEngine.barcodeVisionAvailable`), adapted for this request's async API: runs a
    /// tiny blank image through the real request and reports whether it completes without
    /// throwing. Memoized for the process lifetime. Unlike the sibling probes' single
    /// `withLock` critical section, this one can't hold the lock across `await probe()` (unsafe
    /// with `OSAllocatedUnfairLock`), so two concurrent first-callers can each run the real
    /// probe once before the cache converges — harmless (idempotent, deterministic result), just
    /// not as strictly single-flight as the synchronous engines.
    public static func documentOCRAvailable() async -> Bool {
        if let cached = _probeCache.withLock({ $0 }) { return cached }
        let ok = await probe()
        _probeCache.withLock { $0 = ok }
        return ok
    }

    private static let _probeCache = OSAllocatedUnfairLock(initialState: Optional<Bool>.none)

    private static func probe() async -> Bool {
        guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage() else { return false }
        do {
            _ = try await RecognizeDocumentsRequest().perform(on: img, orientation: nil)
            return true
        } catch {
            return false
        }
    }

    // MARK: - recognize (path + data)

    public static func recognize(path: String, page: Int = 1, scale: Double = 2.0) async throws -> DocumentOCRResult {
        let (cgImage, width, height) = try OCREngine.loadImage(path: path, page: page, scale: scale)
        return try await recognizeCore(cgImage: cgImage, width: width, height: height)
    }

    public static func recognize(data: Data, page: Int = 1, scale: Double = 2.0) async throws -> DocumentOCRResult {
        let (cgImage, width, height) = try OCREngine.loadImage(data: data, page: page, scale: scale)
        return try await recognizeCore(cgImage: cgImage, width: width, height: height)
    }

    private static func recognizeCore(cgImage: CGImage, width: Int, height: Int) async throws -> DocumentOCRResult {
        let observations = try await RecognizeDocumentsRequest().perform(on: cgImage, orientation: nil)
        guard let observation = observations.first else {
            return DocumentOCRResult(title: nil, text: "", paragraphs: [], tables: [], lists: [],
                                     imageWidth: width, imageHeight: height)
        }
        // `.document: Container` — title/text/paragraphs/tables/lists nest under this, not
        // directly on `DocumentObservation` itself (swiftinterface, corrects plan §2.3's
        // flattened assumption — see Phase 0 spike finding).
        let doc = observation.document

        let paragraphs = doc.paragraphs.map(textBlock)
        let tables = doc.tables.map { table -> DocumentTable in
            let rowCount = table.rows.count
            // `table.columns.count`, not `table.rows.first?.count` — a merged header/title row
            // (a single cell spanning the full width, e.g. this exact `document-ocr` invoice
            // example's title banner above a normal N-column grid) makes row 0 narrower than
            // the table's true column count. `Table` exposes `columns: [[Cell]]` as the
            // authoritative per-column view precisely for this (SDK also carries per-cell
            // `rowRange`/`columnRange` for spans, out of MVP scope) — using row 0's width would
            // silently truncate every row to that narrower width and misreport `columns` too
            // (hostile-review finding, reproduced with a merged-header fixture: "Price"/"9.99"
            // vanished from `cells` and `columns` read 1 instead of 2).
            let colCount = table.columns.count
            var cells: [DocumentTableCell] = []
            for r in 0..<rowCount {
                for c in 0..<colCount {
                    guard let cell = table.cell(row: r, col: c) else { continue }
                    cells.append(DocumentTableCell(row: r, col: c, text: cell.content.text.transcript))
                }
            }
            return DocumentTable(rows: rowCount, columns: colCount,
                                 rect: normalized(table.boundingRegion.boundingBox), cells: cells)
        }
        let lists = doc.lists.map { list -> DocumentList in
            let items = list.items.map { DocumentListItem(marker: $0.markerString, text: $0.itemString) }
            return DocumentList(rect: normalized(list.boundingRegion.boundingBox), items: items)
        }

        return DocumentOCRResult(
            title: doc.title?.transcript,
            text: doc.text.transcript,
            paragraphs: paragraphs,
            tables: tables,
            lists: lists,
            imageWidth: width, imageHeight: height)
    }

    private static func textBlock(_ t: DocumentObservation.Container.Text) -> DocumentTextBlock {
        DocumentTextBlock(text: t.transcript, rect: normalized(t.boundingRegion.boundingBox))
    }

    /// `NormalizedRegion.boundingBox` is `Vision.NormalizedRect` (the Swift-native type this
    /// request family uses) — same bottom-left-origin, 0...1 convention as the legacy
    /// `CGRect`-based `VNRectangleObservation.boundingBox` that `OCREngine`/`BarcodeEngine`
    /// read (verified numerically in the Phase 0 spike: title/table pixel positions matched
    /// their rendered CoreGraphics coordinates exactly). `.cgRect` bridges it to a plain
    /// `CGRect` so `VisionCore.NormalizedRect` — and `Geometry.toPixelRect` — can be reused
    /// as-is, with no new coordinate-conversion logic for this engine.
    private static func normalized(_ region: Vision.NormalizedRect) -> NormalizedRect {
        let cg = region.cgRect
        return NormalizedRect(x: cg.origin.x, y: cg.origin.y, width: cg.size.width, height: cg.size.height)
    }
}
#endif
