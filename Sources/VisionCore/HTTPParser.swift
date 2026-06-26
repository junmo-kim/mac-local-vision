import Foundation

/// Pure HTTP/1.1 request parser — no networking dependencies.
/// Parses a single complete HTTP request from raw bytes.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]  // lowercase keys
    public let body: Data
}

public enum HTTPParseError: Error, Sendable, Equatable {
    case incomplete           // header section not yet received
    case malformed(String)    // structurally invalid
}

public enum HTTPParser {
    private static let headerSep = Data("\r\n\r\n".utf8)

    /// Parse a complete HTTP/1.1 request from raw bytes.
    /// Body is trimmed to Content-Length when present.
    public static func parse(_ raw: Data) throws -> HTTPRequest {
        guard let sepRange = raw.range(of: headerSep) else {
            throw HTTPParseError.incomplete
        }

        let headerData = Data(raw[raw.startIndex ..< sepRange.lowerBound])
        let rawBody = Data(raw[sepRange.upperBound...])

        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.malformed("non-UTF8 headers")
        }

        var lines = headerStr.components(separatedBy: "\r\n")

        // Request line
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw HTTPParseError.malformed("invalid request line: \(requestLine)")
        }
        let method = String(parts[0])
        let path = String(parts[1])

        // Headers — lowercase keys for case-insensitive lookup
        // removeFirst() already consumed the request line, so `lines` contains only header lines.
        // This fires when count == 200 (i.e. ≥ 200 header lines).
        guard lines.count < 200 else {
            throw HTTPParseError.malformed("too many header lines")
        }
        var headers: [String: String] = [:]
        for line in lines {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex ..< colon].lowercased()
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if key == "content-length" && headers[key] != nil {
                throw HTTPParseError.malformed("duplicate Content-Length")
            }
            headers[key] = value
        }

        // Trim body to Content-Length when present (avoids trailing pipeline garbage)
        let body: Data
        if let clStr = headers["content-length"], let cl = Int(clStr), cl >= 0 {
            body = Data(rawBody.prefix(cl))
        } else {
            body = rawBody
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}
