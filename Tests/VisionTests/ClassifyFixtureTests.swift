#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VisionCore

/// Tier ② (impl §2): exercise the real Vision classification path against synthetic
/// (non-photographic) fixtures — no static image assets in the repo, mirroring
/// `BarcodeFixtureTests`/`OCRFixtureTests.renderFixture`.
///
/// Test strategy (plan §2.6 Phase 0 spike, run 2026-07-12): `VNClassifyImageRequest`
/// always returns all 1,303 taxonomy identifiers (not just detections), and CoreGraphics
/// synthetic images (solid color / checkerboard / gradient) only ever produced noise —
/// observed max confidence ~0.09 across solid-color/checkerboard/gradient/blank fixtures,
/// with nonsensical top labels ("night_sky", "polka_dots"). Real photos gave meaningful
/// labels (confirming the feature works), but photo assets can't be committed to the repo
/// (convention: no static image assets). So these tests assert *behavior* — no throw,
/// confidence in [0,1], descending sort, minConfidence/top actually filtering/capping,
/// data/path parity, and structured errors on bad input — not exact label identifiers.
///
/// All `ClassifyEngine` entry points are `async` (see its type doc for why): concurrent
/// `VNClassifyImageRequest.perform()` calls deadlock, and only routing through a dedicated
/// serial queue via `.async` + a checked continuation (full suspension, not a lock/`.sync`)
/// avoids it. `ClassifyEngine.visionQueue` now serializes every call process-wide, so this
/// suite no longer needs `@Suite(.serialized)` — `concurrentCallsDoNotDeadlock` below is a
/// direct regression test for the fix (proves the suite's own tests running in parallel,
/// swift-testing's default, don't reproduce the hang that motivated the fix).
@Suite("ClassifyEngine — fixture classification (Vision-bound)",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Vision classification needs a real session — hangs on headless CI runners; runs locally."))
struct ClassifyFixtureTests {
    static func writePNG(_ image: CGImage) -> String {
        let path = NSTemporaryDirectory() + "macvis-classify-fixture-\(UUID().uuidString).png"
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return path
    }

    /// A solid-color fixture — Phase 0 spike observed max confidence ~0.05-0.09 across reds/greens.
    static func renderSolidColorFixture(width: Int = 256, height: Int = 256,
                                        r: CGFloat = 1, g: CGFloat = 0, b: CGFloat = 0) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return writePNG(ctx.makeImage()!)
    }

    /// A checkerboard fixture — Phase 0 spike observed max confidence ~0.038.
    static func renderCheckerboardFixture(width: Int = 256, height: Int = 256, tile: Int = 16) -> String {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        var y = 0, row = 0
        while y < height {
            var x = 0, col = 0
            while x < width {
                if (row + col) % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: tile, height: tile)) }
                x += tile; col += 1
            }
            y += tile; row += 1
        }
        return writePNG(ctx.makeImage()!)
    }

    /// A multi-page PDF where each page has a distinct `mediaBox` size — lets a test prove
    /// `--page`/`--scale` actually reached `OCREngine.loadImage` by checking the *rasterized
    /// dimensions* it returns, without depending on Vision's classification output (which,
    /// per this suite's fixtures, is just noise for synthetic content anyway).
    static func writeMultiPagePDF(pageSizes: [(width: CGFloat, height: CGFloat)]) -> String {
        let path = NSTemporaryDirectory() + "macvis-classify-pdf-\(UUID().uuidString).pdf"
        let url = URL(fileURLWithPath: path)
        let ctx = CGContext(url as CFURL, mediaBox: nil, nil)!
        for size in pageSizes {
            var mediaBox = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            let pageInfo = withUnsafeBytes(of: &mediaBox) { raw -> CFDictionary in
                let data = NSData(bytes: raw.baseAddress, length: raw.count)
                return [kCGPDFContextMediaBox as String: data] as CFDictionary
            }
            ctx.beginPDFPage(pageInfo)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return path
    }

    // MARK: - basic behavior (default min-confidence 0.1)

    @Test("classify runs without throwing on a synthetic image and returns image dimensions")
    func classifiesWithoutThrowing() async throws {
        let path = Self.renderSolidColorFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ClassifyEngine.classify(path: path)
        #expect(result.imageWidth == 256 && result.imageHeight == 256)
    }

    @Test("default min-confidence (0.1) yields zero labels for synthetic noise — not an error")
    func defaultThresholdExcludesSyntheticNoise() async throws {
        let path = Self.renderSolidColorFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ClassifyEngine.classify(path: path)
        #expect(result.labels.isEmpty)
    }

    @Test("every returned label's confidence is within [0, 1]")
    func confidenceInValidRange() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // minConfidence: 0 lets everything through so we have labels to check bounds on.
        let result = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 50)
        #expect(!result.labels.isEmpty)
        for label in result.labels {
            #expect(label.confidence >= 0.0 && label.confidence <= 1.0)
            #expect(!label.identifier.isEmpty)
        }
    }

    @Test("labels are sorted by confidence descending")
    func labelsSortedDescending() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 30)
        let confidences = result.labels.map(\.confidence)
        #expect(confidences == confidences.sorted(by: >))
    }

    // MARK: - --min-confidence actually filters

    @Test("raising min-confidence above the observed synthetic ceiling empties the result")
    func highMinConfidenceEmptiesResult() async throws {
        let path = Self.renderSolidColorFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ClassifyEngine.classify(path: path, minConfidence: 0.5)
        #expect(result.labels.isEmpty)
    }

    @Test("min-confidence: 0 admits far more labels than the default threshold")
    func lowMinConfidenceAdmitsMoreLabels() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let permissive = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 1303)
        let strict = try await ClassifyEngine.classify(path: path, minConfidence: 0.1, top: 1303)
        #expect(permissive.labels.count > strict.labels.count)
    }

    // MARK: - --top caps the count

    @Test("top caps the returned label count")
    func topCapsLabelCount() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 5)
        #expect(result.labels.count == 5)
    }

    @Test("default top (20) applies when top is not specified")
    func defaultTopAppliesWhenUnspecified() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ClassifyEngine.classify(path: path, minConfidence: 0.0)
        #expect(result.labels.count == 20)
    }

    @Test("top: 0 clamps to 1, not zero results")
    func topZeroClampsToOne() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 0)
        #expect(result.labels.count == 1)
    }

    // MARK: - data (base64) path — same logic, in-memory instead of disk

    @Test("classify(data:) matches classify(path:) for the same bytes")
    func dataPathMatchesFilePath() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fromPath = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 10)
        let fromData = try await ClassifyEngine.classify(data: data, minConfidence: 0.0, top: 10)
        #expect(fromPath.labels.map(\.identifier) == fromData.labels.map(\.identifier))
        #expect(fromPath.imageWidth == fromData.imageWidth)
        #expect(fromPath.imageHeight == fromData.imageHeight)
    }

    // MARK: - --page / --scale (PDF) — parity with barcode/ocr/find/ask, plan §2.6 amendment

    @Test("--page selects a distinct PDF page (proven via distinct rasterized dimensions)")
    func pageSelectsDistinctPDFPage() async throws {
        let path = Self.writeMultiPagePDF(pageSizes: [(100, 150), (300, 200)])
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Default scale (2.0) doubles each mediaBox dimension.
        let page1 = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 1, page: 1)
        let page2 = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 1, page: 2)
        #expect(page1.imageWidth == 200 && page1.imageHeight == 300)
        #expect(page2.imageWidth == 600 && page2.imageHeight == 400)
    }

    @Test("--scale changes the rasterized PDF page size")
    func scaleAffectsPDFRasterSize() async throws {
        let path = Self.writeMultiPagePDF(pageSizes: [(100, 150)])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let unscaled = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 1, page: 1, scale: 1.0)
        let doubled = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 1, page: 1, scale: 2.0)
        #expect(unscaled.imageWidth == 100 && unscaled.imageHeight == 150)
        #expect(doubled.imageWidth == 200 && doubled.imageHeight == 300)
    }

    @Test("classify(data:) also honors --page for a multi-page PDF")
    func dataPathHonorsPage() async throws {
        let path = Self.writeMultiPagePDF(pageSizes: [(100, 150), (300, 200)])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let page2 = try await ClassifyEngine.classify(data: data, minConfidence: 0.0, top: 1, page: 2)
        #expect(page2.imageWidth == 600 && page2.imageHeight == 400)
    }

    // MARK: - error paths

    @Test("loading a missing file throws imageLoadFailed")
    func missingFileThrows() async {
        await #expect(throws: VisionError.self) {
            _ = try await ClassifyEngine.classify(path: "/no/such/file.png")
        }
    }

    @Test("garbage bytes → imageLoadFailed (not valid raster or PDF)")
    func garbageDataThrows() async {
        let garbage = Data(repeating: 0xAB, count: 64)
        await #expect(throws: VisionError.self) {
            _ = try await ClassifyEngine.classify(data: garbage)
        }
    }

    // MARK: - availability probe

    @Test("classifyVisionAvailable() reports true on a machine that can run Vision requests")
    func availabilityProbeSucceeds() async {
        #expect(await ClassifyEngine.classifyVisionAvailable() == true)
    }

    // MARK: - concurrency regression (plan §2.6 Phase 5 hostile-review finding)

    /// Direct regression test for the deadlock found during hostile-review: N concurrent
    /// `Task`s each calling `ClassifyEngine.classify` used to hang indefinitely (reproduced
    /// standalone outside swift-testing entirely — 13 concurrent `Task {}`s, killed after
    /// 90s at near-zero CPU). `ClassifyEngine.visionQueue` now serializes every call via
    /// `.async` + continuation (full suspension), which resolved it in isolation testing.
    /// This test exercises the same shape directly against the production engine.
    @Test("N concurrent classify calls all complete (regression: used to deadlock before visionQueue serialization)")
    func concurrentCallsDoNotDeadlock() async throws {
        let path = Self.renderCheckerboardFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let concurrency = 13

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    let r = try await ClassifyEngine.classify(path: path, minConfidence: 0.0, top: 3)
                    return r.labels.count
                }
            }
            var collected: [Int] = []
            for try await count in group { collected.append(count) }
            return collected
        }

        #expect(results.count == concurrency)
        #expect(results.allSatisfy { $0 == 3 })
    }
}
#endif
