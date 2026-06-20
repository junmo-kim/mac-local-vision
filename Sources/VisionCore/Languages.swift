import Foundation

/// Locale → recognition-language resolution (pure, testable).
///
/// Vision's built-in default is English-only (`["en_US"]`), which silently drops
/// every other script. Rather than hardcode any one language (wrong for a globally
/// distributed tool), we derive defaults from the user's OS locale preferences and
/// map them onto whatever the engine actually supports. `--lang` overrides entirely.
public enum Languages {
    private static func subtag(_ code: String) -> String {
        String(code.split(separator: "-").first ?? "").lowercased()
    }

    /// Resolve recognition languages from `preferred` (e.g. `Locale.preferredLanguages`)
    /// against the engine's `supported` set. English is always appended as a fallback
    /// when supported (numerals, brand names, mixed UI chrome).
    ///
    /// Korean Mac  -> ["ko-KR", "en-US"]
    /// German Mac  -> ["de-DE", "en-US"]
    /// en-GB only  -> ["en-US"]
    public static func resolve(preferred: [String], supported: [String], fallback: String = "en-US") -> [String] {
        var result: [String] = []
        for code in preferred {
            let want = subtag(code)
            guard !want.isEmpty else { continue }
            if let match = supported.first(where: { subtag($0) == want }), !result.contains(match) {
                result.append(match)
            }
        }
        if let english = supported.first(where: { subtag($0) == "en" }), !result.contains(english) {
            result.append(english)
        }
        if result.isEmpty {
            result = supported.contains(fallback) ? [fallback] : Array(supported.prefix(1))
        }
        return result
    }
}
