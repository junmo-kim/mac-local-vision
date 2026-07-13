#if canImport(FoundationModels)
import Testing
import VisionCore
@testable import SemanticEngine

/// `JSONSchemaMapper.map` turns a user-supplied JSON Schema (MVP subset) into a
/// FoundationModels `GenerationSchema`, entirely independent of the model/session APIs —
/// see AFMEngine.ask's crash-defense doc comment. These tests never touch
/// LanguageModelSession/Attachment, so they run under plain `swift test`, no
/// MACVIS_ASK_IMAGE flag and no macOS 27 SDK needed (GenerationSchema/DynamicGenerationSchema
/// are @available(macOS 26, *) — verified against the Xcode 26.4.1 SDK's
/// FoundationModels.swiftinterface).
// Deployment target is macOS 26 (Package.swift), so no extra #available guard needed here.
@Suite("JSONSchemaMapper — MVP JSON Schema subset → GenerationSchema")
struct JSONSchemaMapperTests {

    // MARK: - accepted (normal) cases — mapping must not throw

    @Test("flat object: string/integer/number/boolean properties, some required")
    func flatObject() throws {
        let json = """
        {"type":"object","properties":{
            "merchant":{"type":"string"},
            "total":{"type":"number"},
            "count":{"type":"integer"},
            "paid":{"type":"boolean"}
        },"required":["merchant","total"]}
        """
        _ = try JSONSchemaMapper.map(json)
    }

    @Test("string with enum choices")
    func stringEnum() throws {
        let json = """
        {"type":"object","properties":{
            "status":{"type":"string","enum":["open","closed","pending"]}
        },"required":["status"]}
        """
        _ = try JSONSchemaMapper.map(json)
    }

    @Test("array of a single item schema")
    func arrayOfItems() throws {
        let json = """
        {"type":"object","properties":{
            "tags":{"type":"array","items":{"type":"string"}}
        },"required":["tags"]}
        """
        _ = try JSONSchemaMapper.map(json)
    }

    @Test("nested object property")
    func nestedObject() throws {
        let json = """
        {"type":"object","properties":{
            "address":{"type":"object","properties":{
                "city":{"type":"string"},
                "zip":{"type":"string"}
            },"required":["city"]}
        },"required":["address"]}
        """
        _ = try JSONSchemaMapper.map(json)
    }

    @Test("no required array at all — every property optional")
    func noRequired() throws {
        let json = """
        {"type":"object","properties":{"note":{"type":"string"}}}
        """
        _ = try JSONSchemaMapper.map(json)
    }

    // MARK: - malformed cases — mapping must throw ServiceError(bad_request/invalid_schema)

    @Test("not valid JSON at all")
    func notJSON() {
        expectInvalidSchema { try JSONSchemaMapper.map("{not json") }
    }

    @Test("root is a JSON array, not an object")
    func rootNotObject() {
        expectInvalidSchema { try JSONSchemaMapper.map("[1,2,3]") }
    }

    @Test("missing \"type\" keyword")
    func missingType() {
        expectInvalidSchema { try JSONSchemaMapper.map(#"{"properties":{}}"#) }
    }

    @Test("unsupported \"type\" value")
    func unsupportedTypeValue() {
        expectInvalidSchema { try JSONSchemaMapper.map(#"{"type":"null"}"#) }
    }

    @Test("object missing \"properties\"")
    func objectMissingProperties() {
        expectInvalidSchema { try JSONSchemaMapper.map(#"{"type":"object"}"#) }
    }

    @Test("object with empty properties")
    func objectEmptyProperties() {
        expectInvalidSchema { try JSONSchemaMapper.map(#"{"type":"object","properties":{}}"#) }
    }

    @Test("\"required\" contains a non-string element")
    func requiredNonString() {
        let json = #"{"type":"object","properties":{"a":{"type":"string"}},"required":[1]}"#
        expectInvalidSchema { try JSONSchemaMapper.map(json) }
    }

    @Test("empty enum array")
    func emptyEnum() {
        let json = #"{"type":"object","properties":{"s":{"type":"string","enum":[]}},"required":["s"]}"#
        expectInvalidSchema { try JSONSchemaMapper.map(json) }
    }

    @Test("array with tuple-form items (array of schemas) is not the supported single-schema form")
    func arrayTupleItems() {
        let json = #"{"type":"object","properties":{"a":{"type":"array","items":[{"type":"string"}]}},"required":["a"]}"#
        expectInvalidSchema { try JSONSchemaMapper.map(json) }
    }

    @Test("property value that isn't itself a schema object")
    func propertyNotSchemaObject() {
        let json = #"{"type":"object","properties":{"a":"not-a-schema"}}"#
        expectInvalidSchema { try JSONSchemaMapper.map(json) }
    }

    @Test("nesting deeper than the sanity depth cap")
    func tooDeep() {
        // 12 levels of nested single-property objects — over the mapper's depth cap.
        var json = #"{"type":"string"}"#
        for i in 0..<12 {
            json = #"{"type":"object","properties":{"p\#(i)":\#(json)},"required":["p\#(i)"]}"#
        }
        expectInvalidSchema { try JSONSchemaMapper.map(json) }
    }

    // MARK: - unsupported-feature cases — bad_request/unsupported_schema_feature, exit 64

    @Test("$ref is out of MVP scope")
    func refUnsupported() {
        let json = ##"{"type":"object","$ref":"#/$defs/Thing","properties":{}}"##
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("oneOf is out of MVP scope")
    func oneOfUnsupported() {
        let json = #"{"oneOf":[{"type":"string"},{"type":"integer"}]}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("anyOf is out of MVP scope")
    func anyOfUnsupported() {
        let json = #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("allOf is out of MVP scope")
    func allOfUnsupported() {
        let json = #"{"allOf":[{"type":"object","properties":{}}]}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("pattern is out of MVP scope")
    func patternUnsupported() {
        let json = #"{"type":"object","properties":{"a":{"type":"string","pattern":"^[a-z]+$"}},"required":["a"]}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("$defs is out of MVP scope")
    func defsUnsupported() {
        let json = #"{"type":"object","$defs":{"Thing":{"type":"string"}},"properties":{}}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("not is out of MVP scope")
    func notUnsupported() {
        let json = #"{"type":"object","not":{"type":"string"},"properties":{}}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("enum on a non-string type is rejected, not silently dropped")
    func nonStringEnumUnsupported() {
        let json = #"{"type":"object","properties":{"n":{"type":"integer","enum":[1,2,3]}},"required":["n"]}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("numeric value constraint (minimum) is rejected, not silently dropped")
    func minimumUnsupported() {
        let json = #"{"type":"object","properties":{"n":{"type":"integer","minimum":0}},"required":["n"]}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("string format constraint is rejected, not silently dropped")
    func formatUnsupported() {
        let json = #"{"type":"object","properties":{"d":{"type":"string","format":"date"}},"required":["d"]}"#
        expectUnsupportedFeature { try JSONSchemaMapper.map(json) }
    }

    @Test("annotation keywords (title/default) are allowed, not rejected")
    func annotationsAllowed() throws {
        // title/default don't change generated structure — mapping must succeed.
        let json = #"{"type":"object","title":"Receipt","properties":{"m":{"type":"string","default":"x"}},"required":["m"]}"#
        _ = try JSONSchemaMapper.map(json)
    }
}

// MARK: - helpers

private func expectInvalidSchema(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected a thrown ServiceError, but mapping succeeded")
    } catch let e as ServiceError {
        #expect(e.name == "bad_request")
        #expect(e.reason == "invalid_schema")
        #expect(e.exitCode == ExitCode.usage.rawValue)
    } catch {
        Issue.record("expected ServiceError, got \(error)")
    }
}

private func expectUnsupportedFeature(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected a thrown ServiceError, but mapping succeeded")
    } catch let e as ServiceError {
        #expect(e.name == "bad_request")
        #expect(e.reason == "unsupported_schema_feature")
        #expect(e.exitCode == ExitCode.usage.rawValue)
    } catch {
        Issue.record("expected ServiceError, got \(error)")
    }
}
#endif
