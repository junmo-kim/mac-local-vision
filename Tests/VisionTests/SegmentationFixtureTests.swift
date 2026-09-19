#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import VisionCore

@Suite("Iterative segmentation fixture",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "Live segmentation needs locally installed assets; run it explicitly outside CI."))
struct SegmentationFixtureTests {
    @available(macOS 27, *)
    @Test("point and box seeds preserve input coordinates at every mask quality",
          arguments: [false, true], ["fast", "balanced", "accurate"])
    func seedFixture(useBox: Bool, quality: String) async throws {
        let width = 300, height = 200
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            Issue.record("fixture context creation failed"); return
        }
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 32, y: 88, width: 80, height: 80))
        guard let fixture = context.makeImage() else {
            Issue.record("fixture image creation failed"); return
        }

        let fixtureData = try pngData(fixture)
        let result = try await SegmentationEngine.segment(
            data: fixtureData, point: useBox ? nil : [72, 72],
            box: useBox ? [32, 32, 80, 80] : nil, quality: quality,
            downloadAssets: false, page: 1, scale: 2)
        guard let result else { Issue.record("expected a mask"); return }
        guard let source = CGImageSourceCreateWithData(result.png as CFData, nil),
              let mask = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("mask is not a decodable PNG"); return
        }
        #expect(result.width == mask.width)
        #expect(result.height == mask.height)
        #expect(result.imageWidth == width)
        #expect(result.imageHeight == height)
        #expect(mask.colorSpace?.model == .monochrome)

        let samples = try grayBytes(mask)
        let foreground = samples[(72 * mask.height / height) * mask.width + 72 * mask.width / width]
        let verticallyMirrored = samples[(128 * mask.height / height) * mask.width + 72 * mask.width / width]
        let corner = samples[4 * mask.width + 4]
        #expect(foreground > 180)
        #expect(verticallyMirrored < 80)
        #expect(corner < 80)
    }

    @available(macOS 27, *)
    @Test("PDF input dimensions describe the selected rasterization scale", arguments: [1, 2])
    func pdfDimensions(scale: Int) async throws {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var page = CGRect(x: 0, y: 0, width: 150, height: 100)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &page, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(page)
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 45, y: 20, width: 60, height: 60))
        context.endPDFPage()
        context.closePDF()
        let result = try #require(try await SegmentationEngine.segment(
            data: data as Data, point: [Double(75 * scale), Double(50 * scale)],
            box: nil, quality: "fast", downloadAssets: false, page: 1, scale: Double(scale)))
        #expect(result.imageWidth == 150 * scale)
        #expect(result.imageHeight == 100 * scale)
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else {
            throw SegmentationEngineError.maskEncodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SegmentationEngineError.maskEncodeFailed
        }
        return data as Data
    }

    private func grayBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw SegmentationEngineError.maskEncodeFailed }
        return bytes
    }
}
#endif
