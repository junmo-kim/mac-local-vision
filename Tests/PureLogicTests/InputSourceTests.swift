import Testing
import Foundation
@testable import VisionCore

@Suite("InputSource")
struct InputSourceTests {

    // MARK: - data field

    @Test("valid base64 returns .data")
    func validBase64ReturnsData() throws {
        let bytes = Data("hello".utf8)
        let b64 = bytes.base64EncodedString()
        let result = try InputSource.resolve(path: nil, data: b64)
        guard case .data(let decoded) = result else {
            Issue.record("expected .data"); return
        }
        #expect(decoded == bytes)
    }

    @Test("data takes precedence over path")
    func dataTakesPrecedenceOverPath() throws {
        let bytes = Data([0x01, 0x02])
        let b64 = bytes.base64EncodedString()
        let result = try InputSource.resolve(path: "/some/path.png", data: b64)
        if case .path = result {
            Issue.record("data should take precedence over path")
        }
    }

    @Test("invalid base64 throws invalid_base64")
    func invalidBase64ThrowsMalformed() {
        do {
            _ = try InputSource.resolve(path: nil, data: "!!!not-base64!!!")
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.reason == "invalid_base64")
        }
    }

    @Test("empty data string falls back to path")
    func emptyDataStringFallsBackToPath() throws {
        let result = try InputSource.resolve(path: "/img.png", data: "")
        guard case .path(let p) = result else {
            Issue.record("expected .path"); return
        }
        #expect(p == "/img.png")
    }

    // MARK: - path field

    @Test("valid path returns .path")
    func validPathReturnsPath() throws {
        let result = try InputSource.resolve(path: "/tmp/screen.png", data: nil)
        guard case .path(let p) = result else {
            Issue.record("expected .path"); return
        }
        #expect(p == "/tmp/screen.png")
    }

    @Test("both nil throws missing_input")
    func bothNilThrowsMissingInput() {
        do {
            _ = try InputSource.resolve(path: nil, data: nil)
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.reason == "missing_input")
        }
    }

    @Test("empty path throws missing_input")
    func emptyPathThrowsMissingInput() {
        do {
            _ = try InputSource.resolve(path: "", data: nil)
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.reason == "missing_input")
        }
    }

    // MARK: - label

    @Test("path label")
    func pathLabel() throws {
        let src = try InputSource.resolve(path: "/a/b.png", data: nil)
        #expect(src.label == "/a/b.png")
    }

    @Test("data label")
    func dataLabel() throws {
        let src = try InputSource.resolve(path: nil, data: Data([0xFF]).base64EncodedString())
        #expect(src.label == "<base64 data>")
    }
}
