import Testing
import CoreGraphics
@testable import VisionCore

@Suite("OCREngine.clampedRasterSize — PDF raster allocation bound")
struct ClampedRasterSizeTests {
    @Test("a normal page scales to integer pixels")
    func normal() {
        let s = OCREngine.clampedRasterSize(boxWidth: 612, boxHeight: 792, scale: 2.0)  // US Letter @144dpi
        #expect(s?.width == 1224 && s?.height == 1584)
    }

    @Test("rejects empty, non-finite, and overflowing sizes (no Int trap)")
    func rejectsPathological() {
        #expect(OCREngine.clampedRasterSize(boxWidth: 0, boxHeight: 100, scale: 2.0) == nil)        // empty
        #expect(OCREngine.clampedRasterSize(boxWidth: .infinity, boxHeight: 100, scale: 2.0) == nil) // inf
        #expect(OCREngine.clampedRasterSize(boxWidth: 1e200, boxHeight: 1e200, scale: 1.0) == nil)   // would trap Int()
        #expect(OCREngine.clampedRasterSize(boxWidth: 100_000, boxHeight: 100_000, scale: 2.0) == nil) // 4e10 px > cap
    }

    @Test("respects an explicit cap")
    func customCap() {
        #expect(OCREngine.clampedRasterSize(boxWidth: 1000, boxHeight: 1000, scale: 1.0, maxPixels: 100) == nil)
        #expect(OCREngine.clampedRasterSize(boxWidth: 8, boxHeight: 8, scale: 1.0, maxPixels: 100)?.width == 8)
    }
}
