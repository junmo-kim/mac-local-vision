import Testing
@testable import SemanticEngine

@Suite("SemanticEngine — ask plumbing (no model)")
struct AskPlumbingTests {
    @Test("MockEngine returns its stub answer as an AskOutcome")
    func mockFlow() async throws {
        let out = try await MockEngine(response: "stub answer")
            .ask(imagePath: "/x.png", prompt: "q", stream: false, page: 1, scale: 2.0, schema: nil)
        #expect(out.text == "stub answer")
        #expect(out.compute == .onDevice)
    }

    @Test("AskCompute raw value is the documented wire string")
    func computeRawValues() {
        #expect(AskCompute.onDevice.rawValue == "on-device")
    }

    @Test("SemanticError cases carry their structured fields")
    func semanticErrorFields() {
        if case .ineligible(let reason, let detail, let hint)
            = SemanticError.ineligible(reason: "r", detail: "d", hint: "h") {
            #expect(reason == "r" && detail == "d" && hint == "h")
        } else {
            Issue.record("expected .ineligible")
        }
        if case .failed(let reason, _, _) = SemanticError.failed(reason: "x", detail: "", hint: "") {
            #expect(reason == "x")
        } else {
            Issue.record("expected .failed")
        }
    }
}
