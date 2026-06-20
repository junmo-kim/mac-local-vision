import Testing
@testable import VisionCore

@Suite("TextRanges — word splitting for per-word boxes")
struct TextRangesTests {
    private func words(_ s: String) -> [String] {
        TextRanges.words(in: s).map { String(s[$0]) }
    }

    @Test("splits on whitespace, keeps order")
    func basic() {
        #expect(words("탭 =+1. 가장 기본적인 카운터") == ["탭", "=+1.", "가장", "기본적인", "카운터"])
        #expect(words("For Time") == ["For", "Time"])
    }

    @Test("collapses runs of whitespace, trims ends")
    func whitespace() {
        #expect(words("  a   b  ") == ["a", "b"])
        #expect(words("single") == ["single"])
    }

    @Test("empty / whitespace-only yields no words")
    func empty() {
        #expect(words("").isEmpty)
        #expect(words("   ").isEmpty)
    }
}
