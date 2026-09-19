import Foundation

public enum SegmentationParameterError: Error, Equatable, Sendable {
    case exactlyOneSeedRequired
    case invalidSeed
    case invalidQuality
}

public enum SegmentationSeed: Equatable, Sendable {
    case point(NormalizedPoint)
    case box(NormalizedRect)
}

public enum SegmentationQuality: String, Equatable, Sendable {
    case accurate
    case balanced
    case fast
}

/// Pure validation and top-left-pixel → Vision-normalized conversion for `segment`.
public enum SegmentationParameters {
    public static func numericList(_ raw: String) throws -> [Double] {
        let pieces = raw.split(separator: ",", omittingEmptySubsequences: false)
        let values = pieces.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == pieces.count, values.allSatisfy(\.isFinite) else {
            throw SegmentationParameterError.invalidSeed
        }
        return values
    }

    public static func quality(_ raw: String?) throws -> SegmentationQuality {
        guard let raw else { return .balanced }
        guard let quality = SegmentationQuality(rawValue: raw) else {
            throw SegmentationParameterError.invalidQuality
        }
        return quality
    }

    /// Validate the parts of a seed that do not depend on the decoded image size.
    /// Adapters call this before platform availability checks so malformed input
    /// has the same error contract on every supported macOS version.
    public static func validateSeed(point: [Double]?, box: [Double]?) throws {
        if let point {
            guard point.count == 2, point.allSatisfy(\.isFinite),
                  point[0] >= 0, point[1] >= 0 else {
                throw SegmentationParameterError.invalidSeed
            }
        }
        if let box {
            guard box.count == 4, box.allSatisfy(\.isFinite),
                  box[0] >= 0, box[1] >= 0, box[2] > 0, box[3] > 0 else {
                throw SegmentationParameterError.invalidSeed
            }
        }
        guard (point == nil) != (box == nil) else {
            throw SegmentationParameterError.exactlyOneSeedRequired
        }
    }

    public static func seed(
        point: [Double]?, box: [Double]?, imageWidth: Int, imageHeight: Int
    ) throws -> SegmentationSeed {
        try validateSeed(point: point, box: box)
        guard imageWidth > 0, imageHeight > 0 else {
            throw SegmentationParameterError.invalidSeed
        }
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        if let point {
            guard point[0] < width, point[1] < height else {
                throw SegmentationParameterError.invalidSeed
            }
            return .point(.init(x: point[0] / width, y: 1 - point[1] / height))
        }
        guard let box else {
            throw SegmentationParameterError.invalidSeed
        }
        let x = box[0], y = box[1], boxWidth = box[2], boxHeight = box[3]
        guard x + boxWidth <= width, y + boxHeight <= height else {
            throw SegmentationParameterError.invalidSeed
        }
        return .box(.init(
            x: x / width,
            y: 1 - ((y + boxHeight) / height),
            width: boxWidth / width,
            height: boxHeight / height))
    }
}
