import Testing
@testable import VisionCore

@Suite("Segmentation parameters")
struct SegmentationParameterTests {
    @Test("point uses top-left pixels and converts to Vision bottom-left normalized coordinates")
    func pointConversion() throws {
        let seed = try SegmentationParameters.seed(
            point: [25, 20], box: nil, imageWidth: 100, imageHeight: 80)
        #expect(seed == .point(.init(x: 0.25, y: 0.75)))
    }

    @Test("box uses top-left pixels and converts its bottom edge to Vision coordinates")
    func boxConversion() throws {
        let seed = try SegmentationParameters.seed(
            point: nil, box: [10, 20, 40, 30], imageWidth: 100, imageHeight: 100)
        #expect(seed == .box(.init(x: 0.1, y: 0.5, width: 0.4, height: 0.3)))
    }

    @Test(arguments: [
        (Optional<[Double]>.none, Optional<[Double]>.none),
        (Optional([10.0, 10.0]), Optional([0.0, 0.0, 20.0, 20.0])),
    ])
    func exactlyOneSeed(point: [Double]?, box: [Double]?) {
        #expect(throws: SegmentationParameterError.exactlyOneSeedRequired) {
            try SegmentationParameters.seed(
                point: point, box: box, imageWidth: 100, imageHeight: 100)
        }
    }

    @Test("a malformed supplied seed wins over XOR validation")
    func malformedSeedIsNotTreatedAsAbsent() {
        #expect(throws: SegmentationParameterError.invalidSeed) {
            try SegmentationParameters.seed(
                point: [.nan], box: [0, 0, 20, 20], imageWidth: 100, imageHeight: 100)
        }
    }

    @Test("seed syntax validates without decoded image dimensions")
    func seedSyntaxValidation() throws {
        try SegmentationParameters.validateSeed(point: [10, 20], box: nil)
        try SegmentationParameters.validateSeed(point: nil, box: [0, 0, 20, 20])
        #expect(throws: SegmentationParameterError.invalidSeed) {
            try SegmentationParameters.validateSeed(point: [.nan], box: nil)
        }
        #expect(throws: SegmentationParameterError.invalidSeed) {
            try SegmentationParameters.validateSeed(point: nil, box: [0, 0, 0, 20])
        }
        #expect(throws: SegmentationParameterError.exactlyOneSeedRequired) {
            try SegmentationParameters.validateSeed(point: nil, box: nil)
        }
    }

    @Test("malformed seed wins over a simulated macOS 26 availability failure")
    func validationPrecedesPlatformAvailability() {
        #expect(throws: SegmentationParameterError.invalidSeed) {
            try SegmentationEngine.preflight(
                point: [.nan], box: nil, quality: nil, platformAvailable: false)
        }

        do {
            try SegmentationEngine.preflight(
                point: [10, 20], box: nil, quality: nil, platformAvailable: false)
            Issue.record("expected needsMacOS27")
        } catch SegmentationEngineError.needsMacOS27 {
            // Expected: valid input reaches the simulated platform gate.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(arguments: [
        [10.0], [10.0, 20.0, 30.0], [-1.0, 10.0], [100.0, 10.0],
        [Double.nan, 10.0],
    ])
    func invalidPoints(point: [Double]) {
        #expect(throws: SegmentationParameterError.invalidSeed) {
            try SegmentationParameters.seed(
                point: point, box: nil, imageWidth: 100, imageHeight: 100)
        }
    }

    @Test(arguments: [
        [0.0, 0.0, 0.0, 20.0], [0.0, 0.0, 20.0, -1.0],
        [90.0, 0.0, 20.0, 20.0], [0.0, 90.0, 20.0, 20.0],
        [0.0, 0.0, 20.0],
    ])
    func invalidBoxes(box: [Double]) {
        #expect(throws: SegmentationParameterError.invalidSeed) {
            try SegmentationParameters.seed(
                point: nil, box: box, imageWidth: 100, imageHeight: 100)
        }
    }

    @Test("quality accepts exactly accurate, balanced, and fast")
    func quality() throws {
        #expect(try SegmentationParameters.quality(nil) == .balanced)
        #expect(try SegmentationParameters.quality("accurate") == .accurate)
        #expect(try SegmentationParameters.quality("balanced") == .balanced)
        #expect(try SegmentationParameters.quality("fast") == .fast)
        #expect(throws: SegmentationParameterError.invalidQuality) {
            try SegmentationParameters.quality("turbo")
        }
    }

    @Test("comma-separated CLI numeric lists reject malformed elements")
    func numericListParsing() throws {
        #expect(try SegmentationParameters.numericList("10.5,20") == [10.5, 20])
        #expect(throws: SegmentationParameterError.invalidSeed) {
            try SegmentationParameters.numericList("10,nope")
        }
    }
}
