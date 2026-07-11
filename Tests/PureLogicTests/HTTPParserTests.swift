import Testing
import Foundation
@testable import VisionCore

@Suite("HTTPParser")
struct HTTPParserTests {

    // MARK: - happy path

    @Test("simple POST request")
    func simplePostRequest() throws {
        let body = "{\"method\":\"ping\"}"
        let raw = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n\(body)"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(req.method == "POST")
        #expect(req.path == "/mcp")
        #expect(req.headers["content-type"] == "application/json")
        #expect(req.headers["content-length"] == "\(body.count)")
        #expect(String(data: req.body, encoding: .utf8) == body)
    }

    @Test("GET request with no body")
    func getRequestNoBody() throws {
        let raw = "GET /doctor HTTP/1.1\r\nHost: localhost:9090\r\n\r\n"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(req.method == "GET")
        #expect(req.path == "/doctor")
        #expect(req.headers["host"] == "localhost:9090")
        #expect(req.body.isEmpty)
    }

    @Test("headers are case-normalized")
    func headersCaseNormalized() throws {
        let raw = "GET / HTTP/1.1\r\nX-Custom-Header: Hello\r\nContent-Type: text/plain\r\n\r\n"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(req.headers["x-custom-header"] == "Hello")
        #expect(req.headers["content-type"] == "text/plain")
    }

    @Test("body trimmed to Content-Length")
    func bodyTrimmedToContentLength() throws {
        // Raw body has extra bytes; Content-Length says 3
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 3\r\n\r\nhello"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(String(data: req.body, encoding: .utf8) == "hel")
    }

    @Test("large JSON body")
    func largeJsonBody() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ocr","arguments":{"path":"/tmp/test.png"}}}
        """
        let raw = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(req.method == "POST")
        #expect(req.path == "/mcp")
        #expect(String(data: req.body, encoding: .utf8) == json)
    }

    // MARK: - error cases

    @Test("incomplete headers throw .incomplete")
    func incompleteHeaders() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\n"
        #expect(throws: HTTPParseError.incomplete) {
            try HTTPParser.parse(Data(raw.utf8))
        }
    }

    @Test("malformed request line (one word) throws .malformed")
    func malformedRequestLineOneWord() {
        do {
            _ = try HTTPParser.parse(Data("BADLINE\r\n\r\n".utf8))
            Issue.record("expected .malformed to be thrown")
        } catch let error as HTTPParseError {
            guard case .malformed = error else {
                Issue.record("expected .malformed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected HTTPParseError, got \(error)")
        }
    }

    @Test("empty data throws .incomplete")
    func emptyData() {
        #expect(throws: HTTPParseError.incomplete) {
            try HTTPParser.parse(Data())
        }
    }

    @Test("no Content-Length: body is everything after the separator")
    func noContentLengthBodyIncluded() throws {
        // Without Content-Length, body is everything after the separator
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n{\"hello\":true}"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(String(data: req.body, encoding: .utf8) == "{\"hello\":true}")
    }

    @Test("body shorter than Content-Length is clamped to available bytes")
    func bodyShorterThanContentLength() throws {
        // Parser silently clamps to available bytes; completeness checking belongs
        // to receiveHTTPRequest (the transport layer), not the parser.
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"short"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(req.body.count < 100)
    }

    @Test("non-numeric Content-Length is treated as absent")
    func nonNumericContentLengthBodyIncluded() throws {
        // Non-numeric Content-Length is treated as absent — body is raw bytes after separator
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: ATTACK\r\n\r\nhello"
        let req = try HTTPParser.parse(Data(raw.utf8))
        #expect(String(data: req.body, encoding: .utf8) == "hello")
    }

    // MARK: - guard: duplicate Content-Length

    @Test("duplicate Content-Length throws .malformed")
    func duplicateContentLengthThrowsMalformed() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 3\r\n\r\nhello"
        #expect(throws: HTTPParseError.malformed("duplicate Content-Length")) {
            try HTTPParser.parse(Data(raw.utf8))
        }
    }

    // MARK: - guard: header count cap

    @Test("too many headers throws .malformed")
    func tooManyHeadersThrowsMalformed() {
        var raw = "POST /mcp HTTP/1.1\r\n"
        for i in 0..<200 { raw += "X-Flood-\(i): v\r\n" }
        raw += "\r\n"
        #expect(throws: HTTPParseError.malformed("too many header lines")) {
            try HTTPParser.parse(Data(raw.utf8))
        }
    }
}
