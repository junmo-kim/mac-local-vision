import Foundation

/// The request contract shared by the CLI and the MCP server. A request fully
/// describes one operation; optional fields default at the service layer.
public struct VisionRequest: Codable, Sendable {
    public var op: String              // ocr | find | doctor | ask | ping | barcode | make-qr
    public var path: String?
    public var data: String?           // base64-encoded image/PDF — alternative to path for remote callers
    public var target: String?
    public var prompt: String?
    public var fast: Bool?
    public var words: Bool?
    public var boxes: Bool?
    public var stream: Bool?
    public var minConfidence: Double?
    public var languages: [String]?
    public var page: Int?
    public var scale: Double?
    public var format: String?         // yaml | json — output rendering
    public var symbologies: [String]?  // barcode: restrict to these symbologies (empty/nil = all)
    public var text: String?           // make-qr: the text to encode
    // make-qr: file path to write the PNG to; nil = return `image_data` (base64) instead.
    // Distinct from `path` (which means "input image to read" everywhere else) since
    // make-qr is the first op that *produces* an image rather than consuming one.
    public var outPath: String?
    public var correctionLevel: String? // make-qr: L | M | Q | H (default M)
    public var size: Int?              // make-qr: per-module pixel magnification (default 10)

    public init(op: String, path: String? = nil, data: String? = nil,
                target: String? = nil, prompt: String? = nil,
                fast: Bool? = nil, words: Bool? = nil, boxes: Bool? = nil, stream: Bool? = nil,
                minConfidence: Double? = nil, languages: [String]? = nil,
                page: Int? = nil, scale: Double? = nil, format: String? = nil,
                symbologies: [String]? = nil, text: String? = nil, outPath: String? = nil,
                correctionLevel: String? = nil, size: Int? = nil) {
        self.op = op; self.path = path; self.data = data
        self.target = target; self.prompt = prompt
        self.fast = fast; self.words = words; self.boxes = boxes; self.stream = stream
        self.minConfidence = minConfidence; self.languages = languages
        self.page = page; self.scale = scale; self.format = format
        self.symbologies = symbologies
        self.text = text; self.outPath = outPath
        self.correctionLevel = correctionLevel; self.size = size
    }
}

/// A structured, self-correcting error (cli-api §4): every failure carries a stable
/// `name`, a machine `reason`, and an actionable `hint` so an agent knows what to do
/// next, plus an `exitCode` distinguishing permanent (70) from retryable (71).
public struct ServiceError: Error, Sendable {
    public let name: String
    public let reason: String?
    public let detail: String?
    public let hint: String?
    public let exitCode: Int32

    public init(name: String, reason: String? = nil, detail: String? = nil,
                hint: String? = nil, exitCode: Int32) {
        self.name = name; self.reason = reason; self.detail = detail
        self.hint = hint; self.exitCode = exitCode
    }

    /// Renderable error envelope (stderr / wire / MCP).
    public func envelope() -> YAMLValue {
        var fields: [(String, YAMLValue)] = [("error", .string(name))]
        if let reason { fields.append(("reason", .string(reason))) }
        if let detail { fields.append(("detail", .string(detail))) }
        if let hint { fields.append(("hint", .string(hint))) }
        return .dict(fields)
    }
}

/// Resolves a VisionRequest's input to either a local file path or decoded image bytes.
/// Pure logic — no filesystem access, no Vision dependencies. Used by VisionService and
/// testable from PureLogicTests.
public enum InputSource: Sendable {
    case path(String)
    case data(Data)  // base64-decoded, for remote (non-Mac) callers

    public var label: String {
        if case .path(let p) = self { return p }
        return "<base64 data>"
    }

    /// Resolve from a request's path/data fields. `data` takes precedence over `path`.
    public static func resolve(path: String?, data: String?) throws -> InputSource {
        if let b64 = data, !b64.isEmpty {
            guard let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw ServiceError(name: "bad_request", reason: "invalid_base64",
                                   hint: "data must be a valid base64-encoded image or PDF",
                                   exitCode: 1)
            }
            return .data(decoded)
        }
        guard let p = path, !p.isEmpty else {
            throw ServiceError(name: "bad_request", reason: "missing_input",
                               hint: "provide path (local file) or data (base64-encoded image/PDF)",
                               exitCode: 1)
        }
        return .path(p)
    }
}

/// A successful service result plus the exit code to surface (0, or 1 for find-not-found).
public struct ServiceResult: Sendable {
    public var value: YAMLValue
    public var exitCode: Int32
    public init(_ value: YAMLValue, exitCode: Int32 = 0) {
        self.value = value; self.exitCode = exitCode
    }
}
