import Foundation

/// Query-string → args parsing for the one-shot `QUERY /{tool}?<options>` HTTP
/// entry point. Pure string logic, hosted next to HTTPParser so it can be unit
/// tested without spinning up a listener. Typed conversion mirrors the MCP
/// JSON-RPC arg surface: booleans from "true"/"false", numbers via Double,
/// comma-split string arrays for the two array-valued keys.
public enum QueryString {
    /// Keys whose values are arrays, always comma-split (a bare value becomes a
    /// one-element array so downstream `as? [String]` casts never silently drop it).
    static let arrayKeys: Set<String> = ["languages", "symbologies"]

    public static func parse(_ query: String?) -> [String: Any] {
        guard let query, !query.isEmpty else { return [:] }
        var out: [String: Any] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first.map({ decode(String($0)) }), !key.isEmpty else { continue }
            // Duplicate keys: last one wins (documented behavior).
            out[key] = value(kv.count > 1 ? String(kv[1]) : "", key)
        }
        return out
    }

    private static func value(_ raw: String, _ key: String) -> Any {
        let raw = decode(raw)
        if raw.isEmpty { return raw }
        if arrayKeys.contains(key) {
            return raw.split(separator: ",").map { String($0) }
        }
        if raw == "true" || raw == "false" { return raw == "true" }
        if let d = Double(raw) { return d }
        return raw
    }

    /// Form-style decoding: literal `+` means space, then percent-escapes resolve
    /// (so an encoded `%2B` survives as a literal plus).
    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}
