import Foundation

/// Result of parsing a subcommand's argument list.
public struct ParsedArgs: Equatable, Sendable {
    public var positionals: [String]
    public var options: [String: String]
    public var flags: Set<String>

    public func option(_ key: String) -> String? { options[key] }
    public func flag(_ key: String) -> Bool { flags.contains(key) }
    public var firstPositional: String? { positionals.first }
}

/// Minimal, dependency-free argument parser (impl §1: zero third-party deps).
///
/// Grammar:
///   - `--name value`   -> options["name"] = "value"
///   - `--name`         -> flags.insert("name")          (if name ∈ booleanFlags, or no value follows)
///   - `value`          -> positionals.append("value")
public enum ArgParser {
    public static func parse(_ args: [String], booleanFlags: Set<String> = []) -> ParsedArgs {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []

        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                // `--key=value` form.
                if let eq = name.firstIndex(of: "=") {
                    let key = String(name[name.startIndex..<eq])
                    let value = String(name[name.index(after: eq)...])
                    options[key] = value
                    i += 1
                    continue
                }
                if booleanFlags.contains(name) {
                    flags.insert(name)
                    i += 1
                    continue
                }
                // Consume the next token as the value unless it's another option.
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    options[name] = args[i + 1]
                    i += 2
                } else {
                    flags.insert(name)
                    i += 1
                }
            } else {
                positionals.append(token)
                i += 1
            }
        }
        return ParsedArgs(positionals: positionals, options: options, flags: flags)
    }
}
