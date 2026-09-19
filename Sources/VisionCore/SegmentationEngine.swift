import Foundation
import CoreGraphics
import ImageIO

#if canImport(Vision)
import Vision

public enum SegmentationAssetState: Equatable, Sendable {
    case needsMacOS27
    case notReady
    case downloading
    case failed(String)
    case ready
}

public enum SegmentationEngineError: Error, Sendable {
    case needsMacOS27
    case assetsNotReady(String?)
    case assetDownloadFailed(String)
    case requestFailed(String)
    case maskEncodeFailed
    case outputWriteFailed(String)
}

/// Pure orchestration for the explicit asset-download contract. The injected
/// closure makes the "never download without opt-in" rule testable without
/// installing Vision model assets on the test machine.
public enum SegmentationAssetPolicy {
    public static func prepare(
        initial: SegmentationAssetState,
        downloadAssets: Bool,
        download: () async throws -> SegmentationAssetState
    ) async throws {
        switch initial {
        case .ready:
            return
        case .needsMacOS27:
            throw SegmentationEngineError.needsMacOS27
        case .notReady, .downloading, .failed:
            guard downloadAssets else {
                throw SegmentationEngineError.assetsNotReady(detail(initial))
            }
        }
        let refreshed: SegmentationAssetState
        do {
            refreshed = try await download()
        } catch {
            throw SegmentationEngineError.assetDownloadFailed(String(describing: error))
        }
        guard refreshed == .ready else {
            throw SegmentationEngineError.assetsNotReady(detail(refreshed))
        }
    }

    private static func detail(_ state: SegmentationAssetState) -> String? {
        switch state {
        case .needsMacOS27: return "needs_macos_27"
        case .notReady: return "not_ready"
        case .downloading: return "downloading"
        case .failed(let detail): return detail
        case .ready: return nil
        }
    }
}

public struct SegmentationResult: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
}

public enum SegmentationEngine {
    static func preflight(
        point: [Double]?, box: [Double]?, quality: String?, platformAvailable: Bool
    ) throws {
        try SegmentationParameters.validateSeed(point: point, box: box)
        _ = try SegmentationParameters.quality(quality)
        guard platformAvailable else { throw SegmentationEngineError.needsMacOS27 }
    }

    public static func assetState() async -> SegmentationAssetState {
        guard #available(macOS 27, *) else { return .needsMacOS27 }
        let request = GenerateIterativeSegmentationRequest(
            seedPoint: Vision.NormalizedPoint(x: 0.5, y: 0.5))
        return await assetState(of: request)
    }

    @available(macOS 27, *)
    private static func makeRequest(seed: SegmentationSeed) -> GenerateIterativeSegmentationRequest {
        switch seed {
        case .point(let point):
            return GenerateIterativeSegmentationRequest(
                seedPoint: Vision.NormalizedPoint(x: point.x, y: point.y))
        case .box(let box):
            return GenerateIterativeSegmentationRequest(
                seedBox: Vision.NormalizedRect(
                    x: box.x, y: box.y, width: box.width, height: box.height))
        }
    }

    public static func segment(
        path: String, point: [Double]?, box: [Double]?, quality: String?,
        downloadAssets: Bool, page: Int, scale: Double
    ) async throws -> SegmentationResult? {
        guard #available(macOS 27, *) else {
            try preflight(
                point: point, box: box, quality: quality, platformAvailable: false)
            throw SegmentationEngineError.needsMacOS27
        }
        try preflight(
            point: point, box: box, quality: quality, platformAvailable: true)
        let image = try OCREngine.loadImage(path: path, page: page, scale: scale)
        return try await perform(
            image: image, point: point, box: box, quality: quality,
            downloadAssets: downloadAssets)
    }

    public static func segment(
        data: Data, point: [Double]?, box: [Double]?, quality: String?,
        downloadAssets: Bool, page: Int, scale: Double
    ) async throws -> SegmentationResult? {
        guard #available(macOS 27, *) else {
            try preflight(
                point: point, box: box, quality: quality, platformAvailable: false)
            throw SegmentationEngineError.needsMacOS27
        }
        try preflight(
            point: point, box: box, quality: quality, platformAvailable: true)
        let image = try OCREngine.loadImage(data: data, page: page, scale: scale)
        return try await perform(
            image: image, point: point, box: box, quality: quality,
            downloadAssets: downloadAssets)
    }

    @available(macOS 27, *)
    private static func perform(
        image: (cgImage: CGImage, width: Int, height: Int),
        point: [Double]?, box: [Double]?, quality: String?, downloadAssets: Bool
    ) async throws -> SegmentationResult? {
        let seed = try SegmentationParameters.seed(
            point: point, box: box, imageWidth: image.width, imageHeight: image.height)
        let parsedQuality = try SegmentationParameters.quality(quality)
        let request = makeRequest(seed: seed)
        switch parsedQuality {
        case .accurate: request.qualityLevel = .accurate
        case .balanced: request.qualityLevel = .balanced
        case .fast: request.qualityLevel = .fast
        }

        try await SegmentationAssetPolicy.prepare(
            initial: await assetState(of: request),
            downloadAssets: downloadAssets
        ) {
            try await request.downloadAssets()
            return await assetState(of: request)
        }

        do {
            guard let observation = try await request.perform(on: image.cgImage) else { return nil }
            return try encodeMask(observation)
        } catch let error as SegmentationEngineError {
            throw error
        } catch {
            throw SegmentationEngineError.requestFailed(String(describing: error))
        }
    }

    @available(macOS 27, *)
    private static func assetState(
        of request: GenerateIterativeSegmentationRequest
    ) async -> SegmentationAssetState {
        switch await request.assetStatus {
        case .notReady: return .notReady
        case .downloading: return .downloading
        case .ready: return .ready
        case .error(let error): return .failed(String(describing: error))
        @unknown default: return .failed("unknown asset status")
        }
    }

    @available(macOS 27, *)
    private static func encodeMask(_ observation: PixelBufferObservation) throws -> SegmentationResult {
        let source: CGImage
        do {
            source = try observation.cgImage
        } catch {
            throw SegmentationEngineError.maskEncodeFailed
        }
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let grayImage: CGImage? = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let grayImage else { throw SegmentationEngineError.maskEncodeFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else {
            throw SegmentationEngineError.maskEncodeFailed
        }
        CGImageDestinationAddImage(destination, grayImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SegmentationEngineError.maskEncodeFailed
        }
        return SegmentationResult(png: data as Data, width: width, height: height)
    }

    public static func writePNG(_ data: Data, to path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw SegmentationEngineError.outputWriteFailed(path)
        }
    }
}
#endif
