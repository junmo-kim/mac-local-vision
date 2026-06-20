import Foundation

/// Pure text-span helpers (tier ①, testable anywhere).
public enum TextRanges {
    /// Ranges of whitespace-separated words within `s`, in order. Used to ask Vision
    /// for each word's `boundingBox(for:)` so `ocr --words` can return per-word pixels.
    public static func words(in s: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if let st = start { ranges.append(st..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i = s.index(after: i)
        }
        if let st = start { ranges.append(st..<s.endIndex) }
        return ranges
    }
}
