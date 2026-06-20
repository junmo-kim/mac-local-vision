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
}
