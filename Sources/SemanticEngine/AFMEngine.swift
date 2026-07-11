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
        // Originally this let the framework's thrown error decide eligibility, without
        // pre-judging from the availability probe. On macOS 27 Beta (26A5378j) that
        // assumption doesn't hold: calling LanguageModelSession/Attachment while the model
        // isn't ready crashes the process (EXC_BAD_ACCESS/SIGSEGV inside FoundationModels'
        // XPC layer, verified via crash report) instead of throwing a catchable error. So we
        // gate on the probe (right before that call, below) and only let the framework
        // decide once it reports available.
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
        // Gated as late as possible — right before the crash-prone call, after image
        // loading — to keep the check-to-call window (and thus the chance the model flips
        // states in between) as narrow as possible.
        if let unavailable = Self.mapAvailabilityError(probeAskAvailability()) {
            throw unavailable
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

    /// Maps a pre-flight `probeAskAvailability()` result to the structured error `ask()`
    /// should throw before attempting the real call — or `nil` when the call is safe to
    /// attempt. Pulled out of `ask()` as a pure function (mirroring `mapCallError`/
    /// `mapCallErrorByMessage` below) so the pre-flight gate is unit-testable without live
    /// FoundationModels state. Locked by MapAvailabilityErrorTests.
    static func mapAvailabilityError(_ availability: AskAvailability) -> SemanticError? {
        switch availability {
        case .available:
            return nil
        case .ineligible(let reason):
            return .ineligible(
                reason: reason,
                detail: "This Mac can't run ask on-device.",
                hint: "ask needs an Apple-Intelligence-eligible Apple Silicon Mac on macOS 27 (Beta) — signed in, supported region, internal boot (eligibility is blocked on external-boot disks).")
        case .osTooOld(let reason):
            return .ineligible(
                reason: reason,
                detail: "Image input requires macOS 27.",
                hint: "Run on macOS 27 + M3/M4 (12GB+).")
        case .notReady(let reason):
            return .temporarilyUnavailable(
                reason: reason,
                detail: reason == "apple_intelligence_not_enabled"
                    ? "Apple Intelligence is off."
                    : "The model is still downloading.",
                hint: reason == "apple_intelligence_not_enabled"
                    ? "Enable Apple Intelligence in System Settings, then retry."
                    : "Retry shortly.")
        }
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
        // Observed in practice (2026-07-11, macOS 27 Beta 26A5378j): right after the main
        // generation model finishes downloading, calls can still fail because a secondary
        // model — the guardrail/safety content sanitizer — hasn't finished loading yet.
        // Confirmed transient: an identical call moments later succeeded. Surfaces as a
        // deeply nested error whose innermost domains are ModelManagerError/
        // SensitiveContentAnalysisML rather than anything matching the checks above.
        if m.contains("modelmanagererror") || m.contains("sensitivecontentanalysis") {
            return .temporarilyUnavailable(
                reason: "content_safety_model_not_ready",
                detail: "A secondary safety/guardrail model is still initializing.",
                hint: "Retry shortly — this can happen right after Apple Intelligence finishes downloading the main model.")
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

/// Preflight availability — used by `doctor` to show what's likely possible, AND (via
/// `AFMEngine.mapAvailabilityError`) as the pre-flight gate in `ask()` that avoids calling
/// into FoundationModels while the model isn't ready — a real SIGSEGV on macOS 27 Beta
/// (26A5378j), not just a thrown error; see `ask()`'s doc comment. Reads the system's
/// reported availability, never device specs.
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

/// Languages the on-device model can actually respond in *right now*. Verified empirically
/// (2026-07-12): once `.available`, the model handles prompts fluently across many of its
/// `supportedLanguages` — not just the current system language (tested ko/en/ja/fr, only
/// ko/en were in Preferred Languages, all four worked). So "ready" isn't gated per-language;
/// `.availability` is a single global switch and `supportedLanguages` is what's usable once
/// it's on. (Switching Siri's *system* language can still bounce `ask` back to
/// `model_not_ready` temporarily — that looks like Apple Intelligence re-provisioning as a
/// whole when the primary language changes, not a per-language asset gate; see 2026-07-11
/// per-language-download topic, corrected 2026-07-12.)
///
/// Gated on both the `MACVIS_ASK_IMAGE` compile flag and `probeAskAvailability()` — exactly
/// mirroring how `ask()` itself and `doctor`'s `askStatus` are gated (`probeAskAvailability()`
/// alone only checks the runtime OS version, not whether *this binary* was built with image
/// support, so skipping the compile-flag check would let a core build on real macOS 27
/// hardware report non-empty `ask_languages` while `ask` itself still says
/// `needs_macos_27_sdk`). So this never disagrees with `ask`'s own reported status: `[]`
/// whenever `ask` would report unavailable, the full `supportedLanguages` set (~24) once
/// `ask` is truly `available`. Used by `doctor` (`ask_languages`).
public func readyAskLanguages() -> [String] {
#if MACVIS_ASK_IMAGE
    guard case .available = probeAskAvailability() else { return [] }
#if canImport(FoundationModels)
    if #available(macOS 26, *) {
        return SystemLanguageModel.default.supportedLanguages
            .map { $0.minimalIdentifier }
            .sorted()
    }
#endif
#endif
    return []
}
