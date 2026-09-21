import Foundation
import VisionCore
import Darwin

/// Argument/usage error raised by command handlers.
struct CLIError: Error {
    let message: String
    var exitCode: ExitCode = .usage
}

enum IO {
    @TaskLocal static var dataOutputFileDescriptor: Int32 = STDOUT_FILENO

    /// Pure data to stdout (YAML/JSON only — cli-api §1).
    static func emit(_ value: YAMLValue, format: OutputFormat) {
        let data = Data((value.render(as: format) + "\n").utf8)
        writeData(data)
    }

    static func emitText(_ text: String) {
        writeData(Data(text.utf8))
    }

    /// Keep caller-visible output separate from diagnostics written directly to fd 1 by
    /// Apple frameworks. The redirection lasts for the remaining process lifetime so delayed
    /// native messages cannot corrupt an already-written JSON or YAML response.
    static func withProcessDataOutputBoundary<T>(
        _ operation: nonisolated(nonsending) () async -> T
    ) async -> T? {
        let dataOutput = dup(STDOUT_FILENO)
        guard dataOutput >= 0 else { return nil }
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(dataOutput)
            return nil
        }
        defer { close(dataOutput) }
        return await $dataOutputFileDescriptor.withValue(dataOutput, operation: operation)
    }

    /// Logs and structured errors to stderr, keeping stdout clean.
    static func emitError(_ value: YAMLValue, format: OutputFormat) {
        let text = value.render(as: format) + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func writeData(_ data: Data) {
        FileHandle(fileDescriptor: dataOutputFileDescriptor, closeOnDealloc: false).write(data)
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

func optNumericList(_ args: ParsedArgs, _ key: String) throws -> [Double]? {
    guard let raw = args.option(key) else {
        if args.flag(key) {
            throw CLIError(message: "invalid --\(key): expected comma-separated numbers")
        }
        return nil
    }
    do {
        return try SegmentationParameters.numericList(raw)
    } catch {
        throw CLIError(message: "invalid --\(key): \(raw) (expected comma-separated numbers)")
    }
}
