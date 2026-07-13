import Foundation

/// An ordered, typed value tree used to render command output.
///
/// Output contract (cli-api §1): `stdout` carries only parseable data — YAML by
/// default, JSON via `--format json`. Dictionaries preserve insertion order so the
/// output is stable and diffable.
public indirect enum YAMLValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([YAMLValue])
    case dict([(String, YAMLValue)])
}

extension YAMLValue: Equatable {
    // Manual conformance: `.dict`'s payload is `[(String, YAMLValue)]` — a tuple array —
    // and plain tuples can't conform to Equatable, so auto-synthesis doesn't apply here.
    // Order-sensitive, matching the type's own "dictionaries preserve insertion order" contract.
    public static func == (lhs: YAMLValue, rhs: YAMLValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.dict(let a), .dict(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

/// Thrown by `YAMLValue.parseJSON` on malformed input. Domain-neutral (this is a general
/// JSON→YAMLValue decoder, not tied to any one caller's exit-code/error-envelope
/// conventions) — callers translate it into their own structured error as needed.
public struct JSONParseError: Error, Sendable {
    public let detail: String
}

public extension YAMLValue {
    /// Decode JSON text into a `YAMLValue` tree — the inverse of `render(as: .json)`. Used
    /// to embed an already-JSON `ask --schema` answer (`GeneratedContent.jsonString`) into
    /// the response tree as structured data rather than one opaque string.
    static func parseJSON(_ text: String) throws -> YAMLValue {
        guard let data = text.data(using: .utf8) else {
            throw JSONParseError(detail: "not valid UTF-8 text")
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONParseError(detail: error.localizedDescription)
        }
        return try convertJSONValue(obj)
    }
}

private func convertJSONValue(_ value: Any) throws -> YAMLValue {
    if value is NSNull { return .null }
    if let num = value as? NSNumber {
        // NSNumber conflates JSON booleans and numbers on Darwin — a bare `as? Bool` cast
        // can silently misfire on numeric 0/1, so check the CFBoolean type identity first.
        if CFGetTypeID(num) == CFBooleanGetTypeID() {
            return .bool(num.boolValue)
        }
        if let i = Int(exactly: num) {
            return .int(i)
        }
        return .double(num.doubleValue)
    }
    if let s = value as? String { return .string(s) }
    if let arr = value as? [Any] { return .array(try arr.map(convertJSONValue)) }
    if let dict = value as? [String: Any] {
        // JSONSerialization doesn't preserve key order — sort for deterministic output
        // (same tradeoff JSONSchemaMapper makes on the way in).
        return .dict(try dict.keys.sorted().map { key in (key, try convertJSONValue(dict[key]!)) })
    }
    throw JSONParseError(detail: "unrecognized JSON value type: \(type(of: value))")
}

public enum OutputFormat: String, Sendable {
    case yaml
    case json
}

public extension YAMLValue {
    func render(as format: OutputFormat) -> String {
        switch format {
        case .yaml: return renderYAML(indent: 0)
        case .json: return renderJSON()
        }
    }

    // MARK: - YAML

    private func renderYAML(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .array(let items):
            if items.isEmpty { return "\(pad)[]" }
            return items.map { item -> String in
                if let scalar = item.scalarYAML() {
                    return "\(pad)- \(scalar)"
                }
                // Nested container under a list item.
                let body = item.renderYAML(indent: indent + 1)
                return "\(pad)-\n\(body)"
            }.joined(separator: "\n")
        case .dict(let pairs):
            if pairs.isEmpty { return "\(pad){}" }
            return pairs.map { key, value -> String in
                if let scalar = value.scalarYAML() {
                    return "\(pad)\(yamlKey(key)): \(scalar)"
                }
                let body = value.renderYAML(indent: indent + 1)
                return "\(pad)\(yamlKey(key)):\n\(body)"
            }.joined(separator: "\n")
        default:
            return "\(pad)\(scalarYAML() ?? "null")"
        }
    }

    private func scalarYAML() -> String? {
        switch self {
        case .string(let s): return yamlScalarString(s)
        case .int(let i): return String(i)
        case .double(let d): return formatDouble(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a) where a.isEmpty: return "[]"
        case .dict(let d) where d.isEmpty: return "{}"
        default: return nil
        }
    }

    // MARK: - JSON

    private func renderJSON() -> String {
        switch self {
        case .string(let s): return jsonString(s)
        case .int(let i): return String(i)
        case .double(let d): return formatDouble(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            return "[" + items.map { $0.renderJSON() }.joined(separator: ",") + "]"
        case .dict(let pairs):
            return "{" + pairs.map { "\(jsonString($0.0)):\($0.1.renderJSON())" }.joined(separator: ",") + "}"
        }
    }
}

// MARK: - Scalar helpers (pure, testable)

/// Bare YAML key if it is a simple token; quoted otherwise.
func yamlKey(_ s: String) -> String { isSimpleToken(s) ? s : yamlQuoted(s) }

/// A YAML scalar string: bare for simple tokens (`available`, `device_not_eligible`),
/// double-quoted (escaped) for anything with spaces, punctuation, or non-ASCII.
func yamlScalarString(_ s: String) -> String { isSimpleToken(s) ? s : yamlQuoted(s) }

func isSimpleToken(_ s: String) -> Bool {
    guard let first = s.first, first.isLetter || first == "_" else { return false }
    let reserved: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]
    if reserved.contains(s.lowercased()) { return false }
    return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "/") }
}

func yamlQuoted(_ s: String) -> String { jsonString(s) }

func jsonString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            // RFC 8259 §7: all control chars U+0000–U+001F must be escaped. OCR output
            // can contain them (NUL, vertical tab, form feed, …) — emitting them raw
            // produces JSON that strict parsers (jq, JSONSerialization) reject.
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    out += "\""
    return out
}

/// Stable double formatting: fixed-point, trailing zeros trimmed (`0.8500` -> `0.85`).
func formatDouble(_ d: Double) -> String {
    // NaN/±Infinity are not representable in JSON and break YAML float parsing —
    // emit `null` rather than a bare `nan`/`inf` token.
    guard d.isFinite else { return "null" }
    if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
    var s = String(format: "%.4f", d)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}
