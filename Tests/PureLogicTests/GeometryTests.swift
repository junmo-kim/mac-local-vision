import Testing
@testable import VisionCore

@Suite("Geometry — Retina/top-left coordinate logic")
struct GeometryTests {
    @Test("normalized bottom-left rect flips to top-left pixel rect")
    func flipsToTopLeft() {
        // A box in the bottom-left quadrant of a 1000x1000 image.
        let n = NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        let px = Geometry.toPixelRect(n, imageWidth: 1000, imageHeight: 1000)
        // Bottom-left in Vision space -> bottom-left in screenshot space => top = 500.
        #expect(px.x == 0)
        #expect(px.y == 500)
        #expect(px.width == 500)
        #expect(px.height == 500)
    }

    @Test("center point lands at the rect middle")
    func centerPoint() {
        let n = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let px = Geometry.toPixelRect(n, imageWidth: 800, imageHeight: 600)
        #expect(px.centerX == 400)
        #expect(px.centerY == 300)
    }

    @Test("top-row word maps near y=0")
    func topRow() {
        // High y (near top in Vision's bottom-left space) -> small top pixel.
        let n = NormalizedRect(x: 0.1, y: 0.9, width: 0.2, height: 0.05)
        let px = Geometry.toPixelRect(n, imageWidth: 1000, imageHeight: 1000)
        #expect(px.y == 50) // (1 - (0.9 + 0.05)) * 1000
    }

    @Test("center rounds the half-extent for odd dimensions (no truncation drift)")
    func oddDimensionCenter() {
        // width 41: truncation would give +20 (center 30); rounding gives +21 (center 31).
        let px = PixelRect(x: 10, y: 10, width: 41, height: 41)
        #expect(px.centerX == 31)
        #expect(px.centerY == 31)
    }

    @Test("sanity filter rejects degenerate and absurd boxes")
    func sanity() {
        #expect(Geometry.isSane(NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)))
        #expect(!Geometry.isSane(NormalizedRect(x: 0, y: 0, width: 0, height: 0.1)))      // zero width
        #expect(!Geometry.isSane(NormalizedRect(x: 0, y: 0, width: 0.9, height: 0.001)))  // aspect blow-up
        #expect(!Geometry.isSane(NormalizedRect(x: 0, y: 0, width: 1.5, height: 0.1)))    // over-unit
    }

    // MARK: - toPixelPoint (document-bounds corner conversion — a general quad isn't a rect)

    @Test("normalized bottom-left point flips to top-left pixel point")
    func pointFlipsToTopLeft() {
        // Bottom-left corner in Vision space (0,0) -> bottom-left in screenshot space
        // => y = imageHeight (not 0).
        let p = Geometry.toPixelPoint(x: 0.0, y: 0.0, imageWidth: 1000, imageHeight: 800)
        #expect(p.x == 0)
        #expect(p.y == 800)
    }

    @Test("top-left in Vision space (high y) maps near pixel y=0")
    func pointTopMapsNearZero() {
        let p = Geometry.toPixelPoint(x: 0.2, y: 0.9, imageWidth: 1000, imageHeight: 1000)
        #expect(p.x == 200)
        #expect(p.y == 100) // (1 - 0.9) * 1000
    }

    // MARK: - NormalizedQuad.area (shoelace) + pickLargestQuad (document-bounds multi-doc policy)

    private func quad(_ tl: (Double, Double), _ tr: (Double, Double), _ br: (Double, Double), _ bl: (Double, Double),
                       confidence: Double = 0.9) -> NormalizedQuad {
        NormalizedQuad(
            topLeft: NormalizedPoint(x: tl.0, y: tl.1), topRight: NormalizedPoint(x: tr.0, y: tr.1),
            bottomRight: NormalizedPoint(x: br.0, y: br.1), bottomLeft: NormalizedPoint(x: bl.0, y: bl.1),
            confidence: confidence)
    }

    @Test("area of an axis-aligned unit-normalized rect quad matches width*height")
    func areaOfAxisAlignedQuad() {
        let q = quad((0.2, 0.8), (0.8, 0.8), (0.8, 0.2), (0.2, 0.2)) // a 0.6x0.6 square
        #expect(abs(q.area - 0.36) < 0.0001)
    }

    @Test("pickLargestQuad prefers the larger-area candidate")
    func pickLargestPrefersBiggerArea() {
        let small = quad((0.4, 0.6), (0.6, 0.6), (0.6, 0.4), (0.4, 0.4)) // 0.2x0.2
        let big = quad((0.1, 0.9), (0.9, 0.9), (0.9, 0.1), (0.1, 0.1))   // 0.8x0.8
        let picked = Geometry.pickLargestQuad([small, big], minConfidence: 0.0)
        #expect(picked == big)
    }

    @Test("pickLargestQuad filters out candidates below minConfidence")
    func pickLargestFiltersLowConfidence() {
        let lowConf = quad((0.1, 0.9), (0.9, 0.9), (0.9, 0.1), (0.1, 0.1), confidence: 0.1) // big but low-confidence
        let highConf = quad((0.4, 0.6), (0.6, 0.6), (0.6, 0.4), (0.4, 0.4), confidence: 0.9) // small but confident
        let picked = Geometry.pickLargestQuad([lowConf, highConf], minConfidence: 0.5)
        #expect(picked == highConf)
    }

    @Test("pickLargestQuad returns nil for an empty candidate list")
    func pickLargestEmptyIsNil() {
        #expect(Geometry.pickLargestQuad([], minConfidence: 0.0) == nil)
    }

    @Test("pickLargestQuad rejects insane (out-of-range) quads")
    func pickLargestRejectsInsaneQuad() {
        let insane = quad((0.1, 0.9), (0.9, 0.9), (0.9, 0.1), (-5.0, 0.1)) // corrupted corner
        let sane = quad((0.3, 0.7), (0.7, 0.7), (0.7, 0.3), (0.3, 0.3))
        let picked = Geometry.pickLargestQuad([insane, sane], minConfidence: 0.0)
        #expect(picked == sane)
    }

    @Test("pickLargestQuad excludes exact zero-confidence candidates even with minConfidence 0 — VNDetectDocumentSegmentationRequest always returns one full-frame candidate for a non-document scene, using confidence 0 as its sentinel (Phase 1 finding, not an empty results array like VNDetectBarcodesRequest)")
    func pickLargestExcludesZeroConfidenceSentinel() {
        let phantom = quad((0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0), confidence: 0.0) // full-frame phantom
        #expect(Geometry.pickLargestQuad([phantom], minConfidence: 0.0) == nil)
    }
}
