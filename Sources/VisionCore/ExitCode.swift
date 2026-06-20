import Foundation

/// Process exit codes (cli-api §4.2). Distinguishes permanently-impossible from
/// retryable so that agents/CI can branch without re-attempting hopeless calls.
public enum ExitCode: Int32, Sendable {
    case success = 0
    case runtimeError = 1
    /// Bad arguments (`EX_USAGE`). Retrying is pointless.
    case usage = 64
    /// `ask` impossible — OS/hardware ineligible (device_not_eligible / os_too_old). Permanent.
    case askIneligible = 70
    /// `ask` impossible — Apple Intelligence off / model downloading. Retryable later.
    case askTemporarilyUnavailable = 71
}
