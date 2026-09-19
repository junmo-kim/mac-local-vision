import XCTest
@testable import VisionCore

final class QueryStringTests: XCTestCase {
    private func typed(_ v: Any?) -> String {
        switch v {
        case let b as Bool: return "bool:\(b)"
        case let d as Double: return "num:\(d)"
        case let a as [String]: return "arr:[\(a.joined(separator: ","))]"
        case let s as String: return "str:\(s)"
        default: return "nil"
        }
    }

    private func value(_ query: String, _ key: String) -> String {
        typed(QueryString.parse(query)[key])
    }

    // Regression for the operator-precedence bug: `a && b || c` previously left a
    // single-value `languages=ko-KR` as a String, which the downstream
    // `as? [String]` cast silently dropped (locale-default OCR, no error).
    func testSingleArrayValueBecomesOneElementArray() {
        XCTAssertEqual(value("languages=ko-KR", "languages"), "arr:[ko-KR]")
        XCTAssertEqual(value("symbologies=qr", "symbologies"), "arr:[qr]")
    }

    func testMultiValueArraysSplitOnComma() {
        XCTAssertEqual(value("languages=ko-KR,en-US", "languages"), "arr:[ko-KR,en-US]")
        XCTAssertEqual(value("symbologies=qr,code128", "symbologies"), "arr:[qr,code128]")
    }

    func testPercentEncodedCommaSplitsAfterDecoding() {
        XCTAssertEqual(value("languages=ko-KR%2Cen-US", "languages"), "arr:[ko-KR,en-US]")
    }

    func testEncodedNumberIsTypedNotStringified() {
        XCTAssertEqual(value("minConfidence=0%2E5", "minConfidence"), "num:0.5")
    }

    func testEmptyValueStaysStringNotArray() {
        XCTAssertEqual(value("languages=", "languages"), "str:")
    }

    func testBooleans() {
        XCTAssertEqual(value("words=true", "words"), "bool:true")
        XCTAssertEqual(value("words=false", "words"), "bool:false")
        XCTAssertEqual(value("visionTools=true", "visionTools"), "bool:true")
        XCTAssertEqual(value("visionTools=false", "visionTools"), "bool:false")
    }

    func testNumbersIncludingZero() {
        XCTAssertEqual(value("minConfidence=0", "minConfidence"), "num:0.0")
        XCTAssertEqual(value("scale=2.5", "scale"), "num:2.5")
    }

    func testNumericLookingStringForNonNumberKeyIsTypedAsNumber() {
        // target is consumed via as? String; digits-only targets are an accepted,
        // documented trade-off of shared typed parsing.
        XCTAssertEqual(value("target=123", "target"), "num:123.0")
    }

    func testPlusMeansSpaceAndEncodedPlusSurvives() {
        XCTAssertEqual(value("target=hello+world", "target"), "str:hello world")
        XCTAssertEqual(value("target=hello%2Bworld", "target"), "str:hello+world")
    }

    func testDuplicateKeysLastWins() {
        XCTAssertEqual(value("top=5&top=9", "top"), "num:9.0")
    }

    func testEmptyAndMalformedPairsAreIgnored() {
        XCTAssertEqual(QueryString.parse("").count, 0)
        XCTAssertEqual(QueryString.parse(nil).count, 0)
        XCTAssertEqual(value("&&flag=true&=x", "flag"), "bool:true")
    }
}
