import Foundation
import VisionCore

/// Argument/usage error raised by command handlers.
struct CLIError: Error {
    let message: String
    var exitCode: ExitCode = .usage
}

enum IO {
    /// Pure data to stdout (YAML/JSON only — cli-api §1).
    static func emit(_ value: YAMLValue, format: OutputFormat) {
        print(value.render(as: format))
    }

    /// Logs and structured errors to stderr, keeping stdout clean.
    static func emitError(_ value: YAMLValue, format: OutputFormat) {
        let text = value.render(as: format) + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Resolve the requested output format from `--format`.
func resolveFormat(_ args: ParsedArgs) throws -> OutputFormat {
    guard let raw = args.option("format") else { return .yaml }
    guard let format = OutputFormat(rawValue: raw) else {
        throw CLIError(message: "invalid --format: \(raw) (expected yaml|json)")
    }
    return format
}

/// Parse an optional numeric option, erroring on malformed input instead of silently
/// falling back to a default (which would hide the user's typo).
func optDouble(_ args: ParsedArgs, _ key: String) throws -> Double? {
    guard let raw = args.option(key) else { return nil }
    guard let value = Double(raw) else {
        throw CLIError(message: "invalid --\(key): \(raw) (expected a number)")
    }
    return value
}

func optInt(_ args: ParsedArgs, _ key: String) throws -> Int? {
    guard let raw = args.option(key) else { return nil }
    guard let value = Int(raw) else {
        throw CLIError(message: "invalid --\(key): \(raw) (expected an integer)")
    }
    return value
}
