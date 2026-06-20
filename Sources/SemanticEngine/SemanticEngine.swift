import Foundation

/// Where an `ask` ran. macvis runs purely on-device, so this is always `on-device`
/// (nothing leaves the machine). Apple's Private Cloud Compute backend exists but is
/// intentionally not used — see `AFMEngine.ask` (entitlement-gated + App Store only).
public enum AskCompute: String, Sendable {
    case onDevice = "on-device"
}

/// The answer plus where it was computed.
public struct AskOutcome: Sendable {
    public let text: String
    public let compute: AskCompute
    public init(text: String, compute: AskCompute) {
        self.text = text
        self.compute = compute
    }
}

/// Abstraction over the multimodal `ask` backend so the CLI plumbing (arg validation,
/// streaming, output formatting, error->stderr separation) is testable on CI with a
/// mock, while the real Apple Foundation Models call stays behind macOS 27 guards
/// (impl §2: protocol + DI). Model *output quality* is never asserted in unit tests.
///
/// macvis runs `ask` on-device only; there is no cloud opt-in (Private Cloud Compute is
/// entitlement-gated + App Store only — see `AFMEngine.ask`).
public protocol SemanticEngine: Sendable {
    func ask(imagePath: String, prompt: String, stream: Bool,
             page: Int, scale: Double) async throws -> AskOutcome
}

/// Structured `ask` failure. Maps to exit codes 70 (permanent) / 71 (retryable).
public enum SemanticError: Error, Sendable {
    /// Permanent: device/OS can never run `ask` (device_not_eligible / os_too_old).
    case ineligible(reason: String, detail: String, hint: String)
    /// Retryable: Apple Intelligence off, or model still downloading.
    case temporarilyUnavailable(reason: String, detail: String, hint: String)
    /// A call that actually ran and failed for some other reason (guardrail, context,
    /// or an error we haven't specifically mapped). Surfaced verbatim — exit 1.
    case failed(reason: String, detail: String, hint: String)
}
