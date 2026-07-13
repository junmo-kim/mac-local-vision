import Foundation
import VisionCore  // ServiceError / ExitCode — the shared bad_request error shape (Wire.swift)

#if canImport(FoundationModels)
import FoundationModels

/// Maps a user-supplied JSON Schema (MVP subset) into Apple's runtime `GenerationSchema`,
/// for `AFMEngine.ask(schema:)` Guided Generation. Pure logic — imports only
/// Foundation/FoundationModels' *schema* types, never touches LanguageModelSession or
/// Attachment, so a malformed/unsupported schema is rejected before any model call is
/// attempted. That separation is deliberate: the SIGSEGV crash fixed on macOS 27 Beta
/// (26A5378j — see AFMEngine.ask's doc comment) happened *inside* a live model call, so
/// keeping schema validation fully upstream of `probeAskAvailability()`/session creation
/// means a bad `--schema` can never be the thing that reaches that crash-prone code path.
///
/// `GenerationSchema`/`DynamicGenerationSchema` are `@available(macOS 26, *)` — present in
/// the ordinary macOS 26 SDK (verified against Xcode 26.4.1's FoundationModels.swiftinterface),
/// independent of the macOS-27-only multimodal image API and the `MACVIS_ASK_IMAGE` compile
/// flag. So this mapper (and its tests) build and run under plain `swift build`/`swift test`.
///
/// Supported subset: object (named properties) / string (+ `enum`) / integer / number /
/// boolean / array (single-schema `items`) / `required`. Deliberately unsupported — reported
/// as `bad_request/unsupported_schema_feature` rather than silently ignored: composition &
/// reference keywords (`$ref`, `anyOf`, `oneOf`, `allOf`, `not`, `pattern`, `$defs`) and value
/// constraints the generated schema can't actually enforce (`minimum`/`maximum`/
/// `exclusiveMinimum`/`exclusiveMaximum`/`multipleOf`, `minLength`/`maxLength`/`format`,
/// `const`, `minItems`/`maxItems`/`uniqueItems`, and `enum` on a non-string type). Rejecting
/// these avoids the model "successfully" generating output that quietly ignores the
/// constraint the caller asked for. Annotation-only keywords (`title`/`description`/
/// `default`/`examples`) are allowed — they don't change the generated structure.
/// Everything else structurally wrong is `bad_request/invalid_schema`. Both are exit 64
/// (usage — retrying without changing the schema is pointless), matching the rest of the
/// CLI's bad_request convention.
// Deployment target is macOS 26 (Package.swift), so no extra #available guard is needed here.
public enum JSONSchemaMapper {
    /// Sanity caps against pathological input (deeply nested / huge schemas) — same risk
    /// class as `make-qr --size` needing a raster cap. Not part of JSON Schema itself, just
    /// this mapper's own defensiveness.
    private static let maxDepth = 10
    private static let maxProperties = 100

    /// Keywords this MVP subset explicitly does not support. Presence anywhere in a schema
    /// node is rejected rather than silently ignored (silent ignoring would make the model
    /// "successfully" generate content that doesn't actually honor the constraint the caller
    /// asked for). Two groups: composition/reference keywords (structurally unmodelable) and
    /// value constraints (`DynamicGenerationSchema` can't enforce them). Annotation-only
    /// keywords (title/description/default/examples) are intentionally absent — ignoring them
    /// is harmless since they don't affect generated structure. (`enum` is handled per-node,
    /// not here: supported for string, rejected on other types — see `mapNode`.)
    private static let unsupportedKeywords = [
        // composition / references — structurally unsupported
        "$ref", "anyOf", "oneOf", "allOf", "not", "pattern", "$defs",
        // value constraints — not enforceable by the generated schema, so reject rather
        // than emit an unconstrained value that looks like it honored them
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "minLength", "maxLength", "format", "const",
        "minItems", "maxItems", "uniqueItems",
    ]

    public static func map(_ jsonSchemaText: String) throws -> GenerationSchema {
        guard let data = jsonSchemaText.data(using: .utf8) else {
            throw invalidSchema("schema text is not valid UTF-8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw invalidSchema("not valid JSON: \(error.localizedDescription)")
        }
        guard let root = parsed as? [String: Any] else {
            throw invalidSchema("schema root must be a JSON object")
        }
        let dynamicSchema = try mapNode(root, path: "root", depth: 0)
        do {
            return try GenerationSchema(root: dynamicSchema, dependencies: [])
        } catch {
            // GenerationSchema.SchemaError (duplicate names, empty anyOf, ...) — shouldn't
            // normally trigger given how mapNode names things, but surfaced defensively
            // rather than left as an unmapped/uncaught model-layer error.
            throw invalidSchema("schema assembly failed: \(error.localizedDescription)")
        }
    }

    // MARK: - node mapping (recursive)

    private static func mapNode(_ node: [String: Any], path: String, depth: Int) throws -> DynamicGenerationSchema {
        if depth > maxDepth {
            throw invalidSchema("nesting exceeds the max depth (\(maxDepth)) at \(path)")
        }
        for keyword in unsupportedKeywords where node[keyword] != nil {
            throw unsupportedFeature(keyword, path: path)
        }
        guard let type = node["type"] as? String else {
            throw invalidSchema("missing or non-string \"type\" at \(path)")
        }
        // `enum` is only modeled for string (→ `anyOf` choices). On any other type the
        // constraint would be silently dropped, so reject it rather than ignore it.
        if type != "string", node["enum"] != nil {
            throw unsupportedFeature("enum on a non-string type", path: path)
        }
        let description = node["description"] as? String
        switch type {
        case "object":
            return try mapObject(node, path: path, depth: depth, description: description)
        case "string":
            if let rawEnum = node["enum"] {
                guard let choices = rawEnum as? [String] else {
                    throw invalidSchema("\"enum\" at \(path) must be an array of strings")
                }
                guard !choices.isEmpty else {
                    throw invalidSchema("\"enum\" at \(path) must not be empty")
                }
                return DynamicGenerationSchema(name: path, description: description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = node["items"] as? [String: Any] else {
                throw invalidSchema(
                    "array at \(path) needs a single-schema \"items\" object " +
                    "(tuple-form \"items\" arrays are not supported in this MVP subset)")
            }
            let itemSchema = try mapNode(items, path: "\(path)[]", depth: depth + 1)
            return DynamicGenerationSchema(arrayOf: itemSchema)
        default:
            throw invalidSchema("unsupported \"type\": \"\(type)\" at \(path)")
        }
    }

    private static func mapObject(_ node: [String: Any], path: String, depth: Int,
                                  description: String?) throws -> DynamicGenerationSchema {
        guard let properties = node["properties"] as? [String: Any] else {
            throw invalidSchema("object at \(path) needs a \"properties\" object")
        }
        guard !properties.isEmpty else {
            throw invalidSchema("object at \(path) has no properties")
        }
        guard properties.count <= maxProperties else {
            throw invalidSchema("object at \(path) exceeds the max property count (\(maxProperties))")
        }
        let required: Set<String>
        if let rawRequired = node["required"] {
            guard let names = rawRequired as? [String] else {
                throw invalidSchema("\"required\" at \(path) must be an array of strings")
            }
            required = Set(names)
        } else {
            required = []
        }
        // JSONSerialization doesn't preserve key order — sort for deterministic output
        // (matters for test stability and reproducible schema debug-description dumps).
        var mappedProperties: [DynamicGenerationSchema.Property] = []
        for name in properties.keys.sorted() {
            guard let sub = properties[name] as? [String: Any] else {
                throw invalidSchema("property \"\(name)\" at \(path) must be a schema object")
            }
            let subSchema = try mapNode(sub, path: "\(path).\(name)", depth: depth + 1)
            mappedProperties.append(.init(name: name, description: sub["description"] as? String,
                                          schema: subSchema, isOptional: !required.contains(name)))
        }
        return DynamicGenerationSchema(name: path, description: description, properties: mappedProperties)
    }

    // MARK: - errors

    private static func invalidSchema(_ detail: String) -> ServiceError {
        ServiceError(name: "bad_request", reason: "invalid_schema", detail: detail,
                    hint: "check the JSON Schema syntax against the supported MVP subset " +
                          "(object/string/integer/number/boolean/array/required).",
                    exitCode: ExitCode.usage.rawValue)
    }

    private static func unsupportedFeature(_ keyword: String, path: String) -> ServiceError {
        ServiceError(name: "bad_request", reason: "unsupported_schema_feature",
                    detail: "\"\(keyword)\" at \(path) is not supported in this MVP subset",
                    hint: "supported: object/string(+enum)/integer/number/boolean/array/required — " +
                          "no composition ($ref/anyOf/oneOf/allOf/not/$defs) or value constraints " +
                          "(pattern/format/minimum/maximum/const/minLength/minItems/...).",
                    exitCode: ExitCode.usage.rawValue)
    }
}
#endif
