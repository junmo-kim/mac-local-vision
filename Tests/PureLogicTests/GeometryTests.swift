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
}
