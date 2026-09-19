#if canImport(Vision)
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import VisionCore

@Suite("Iterative segmentation fixture")
struct SegmentationFixtureTests {
    @available(macOS 27, *)
    @Test(
        "point seed returns a grayscale mask separating foreground and background",
        .disabled("iterative segmentation assets are not ready; install them explicitly") {
            await SegmentationEngine.assetState() != .ready
        })
    func pointFixture() async throws {
        let width = 256, height = 256
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            Issue.record("fixture context creation failed"); return
        }
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 64, y: 64, width: 128, height: 128))
        guard let fixture = context.makeImage() else {
            Issue.record("fixture image creation failed"); return
        }

        let fixtureData = try pngData(fixture)
        let result = try await SegmentationEngine.segment(
            data: fixtureData, point: [128, 128], box: nil, quality: "fast",
            downloadAssets: false, page: 1, scale: 2)
        guard let result else { Issue.record("expected a mask"); return }
        guard let source = CGImageSourceCreateWithData(result.png as CFData, nil),
              let mask = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("mask is not a decodable PNG"); return
        }
        #expect(result.width == mask.width)
        #expect(result.height == mask.height)
        #expect(mask.colorSpace?.model == .monochrome)

        let samples = try grayBytes(mask)
        let center = samples[(mask.height / 2) * mask.width + mask.width / 2]
        let corner = samples[4 * mask.width + 4]
        #expect(abs(Int(center) - Int(corner)) > 32)
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
