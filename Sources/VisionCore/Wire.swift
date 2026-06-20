import Foundation

/// The request contract shared by the CLI and the MCP server. A request fully
/// describes one operation; optional fields default at the service layer.
public struct VisionRequest: Codable, Sendable {
    public var op: String              // ocr | find | doctor | ask | ping
    public var path: String?
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

    public init(op: String, path: String? = nil, target: String? = nil, prompt: String? = nil,
                fast: Bool? = nil, words: Bool? = nil, boxes: Bool? = nil, stream: Bool? = nil,
                minConfidence: Double? = nil, languages: [String]? = nil,
                page: Int? = nil, scale: Double? = nil, format: String? = nil) {
        self.op = op; self.path = path; self.target = target; self.prompt = prompt
        self.fast = fast; self.words = words; self.boxes = boxes; self.stream = stream
        self.minConfidence = minConfidence; self.languages = languages
        self.page = page; self.scale = scale; self.format = format
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

/// A successful service result plus the exit code to surface (0, or 1 for find-not-found).
public struct ServiceResult: Sendable {
    public var value: YAMLValue
    public var exitCode: Int32
    public init(_ value: YAMLValue, exitCode: Int32 = 0) {
        self.value = value; self.exitCode = exitCode
    }
}
