#if canImport(FoundationModels)
import Testing
import Foundation
@testable import SemanticEngine

/// `mapCallError` decides the exit-code class (70/71/1) from whatever the framework throws.
/// It's the authoritative `ask` error router, so lock its keyword mapping in. (The real 27
/// error enum will refine these cases; the string fallback must stay correct meanwhile.)
// Deployment target is macOS 26, so AFMEngine (@available macOS 26) needs no guard here.
@Suite("AFMEngine.mapCallError — framework error routing")
struct MapCallErrorTests {
    private func error(_ message: String) -> Error {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @Test("device ineligibility → ineligible (exit 70 class)")
    func deviceIneligible() {
        guard case .ineligible(let reason, _, _) =
            AFMEngine.mapCallError(error("Model is not eligible for this device"))
        else { Issue.record("expected .ineligible"); return }
        #expect(reason == "device_not_eligible")
    }

    @Test("Apple Intelligence off → temporarilyUnavailable (exit 71 class)")
    func notEnabled() {
        guard case .temporarilyUnavailable(let reason, _, _) =
            AFMEngine.mapCallError(error("Apple Intelligence is not enabled"))
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "apple_intelligence_not_enabled")
    }

    @Test("model still downloading → temporarilyUnavailable (exit 71 class)")
    func modelNotReady() {
        guard case .temporarilyUnavailable(let reason, _, _) =
            AFMEngine.mapCallError(error("the model is not ready, still downloading"))
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "model_not_ready")
    }

    @Test("unmapped error → failed (exit 1 class), surfaces the raw message")
    func unmapped() {
        guard case .failed(let reason, let detail, _) =
            AFMEngine.mapCallError(error("guardrail tripped on output"))
        else { Issue.record("expected .failed"); return }
        #expect(reason == "ask_failed")
        #expect(detail.contains("guardrail"))
    }
}
#endif
