import Testing
@testable import VisionCore

@Suite("Languages — locale-aware recognition language defaults")
struct LanguagesTests {
    // A representative slice of Vision's supported set.
    let supported = ["en-US", "fr-FR", "de-DE", "es-ES", "zh-Hans", "ko-KR", "ja-JP"]

    @Test("Korean locale -> ko-KR + en fallback")
    func korean() {
        #expect(Languages.resolve(preferred: ["ko-KR", "en-US"], supported: supported) == ["ko-KR", "en-US"])
    }

    @Test("German-only locale still gets English fallback appended")
    func german() {
        #expect(Languages.resolve(preferred: ["de-DE"], supported: supported) == ["de-DE", "en-US"])
    }

    @Test("subtag match: bare 'ja' resolves to ja-JP; en-GB folds to en-US")
    func subtagMatching() {
        #expect(Languages.resolve(preferred: ["ja"], supported: supported) == ["ja-JP", "en-US"])
        #expect(Languages.resolve(preferred: ["en-GB"], supported: supported) == ["en-US"])
    }

    @Test("unsupported locale falls back to English")
    func unsupported() {
        #expect(Languages.resolve(preferred: ["sw-KE"], supported: supported) == ["en-US"])
    }

    @Test("empty preferred falls back to English")
    func empty() {
        #expect(Languages.resolve(preferred: [], supported: supported) == ["en-US"])
    }

    @Test("no English in engine -> first supported, no phantom append")
    func noEnglishSupported() {
        #expect(Languages.resolve(preferred: ["ko-KR"], supported: ["ko-KR", "ja-JP"]) == ["ko-KR"])
        #expect(Languages.resolve(preferred: ["xx"], supported: ["ko-KR", "ja-JP"]) == ["ko-KR"])
    }
}
