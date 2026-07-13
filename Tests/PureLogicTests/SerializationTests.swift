import Testing
@testable import VisionCore

@Suite("Serialization — YAML/JSON rendering")
struct SerializationTests {
    @Test("simple tokens render bare, complex strings get quoted")
    func tokenQuoting() {
        #expect(YAMLValue.string("available").render(as: .yaml) == "available")
        #expect(YAMLValue.string("device_not_eligible").render(as: .yaml) == "device_not_eligible")
        // Korean / spaces / reserved words must be quoted.
        #expect(YAMLValue.string("결제하기").render(as: .yaml) == "\"결제하기\"")
        #expect(YAMLValue.string("two words").render(as: .yaml) == "\"two words\"")
        #expect(YAMLValue.string("true").render(as: .yaml) == "\"true\"")
    }

    @Test("find-style dict renders as YAML")
    func yamlDict() {
        let value = YAMLValue.dict([
            ("x", .int(1024)),
            ("confidence", .double(0.85)),
            ("text_found", .string("결제하기")),
        ])
        let expected = """
        x: 1024
        confidence: 0.85
        text_found: "결제하기"
        """
        #expect(value.render(as: .yaml) == expected)
    }

    @Test("json output is valid and ordered")
    func jsonDict() {
        let value = YAMLValue.dict([
            ("found", .bool(true)),
            ("x", .int(10)),
            ("text", .string("a\"b")),
        ])
        #expect(value.render(as: .json) == "{\"found\":true,\"x\":10,\"text\":\"a\\\"b\"}")
    }

    @Test("doubles drop trailing zeros, integers stay integral")
    func doubleFormatting() {
        #expect(YAMLValue.double(0.8500).render(as: .yaml) == "0.85")
        #expect(YAMLValue.double(1.0).render(as: .yaml) == "1")
        #expect(YAMLValue.double(0.333333).render(as: .yaml) == "0.3333")
    }

    @Test("control characters are escaped (valid JSON on adversarial OCR text)")
    func controlChars() {
        // bell (U+0007) + vertical tab (U+000B) must become \u00XX, not raw bytes.
        let value = YAMLValue.string("a\u{07}b\u{0B}c")
        #expect(value.render(as: .json) == "\"a\\u0007b\\u000bc\"")
    }

    @Test("non-finite doubles render as null, never bare nan/inf")
    func nonFiniteDoubles() {
        #expect(YAMLValue.double(.nan).render(as: .json) == "null")
        #expect(YAMLValue.double(.infinity).render(as: .json) == "null")
        #expect(YAMLValue.double(-.infinity).render(as: .yaml) == "null")
        #expect(YAMLValue.double(-0.0).render(as: .json) == "0")
    }

    @Test("newline inside a string forces quoting + escaping")
    func newlineString() {
        #expect(YAMLValue.string("line1\nline2").render(as: .yaml) == "\"line1\\nline2\"")
    }

    @Test("nested list of dicts indents correctly")
    func nestedList() {
        let value = YAMLValue.dict([
            ("lines", .array([
                .dict([("text", .string("hello")), ("confidence", .double(0.9))]),
            ])),
        ])
        let expected = """
        lines:
          -
            text: hello
            confidence: 0.9
        """
        #expect(value.render(as: .yaml) == expected)
    }
}

/// `parseJSON` — the inverse of `render(as: .json)`, used to embed a schema-constrained
/// `ask` answer (itself already JSON, from `GeneratedContent.jsonString`) into the response
/// tree as structured data instead of one opaque string.
@Suite("Serialization — JSON → YAMLValue parsing")
struct SerializationParseJSONTests {
    @Test("object with mixed scalar types")
    func objectScalars() throws {
        let value = try YAMLValue.parseJSON(#"{"merchant":"Acme","total":12.5,"count":3,"paid":true,"note":null}"#)
        guard case .dict(let pairs) = value else { Issue.record("expected .dict"); return }
        let asDict = Dictionary(uniqueKeysWithValues: pairs)
        #expect(asDict["merchant"] == .string("Acme"))
        #expect(asDict["total"] == .double(12.5))
        #expect(asDict["count"] == .int(3))
        #expect(asDict["paid"] == .bool(true))
        #expect(asDict["note"] == .null)
    }

    @Test("whole-number JSON floats decode as .int, not .double")
    func wholeNumberIsInt() throws {
        #expect(try YAMLValue.parseJSON(#"{"n":3}"#) == .dict([("n", .int(3))]))
    }

    @Test("nested array and object")
    func nestedArrayAndObject() throws {
        let value = try YAMLValue.parseJSON(#"{"tags":["a","b"],"address":{"city":"Seoul"}}"#)
        #expect(value == .dict([
            ("address", .dict([("city", .string("Seoul"))])),
            ("tags", .array([.string("a"), .string("b")])),
        ]))
    }

    @Test("bare JSON scalar (not an object) round-trips")
    func bareScalar() throws {
        #expect(try YAMLValue.parseJSON("42") == .int(42))
        #expect(try YAMLValue.parseJSON("true") == .bool(true))
        #expect(try YAMLValue.parseJSON(#""hi""#) == .string("hi"))
    }

    @Test("malformed JSON throws")
    func malformed() {
        #expect(throws: (any Error).self) { try YAMLValue.parseJSON("{not json") }
    }
}
