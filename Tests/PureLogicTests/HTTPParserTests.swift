import XCTest
@testable import VisionCore

final class HTTPParserTests: XCTestCase {

    // MARK: - happy path

    func testSimplePostRequest() throws {
        let body = "{\"method\":\"ping\"}"
        let raw = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n\(body)"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/mcp")
        XCTAssertEqual(req.headers["content-type"], "application/json")
        XCTAssertEqual(req.headers["content-length"], "\(body.count)")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), body)
    }

    func testGetRequestNoBody() throws {
        let raw = "GET /doctor HTTP/1.1\r\nHost: localhost:9090\r\n\r\n"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/doctor")
        XCTAssertEqual(req.headers["host"], "localhost:9090")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testHeadersCaseNormalized() throws {
        let raw = "GET / HTTP/1.1\r\nX-Custom-Header: Hello\r\nContent-Type: text/plain\r\n\r\n"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertEqual(req.headers["x-custom-header"], "Hello")
        XCTAssertEqual(req.headers["content-type"], "text/plain")
    }

    func testBodyTrimmedToContentLength() throws {
        // Raw body has extra bytes; Content-Length says 3
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 3\r\n\r\nhello"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertEqual(String(data: req.body, encoding: .utf8), "hel")
    }

    func testLargeJsonBody() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ocr","arguments":{"path":"/tmp/test.png"}}}
        """
        let raw = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/mcp")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), json)
    }

    // MARK: - error cases

    func testIncompleteHeaders() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\n"
        XCTAssertThrowsError(try HTTPParser.parse(Data(raw.utf8))) { err in
            XCTAssertEqual(err as? HTTPParseError, .incomplete)
        }
    }

    func testMalformedRequestLineOneWord() {
        let raw = "BADLINE\r\n\r\n"
        XCTAssertThrowsError(try HTTPParser.parse(Data(raw.utf8))) { err in
            if case .malformed = err as? HTTPParseError {} else {
                XCTFail("expected .malformed, got \(err)")
            }
        }
    }

    func testEmptyData() {
        XCTAssertThrowsError(try HTTPParser.parse(Data())) { err in
            XCTAssertEqual(err as? HTTPParseError, .incomplete)
        }
    }

    func testNoContentLengthBodyIncluded() throws {
        // Without Content-Length, body is everything after the separator
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n{\"hello\":true}"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertEqual(String(data: req.body, encoding: .utf8), "{\"hello\":true}")
    }

    func testBodyShorterThanContentLength() throws {
        // Parser silently clamps to available bytes; completeness checking belongs
        // to receiveHTTPRequest (the transport layer), not the parser.
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"short"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertLessThan(req.body.count, 100)
    }

    func testNonNumericContentLengthBodyIncluded() throws {
        // Non-numeric Content-Length is treated as absent — body is raw bytes after separator
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: ATTACK\r\n\r\nhello"
        let req = try HTTPParser.parse(Data(raw.utf8))
        XCTAssertEqual(String(data: req.body, encoding: .utf8), "hello")
    }

    // MARK: - guard: duplicate Content-Length

    func testDuplicateContentLengthThrowsMalformed() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 3\r\n\r\nhello"
        XCTAssertThrowsError(try HTTPParser.parse(Data(raw.utf8))) { err in
            XCTAssertEqual(err as? HTTPParseError, .malformed("duplicate Content-Length"))
        }
    }

    // MARK: - guard: header count cap

    func testTooManyHeadersThrowsMalformed() {
        var raw = "POST /mcp HTTP/1.1\r\n"
        for i in 0..<200 { raw += "X-Flood-\(i): v\r\n" }
        raw += "\r\n"
        XCTAssertThrowsError(try HTTPParser.parse(Data(raw.utf8))) { err in
            XCTAssertEqual(err as? HTTPParseError, .malformed("too many header lines"))
        }
    }
}
