import XCTest
@testable import VisionCore

final class InputSourceTests: XCTestCase {

    // MARK: - data field

    func testValidBase64ReturnsData() throws {
        let bytes = Data("hello".utf8)
        let b64 = bytes.base64EncodedString()
        let result = try InputSource.resolve(path: nil, data: b64)
        guard case .data(let decoded) = result else { XCTFail("expected .data"); return }
        XCTAssertEqual(decoded, bytes)
    }

    func testDataTakesPrecedenceOverPath() throws {
        let bytes = Data([0x01, 0x02])
        let b64 = bytes.base64EncodedString()
        let result = try InputSource.resolve(path: "/some/path.png", data: b64)
        if case .path = result { XCTFail("data should take precedence over path") }
    }

    func testInvalidBase64ThrowsMalformed() {
        XCTAssertThrowsError(try InputSource.resolve(path: nil, data: "!!!not-base64!!!")) { err in
            let se = err as? ServiceError
            XCTAssertEqual(se?.reason, "invalid_base64")
        }
    }

    func testEmptyDataStringFallsBackToPath() throws {
        let result = try InputSource.resolve(path: "/img.png", data: "")
        guard case .path(let p) = result else { XCTFail("expected .path"); return }
        XCTAssertEqual(p, "/img.png")
    }

    // MARK: - path field

    func testValidPathReturnsPath() throws {
        let result = try InputSource.resolve(path: "/tmp/screen.png", data: nil)
        guard case .path(let p) = result else { XCTFail("expected .path"); return }
        XCTAssertEqual(p, "/tmp/screen.png")
    }

    func testBothNilThrowsMissingInput() {
        XCTAssertThrowsError(try InputSource.resolve(path: nil, data: nil)) { err in
            let se = err as? ServiceError
            XCTAssertEqual(se?.reason, "missing_input")
        }
    }

    func testEmptyPathThrowsMissingInput() {
        XCTAssertThrowsError(try InputSource.resolve(path: "", data: nil)) { err in
            let se = err as? ServiceError
            XCTAssertEqual(se?.reason, "missing_input")
        }
    }

    // MARK: - label

    func testPathLabel() throws {
        let src = try InputSource.resolve(path: "/a/b.png", data: nil)
        XCTAssertEqual(src.label, "/a/b.png")
    }

    func testDataLabel() throws {
        let src = try InputSource.resolve(path: nil, data: Data([0xFF]).base64EncodedString())
        XCTAssertEqual(src.label, "<base64 data>")
    }
}
