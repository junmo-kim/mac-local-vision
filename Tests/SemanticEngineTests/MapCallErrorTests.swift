#if canImport(FoundationModels)
import Testing
import Foundation
import FoundationModels
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

    @Test("localized assets unavailable message → temporarilyUnavailable (exit 71 class)")
    func modelAssetsUnavailableMessage() {
        guard case .temporarilyUnavailable(let reason, _, _) =
            AFMEngine.mapCallError(error("Language model assets are unavailable."))
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "model_assets_unavailable")
    }

    @available(macOS 27, *)
    @Test("SystemLanguageModel assets unavailable → temporarilyUnavailable (exit 71 class)")
    func modelAssetsUnavailableTyped() {
        let unavailable = SystemLanguageModel.Error.assetsUnavailable(
            .init(debugDescription: "test assets are unavailable"))
        guard case .temporarilyUnavailable(let reason, _, _) =
            AFMEngine.mapCallError(unavailable)
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "model_assets_unavailable")
    }

    @available(macOS 27, *)
    @Test("LanguageModelSession concurrent request → temporarilyUnavailable (exit 71 class)")
    func concurrentRequests() {
        guard case .temporarilyUnavailable(let reason, _, _) =
            AFMEngine.mapCallError(LanguageModelSession.Error.concurrentRequests)
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "session_busy")
    }

    @available(macOS 27, *)
    @Test("LanguageModelSession transcript mutation → failed (exit 1 class)")
    func transcriptMutationWhileResponding() {
        guard case .failed(let reason, _, _) =
            AFMEngine.mapCallError(LanguageModelSession.Error.transcriptMutationWhileResponding)
        else { Issue.record("expected .failed"); return }
        #expect(reason == "session_mutation_while_responding")
    }

    @Test("safety model still loading → temporarilyUnavailable (exit 71 class)")
    func contentSafetyModelNotReady() {
        guard case .temporarilyUnavailable(let reason, _, _) =
            AFMEngine.mapCallError(error("""
                Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 \
                UserInfo={NSMultipleUnderlyingErrorsKey=(
                "Error Domain=com.apple.SensitiveContentAnalysisML Code=15 \
                UserInfo={NSMultipleUnderlyingErrorsKey=(
                "Error Domain=ModelManagerServices.ModelManagerError Code=1041 \"(null)\""
                )}"
                )}
                """))
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "content_safety_model_not_ready")
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

/// `mapAvailabilityError` is the pre-flight gate `ask()` consults before touching
/// LanguageModelSession/Attachment — the fix for a SIGSEGV on an early macOS 27 build when
/// the model isn't ready. Pure function, no live FoundationModels state
/// needed, so lock its `AskAvailability` → `SemanticError`/nil mapping in directly.
@Suite("AFMEngine.mapAvailabilityError — pre-flight gate mapping")
struct MapAvailabilityErrorTests {
    @Test("older macOS returns the image-input OS gate without probing the model")
    func oldOSSkipsModelProbe() {
        var probedModel = false
        let availability = resolveAskAvailability(
            supportsImageInput: false,
            readModelAvailability: {
                probedModel = true
                return .available
            })

        #expect(availability == .osTooOld(reason: "needs_macos_27_for_image_input"))
        #expect(!probedModel)
    }

    @Test(".available → nil (safe to proceed)")
    func available() {
        #expect(AFMEngine.mapAvailabilityError(.available) == nil)
    }

    @Test(".ineligible → ineligible (exit 70 class)")
    func ineligible() {
        guard case .ineligible(let reason, _, _) =
            AFMEngine.mapAvailabilityError(.ineligible(reason: "device_not_eligible"))
        else { Issue.record("expected .ineligible"); return }
        #expect(reason == "device_not_eligible")
    }

    @Test(".osTooOld → ineligible (exit 70 class)")
    func osTooOld() {
        guard case .ineligible(let reason, _, _) =
            AFMEngine.mapAvailabilityError(.osTooOld(reason: "needs_macos_27_for_image_input"))
        else { Issue.record("expected .ineligible"); return }
        #expect(reason == "needs_macos_27_for_image_input")
    }

    @Test(".notReady(apple_intelligence_not_enabled) → temporarilyUnavailable (exit 71 class)")
    func notReadyIntelligenceOff() {
        guard case .temporarilyUnavailable(let reason, let detail, _) =
            AFMEngine.mapAvailabilityError(.notReady(reason: "apple_intelligence_not_enabled"))
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "apple_intelligence_not_enabled")
        #expect(detail == "Apple Intelligence is off.")
    }

    @Test(".notReady(model_not_ready) → temporarilyUnavailable (exit 71 class)")
    func notReadyModelDownloading() {
        guard case .temporarilyUnavailable(let reason, let detail, _) =
            AFMEngine.mapAvailabilityError(.notReady(reason: "model_not_ready"))
        else { Issue.record("expected .temporarilyUnavailable"); return }
        #expect(reason == "model_not_ready")
        #expect(detail == "The model is still downloading.")
    }
}
#endif
