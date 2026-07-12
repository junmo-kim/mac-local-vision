#if canImport(Vision)
import Testing
@testable import VisionCore

/// Pure lookup/clamp logic — no Vision session, so this belongs in PureLogicTests (tier
/// ①) alongside BarcodeSymbologyTests/ClampedRasterSizeTests.
@Suite("ClassifyEngine — defaults and top clamp (pure logic, no Vision session)")
struct ClassifyPureTests {
    @Test("default min-confidence is 0.1 (Phase 0 spike: cuts synthetic noise ceiling ~0.09, keeps real-photo signal)")
    func defaultMinConfidenceIsPointOne() {
        #expect(ClassifyEngine.defaultMinConfidence == 0.1)
    }

    @Test("default top is 20 (Phase 0 spike: bounds worst-case label count)")
    func defaultTopIsTwenty() {
        #expect(ClassifyEngine.defaultTop == 20)
    }

    @Test("effectiveTop falls back to the default when nil")
    func effectiveTopDefaultsWhenNil() {
        #expect(ClassifyEngine.effectiveTop(nil) == 20)
    }

    @Test("effectiveTop clamps to a floor of 1 (never 0 or negative)")
    func effectiveTopClampsToOne() {
        #expect(ClassifyEngine.effectiveTop(0) == 1)
        #expect(ClassifyEngine.effectiveTop(-5) == 1)
    }

    @Test("effectiveTop passes a positive value through unchanged")
    func effectiveTopPassesThroughPositive() {
        #expect(ClassifyEngine.effectiveTop(5) == 5)
        #expect(ClassifyEngine.effectiveTop(1) == 1)
    }
}
#endif
