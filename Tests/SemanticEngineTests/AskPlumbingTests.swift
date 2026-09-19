import Testing
@testable import SemanticEngine

@Suite("SemanticEngine — ask plumbing (no model)")
struct AskPlumbingTests {
    @Test("MockEngine returns its stub answer as an AskOutcome")
    func mockFlow() async throws {
        let out = try await MockEngine(response: "stub answer")
            .ask(imagePath: "/x.png", prompt: "q", stream: false, visionTools: false,
                 page: 1, scale: 2.0, schema: nil)
        #expect(out.text == "stub answer")
        #expect(out.compute == .onDevice)
    }

    @Test("MockEngine accepts the opt-in Vision tools path without changing the outcome contract")
    func mockVisionToolsFlow() async throws {
        let out = try await MockEngine(response: "tool-stub")
            .ask(imagePath: "/x.png", prompt: "read", stream: false, visionTools: true,
                 page: 1, scale: 2.0, schema: nil)
        #expect(out.text == "tool-stub")
        #expect(out.compute == .onDevice)
    }

    @Test("Vision tools select the intended session topology")
    func visionToolsSessionPlan() {
        #expect(AskSessionPlan.select(visionTools: false, hasSchema: false) == .plain)
        #expect(AskSessionPlan.select(visionTools: false, hasSchema: true) == .plain)
        #expect(AskSessionPlan.select(visionTools: true, hasSchema: false) == .tools)
        #expect(AskSessionPlan.select(visionTools: true, hasSchema: true) == .toolsThenSchema)
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
