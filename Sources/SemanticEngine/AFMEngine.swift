import Foundation

/// Availability of the multimodal `ask` mode on the current machine.
public enum AskAvailability: Equatable, Sendable {
    case available
    /// Permanent — device/OS can never run it (exit 70 class).
    case ineligible(reason: String)
    /// Permanent — OS too old for image input (exit 70 class).
    case osTooOld(reason: String)
    /// Retryable — Apple Intelligence off / model not ready yet (exit 71 class).
    case notReady(reason: String)
}

#if canImport(FoundationModels)
import FoundationModels
import CoreGraphics
import VisionCore  // shared image loader (page/scale/PDF/EXIF) — same contract as ocr/find

/// Real Apple Foundation Models backend.
///
/// NOTE: multimodal image input (AFM 3 Core Advanced) requires the **macOS 27 SDK**
/// and a macOS 27 + M3/M4 + 12GB runtime. Until this target is built against the 27
/// SDK, `ask` returns a structured ineligibility error instead of compiling against
/// APIs not present in the 26 SDK (impl §3 roadmap: ship Vision-only first).
@available(macOS 26, *)
public struct AFMEngine: SemanticEngine {
    public init() {}

    public func ask(imagePath: String, prompt: String, stream: Bool,
                    page: Int, scale: Double) async throws -> AskOutcome {
        // Authoritative design: do NOT pre-judge eligibility from device specs or the
        // availability probe. Attempt the real call and let the framework's thrown error
        // decide — unknown errors are surfaced, not guessed. (`probeAskAvailability` is
        // kept for `doctor` preflight only.)
        #if MACVIS_ASK_IMAGE
        // macOS 27 SDK build. Signatures verified against MacOSX27.0.sdk (Xcode 27 beta
        // 27A5194q): `Attachment(<NSImage|CGImage>)` inside a `respond`/`streamResponse`
        // @PromptBuilder closure; the result/chunk `.content` is the String answer.
        // All thrown errors route through `mapCallError` so eligibility comes from the
        // framework, not a spec check.
        guard #available(macOS 27, *) else {
            throw SemanticError.ineligible(
                reason: "needs_macos_27_runtime",
                detail: "Built with multimodal support but running on macOS < 27.",
                hint: "Run on macOS 27 + M3/M4 (12GB+).")
        }
        // Shared loader → same page/scale/PDF/EXIF contract as ocr/find. `Attachment`
        // accepts a CGImage directly (verified against the 27 SDK).
        let image: CGImage
        do {
            image = try OCREngine.loadImage(path: imagePath, page: page, scale: scale).cgImage
        } catch {
            throw SemanticError.failed(
                reason: "image_load_failed", detail: imagePath,
                hint: "check the path / format (png/jpg/heic/pdf — use page for multi-page PDFs).")
        }
        // On-device only, by design. The framework *also* ships a Private Cloud Compute
        // backend — `LanguageModelSession(model: PrivateCloudComputeLanguageModel())`, which
        // compiles fine against the 27 SDK — but we deliberately don't wire it. PCC requires
        // the managed `com.apple.developer.private-cloud-compute` entitlement, and Apple
        // grants that only for App Store distribution (TestFlight / ad-hoc for testing).
        // A notarized, Homebrew-distributed CLI can't carry it — and a bare CLI can't ship
        // on the Mac App Store at all. So `ask` runs purely on the on-device model
        // (`SystemLanguageModel.default`), which needs no entitlement; nothing leaves the box.
        let session = LanguageModelSession()  // on-device SystemLanguageModel.default
        do {
            let text: String
            if stream {
                var latest = ""
                let responseStream = session.streamResponse { prompt; Attachment(image) }
                for try await chunk in responseStream {
                    latest = chunk.content  // snapshot-accumulating stream
                }
                text = latest
            } else {
                text = try await session.respond { prompt; Attachment(image) }.content
            }
            return AskOutcome(text: text, compute: .onDevice)
        } catch let e as SemanticError {
            throw e
        } catch {
            throw Self.mapCallError(error)
        }
        #else
        // The multimodal image API is absent from this SDK — a compile-time fact, the
        // most authoritative signal there is (no spec guessing, no probe).
        throw SemanticError.ineligible(
            reason: "needs_macos_27_sdk",
            detail: "This binary was built without multimodal image support (macOS 27 SDK required).",
            hint: "Build on macOS 26.4+ with the Xcode 27 SDK and -D MACVIS_ASK_IMAGE, run on macOS 27."
        )
        #endif
    }

    /// Map a real FoundationModels call error to our structured error. Authoritative —
    /// driven by what the framework actually threw. On the macOS 27 SDK we match the real
    /// typed `LanguageModelError` enum (cases verified against MacOSX27.0.sdk); older builds
    /// and any unrecognized error fall back to message keywords (`mapCallErrorByMessage`,
    /// locked by MapCallErrorTests).
    static func mapCallError(_ error: Error) -> SemanticError {
        #if MACVIS_ASK_IMAGE
        if #available(macOS 27, *) {
            // On-device generation errors (the real macOS 27 enum). The Private Cloud Compute
            // backend is never instantiated (see `ask` — entitlement-gated), so its separate
            // error type isn't handled here.
            if let e = error as? LanguageModelError {
                switch e {
                case .rateLimited:
                    return .temporarilyUnavailable(
                        reason: "rate_limited",
                        detail: "The session was rate limited.",
                        hint: "Retry shortly.")
                case .timeout:
                    return .temporarilyUnavailable(
                        reason: "timeout",
                        detail: "The request timed out before the model responded.",
                        hint: "Retry, or try a smaller image / shorter prompt.")
                case .contextSizeExceeded:
                    return .failed(
                        reason: "context_size_exceeded",
                        detail: "The prompt and image exceeded the model's context window.",
                        hint: "Use a smaller image (lower --scale) or a shorter prompt.")
                case .guardrailViolation:
                    return .failed(
                        reason: "guardrail_violation",
                        detail: "Apple's safety guardrails blocked this prompt or response.",
                        hint: "Rephrase the prompt, or use a different image.")
                case .refusal:
                    return .failed(
                        reason: "model_refused",
                        detail: "The model declined to answer.",
                        hint: "Rephrase the prompt.")
                case .unsupportedLanguageOrLocale:
                    return .failed(
                        reason: "unsupported_language",
                        detail: "The model doesn't support the requested language.",
                        hint: "Ask in a supported language (e.g. English).")
                case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                    return .failed(
                        reason: "unsupported_request",
                        detail: String(describing: error),
                        hint: "This model or build doesn't support that input or option.")
                @unknown default:
                    break
                }
            }
        }
        #endif
        return mapCallErrorByMessage(error)
    }

    /// Message-keyword fallback: the only path on the macOS 26 build (the typed 27 enums
    /// don't exist there) and the safety net for any error the typed switch didn't match.
    /// Behavior is locked by `MapCallErrorTests`.
    static func mapCallErrorByMessage(_ error: Error) -> SemanticError {
        let m = String(describing: error).lowercased()
        if m.contains("eligible") {
            return .ineligible(
                reason: "device_not_eligible",
                detail: "This Mac can't run ask on-device.",
                hint: "ask needs an Apple-Intelligence-eligible Apple Silicon Mac on macOS 27 (Beta) — signed in, supported region, internal boot (eligibility is blocked on external-boot disks).")
        }
        if m.contains("not enabled") || m.contains("intelligence") {
            return .temporarilyUnavailable(
                reason: "apple_intelligence_not_enabled",
                detail: "Apple Intelligence is off.",
                hint: "Enable Apple Intelligence in System Settings, then retry.")
        }
        if m.contains("not ready") || m.contains("download") {
            return .temporarilyUnavailable(
                reason: "model_not_ready",
                detail: "The model is still downloading.",
                hint: "Retry shortly.")
        }
        // Ran and failed for an unmapped reason (guardrail, context size, …). Surface the
        // real message rather than pretending to know — refine on the 27 SDK.
        return .failed(
            reason: "ask_failed",
            detail: String(describing: error),
            hint: "Unmapped FoundationModels error — refine AFMEngine.mapCallError on the macOS 27 SDK.")
    }
}
#endif

/// Preflight (advisory) availability — used by `doctor` to show what's likely possible.
/// NOT used to gate `ask`: the authoritative signal is the real call's thrown error
/// (see `AFMEngine.ask`). Reads the system's reported availability, never device specs.
public func probeAskAvailability() -> AskAvailability {
#if canImport(FoundationModels)
    if #available(macOS 26, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
            // Base AFM may be present on 26, but image input needs macOS 27.
            if #available(macOS 27, *) { return .available }
            return .osTooOld(reason: "needs_macos_27_for_image_input")
        case .unavailable(.deviceNotEligible):
            return .ineligible(reason: "device_not_eligible")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notReady(reason: "apple_intelligence_not_enabled")
        case .unavailable(.modelNotReady):
            return .notReady(reason: "model_not_ready")
        case .unavailable:
            return .ineligible(reason: "unavailable")
        @unknown default:
            return .ineligible(reason: "unknown")
        }
    }
#endif
    return .osTooOld(reason: "foundation_models_unavailable")
}
