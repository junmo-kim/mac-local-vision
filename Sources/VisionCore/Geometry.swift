import Foundation

/// A normalized rectangle as returned by Apple Vision: origin is **bottom-left**,
/// all components are in the `0...1` range relative to image size.
public struct NormalizedRect: Equatable, Sendable {
    public let x: Double       // minX (left edge)
    public let y: Double       // minY (bottom edge, bottom-left origin)
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A pixel-space rectangle with a **top-left** origin — matching screenshot /
/// Playwright coordinate conventions, which is what E2E callers expect.
public struct PixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Center point — the value an agent clicks/asserts on. Rounds the half-extent
    /// (integer `width / 2` would truncate, biasing the click point up-left for odd sizes).
    public var centerX: Int { x + Int((Double(width) / 2.0).rounded()) }
    public var centerY: Int { y + Int((Double(height) / 2.0).rounded()) }
}

/// Pure coordinate / sanity logic. No Apple-framework imports here on purpose:
/// this is the layer that is unit-testable on any runner (architecture §5, impl §2 tier ①).
public enum Geometry {
    /// Convert a Vision normalized rect (bottom-left origin) into a top-left-origin
    /// pixel rect against the image's *physical* pixel dimensions.
    ///
    /// Defends against the Retina/viewport mismatch (architecture §5.1): callers must
    /// pass physical pixels read from `CGImageGetWidth/Height`, never a logical viewport.
    public static func toPixelRect(_ n: NormalizedRect, imageWidth: Int, imageHeight: Int) -> PixelRect {
        let w = n.width * Double(imageWidth)
        let h = n.height * Double(imageHeight)
        let xPx = n.x * Double(imageWidth)
        // Flip the y axis: Vision's bottom-left origin -> screenshot top-left origin.
        let yTop = (1.0 - (n.y + n.height)) * Double(imageHeight)
        return PixelRect(
            x: Int(xPx.rounded()),
            y: Int(yTop.rounded()),
            width: Int(w.rounded()),
            height: Int(h.rounded())
        )
    }

    /// Outlier filter for motion-blur / mis-detected boxes (architecture §5.3).
    /// Rejects degenerate (zero/over-unit) rects and absurd aspect ratios.
    public static func isSane(_ n: NormalizedRect, maxAspect: Double = 50.0) -> Bool {
        guard n.width > 0, n.height > 0 else { return false }
        guard n.x >= -0.0001, n.y >= -0.0001 else { return false }
        guard n.width <= 1.0001, n.height <= 1.0001 else { return false }
        let aspect = max(n.width / n.height, n.height / n.width)
        return aspect <= maxAspect
    }

    /// Convert a single Vision normalized point (bottom-left origin) into a top-left-origin
    /// physical pixel point — the per-point analogue of `toPixelRect`, needed for
    /// `document-bounds`'s corner quad (a general quadrilateral isn't expressible as a
    /// single axis-aligned `NormalizedRect`).
    public static func toPixelPoint(x: Double, y: Double, imageWidth: Int, imageHeight: Int) -> (x: Int, y: Int) {
        let xPx = x * Double(imageWidth)
        let yTop = (1.0 - y) * Double(imageHeight)
        return (Int(xPx.rounded()), Int(yTop.rounded()))
    }

    /// Pick the best document quad among Vision's candidate observations: filter to sane,
    /// `minConfidence`-passing quads, then prefer the largest by area. Handles the "multiple
    /// documents in one frame" policy question for `document-bounds`/`rectify-document` — a
    /// stray second document/receipt shouldn't outrank the primary subject just because
    /// Vision listed it first.
    ///
    /// Exact-zero confidence is always excluded, independent of `minConfidence` (even 0.0):
    /// `VNDetectDocumentSegmentationRequest` always returns exactly one candidate — for a
    /// non-document scene it's a near-full-frame quad at confidence 0.0, its sentinel for
    /// "not a document" (unlike `VNDetectBarcodesRequest`, which returns an empty array).
    /// Treating confidence 0 as a legitimate `minConfidence: 0` match would surface that
    /// sentinel as a fake detection.
    public static func pickLargestQuad(_ candidates: [NormalizedQuad], minConfidence: Double) -> NormalizedQuad? {
        candidates
            .filter { $0.isSane && $0.confidence > 0 && $0.confidence >= minConfidence }
            .max { $0.area < $1.area }
    }
}

/// A single normalized (bottom-left origin) point, `0...1` relative to image size —
/// `NormalizedRect`'s point-only counterpart, for quads that aren't axis-aligned rects.
public struct NormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A candidate document quadrilateral as reported by `VNDetectDocumentSegmentationRequest`
/// — plain `NormalizedPoint`s (not `CGPoint`/`VNRectangleObservation`) so this type stays
/// Vision-independent and unit-testable from `PureLogicTests`.
public struct NormalizedQuad: Equatable, Sendable {
    public let topLeft: NormalizedPoint
    public let topRight: NormalizedPoint
    public let bottomRight: NormalizedPoint
    public let bottomLeft: NormalizedPoint
    public let confidence: Double

    public init(topLeft: NormalizedPoint, topRight: NormalizedPoint, bottomRight: NormalizedPoint,
                bottomLeft: NormalizedPoint, confidence: Double) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
        self.confidence = confidence
    }

    /// Shoelace-formula area in normalized units — the ranking key `pickLargestQuad` uses
    /// to choose among multiple detected documents.
    public var area: Double {
        let pts = [topLeft, topRight, bottomRight, bottomLeft]
        var sum = 0.0
        for i in 0..<pts.count {
            let p1 = pts[i], p2 = pts[(i + 1) % pts.count]
            sum += p1.x * p2.y - p2.x * p1.y
        }
        return abs(sum) / 2
    }

    /// True when all 4 corners are finite and within a small tolerance of the valid
    /// normalized range — the point-wise analogue of `Geometry.isSane`, applied per-corner
    /// since a document quad isn't necessarily axis-aligned.
    public var isSane: Bool {
        [topLeft, topRight, bottomRight, bottomLeft].allSatisfy {
            $0.x.isFinite && $0.y.isFinite &&
            $0.x >= -0.0001 && $0.x <= 1.0001 && $0.y >= -0.0001 && $0.y <= 1.0001
        }
    }
}
