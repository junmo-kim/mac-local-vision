import Foundation

/// The request contract shared by the CLI and the MCP server. A request fully
/// describes one operation; optional fields default at the service layer.
public struct VisionRequest: Codable, Sendable {
    public var op: String              // ocr | find | doctor | ask | segment | ping | barcode | qr | make-qr | document-bounds | rectify-document | document-ocr | classify
    public var path: String?
    public var data: String?           // base64-encoded image/PDF — alternative to path for remote callers
    public var target: String?
    public var prompt: String?
    public var fast: Bool?
    public var words: Bool?
    public var boxes: Bool?
    public var stream: Bool?
    public var visionTools: Bool?      // ask: opt in to OCRTool + BarcodeReaderTool
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
    public var top: Int?               // classify: max labels to return (default 20 — see ClassifyEngine)
    // ask: JSON Schema text (MVP subset — see JSONSchemaMapper) requesting Guided Generation.
    // Raw text on the wire either way: the CLI reads a --schema file or takes it inline, and
    // the MCP server re-serializes its native JSON-object `schema` argument into this same
    // field, so VisionService.ask has a single mapping code path regardless of caller.
    public var schema: String?
    public var point: [Double]?        // segment: top-left pixel x,y
    public var box: [Double]?          // segment: top-left pixel x,y,width,height
    public var quality: String?        // segment: accurate | balanced | fast
    public var downloadAssets: Bool?   // segment: explicit model-asset download opt-in

    public init(op: String, path: String? = nil, data: String? = nil,
                target: String? = nil, prompt: String? = nil,
                fast: Bool? = nil, words: Bool? = nil, boxes: Bool? = nil, stream: Bool? = nil,
                visionTools: Bool? = nil,
                minConfidence: Double? = nil, languages: [String]? = nil,
                page: Int? = nil, scale: Double? = nil, format: String? = nil,
                symbologies: [String]? = nil, text: String? = nil, outPath: String? = nil,
                correctionLevel: String? = nil, size: Int? = nil, top: Int? = nil,
                schema: String? = nil, point: [Double]? = nil, box: [Double]? = nil,
                quality: String? = nil, downloadAssets: Bool? = nil) {
        self.op = op; self.path = path; self.data = data
        self.target = target; self.prompt = prompt
        self.fast = fast; self.words = words; self.boxes = boxes; self.stream = stream
        self.visionTools = visionTools
        self.minConfidence = minConfidence; self.languages = languages
        self.page = page; self.scale = scale; self.format = format
        self.symbologies = symbologies
        self.text = text; self.outPath = outPath
        self.correctionLevel = correctionLevel; self.size = size
        self.top = top
        self.schema = schema
        self.point = point; self.box = box
        self.quality = quality; self.downloadAssets = downloadAssets
    }
}

public struct RecoveryStep: Equatable, Sendable {
    public let action: String
    public let command: String?
    public let expected: String

    public init(action: String, command: String? = nil, expected: String) {
        self.action = action
        self.command = command
        self.expected = expected
    }

    public func value() -> YAMLValue {
        var fields: [(String, YAMLValue)] = [
            ("action", .string(action)),
        ]
        if let command { fields.append(("command", .string(command))) }
        fields.append(("expected", .string(expected)))
        return .dict(fields)
    }
}

public struct RecoveryVerification: Equatable, Sendable {
    public let command: String
    public let success: String

    public init(command: String, success: String) {
        self.command = command
        self.success = success
    }

    public func value() -> YAMLValue {
        .dict([
            ("command", .string(command)),
            ("success", .string(success)),
        ])
    }
}

public struct RecoveryFallback: Equatable, Sendable {
    public let action: String
    public let commands: [String]

    public init(action: String, commands: [String]) {
        self.action = action
        self.commands = commands
    }

    public func value() -> YAMLValue {
        .dict([
            ("action", .string(action)),
            ("commands", .array(commands.map(YAMLValue.string))),
        ])
    }
}

public struct RecoveryPlan: Equatable, Sendable {
    public let status: String
    public let steps: [RecoveryStep]
    public let verify: RecoveryVerification
    public let ifUnresolved: RecoveryFallback

    public init(status: String, steps: [RecoveryStep], verify: RecoveryVerification,
                ifUnresolved: RecoveryFallback) {
        self.status = status
        self.steps = steps
        self.verify = verify
        self.ifUnresolved = ifUnresolved
    }

    public func value() -> YAMLValue {
        .dict([
            ("status", .string(status)),
            ("steps", .array(steps.map { $0.value() })),
            ("verify", verify.value()),
            ("if_unresolved", ifUnresolved.value()),
        ])
    }
}

public enum AskRecoveryPlan {
    public static func macLanguage(
        preferredIdentifier: String? = Locale.preferredLanguages.first,
        displayLocale: Locale = .current
    ) -> (identifier: String, displayName: String) {
        let rawIdentifier = preferredIdentifier ?? "und"
        let identifier = Locale(identifier: rawIdentifier).identifier(.bcp47)
        let displayName = displayLocale.localizedString(forIdentifier: identifier) ?? identifier
        return (identifier, displayName)
    }

    public static func plan(
        for reason: String,
        macLanguage: (identifier: String, displayName: String)
    ) -> RecoveryPlan? {
        let doctorVerification = RecoveryVerification(
            command: "macvis doctor --format json",
            success: "ask == \"available\"")
        let diagnosticFallback = RecoveryFallback(
            action: "Retry later, then collect version and doctor output for diagnosis.",
            commands: ["sw_vers", "macvis --version", "macvis doctor --format json"])
        let doctorStep = RecoveryStep(
            action: "Run macvis doctor again.",
            command: "macvis doctor --format json",
            expected: "The ask status changes to available.")

        switch reason {
        case "apple_intelligence_not_enabled":
            return RecoveryPlan(
                status: "Apple Intelligence is not enabled.",
                steps: [
                    RecoveryStep(
                        action: "Enable Apple Intelligence in System Settings.",
                        expected: "Apple Intelligence remains enabled after setup completes."),
                    RecoveryStep(
                        action: "Wait for the on-device model to become ready.",
                        expected: "System Settings no longer shows model preparation in progress."),
                    doctorStep,
                ],
                verify: doctorVerification,
                ifUnresolved: diagnosticFallback)

        case "model_not_ready":
            return RecoveryPlan(
                status: "The on-device language model is not ready yet.",
                steps: [
                    RecoveryStep(
                        action: "The current Mac language is \(macLanguage.displayName) (\(macLanguage.identifier)). In System Settings, set the Siri language to match it.",
                        expected: "The Mac and Siri language selections match."),
                    RecoveryStep(
                        action: "Check the download progress at the top of the Apple Intelligence settings page.",
                        expected: "A download percentage appears and continues toward completion."),
                    RecoveryStep(
                        action: "Keep the Mac connected to power and a stable network while the download finishes.",
                        expected: "The model download completes without being interrupted."),
                    doctorStep,
                ],
                verify: doctorVerification,
                ifUnresolved: diagnosticFallback)

        case "device_not_eligible":
            return RecoveryPlan(
                status: "This Mac is not eligible to run ask on-device.",
                steps: [
                    RecoveryStep(
                        action: "Run ask on an Apple Intelligence eligible Apple Silicon Mac.",
                        expected: "The eligible Mac is signed in, uses a supported region, and boots from its internal disk."),
                    doctorStep,
                ],
                verify: doctorVerification,
                ifUnresolved: diagnosticFallback)

        case "needs_macos_27_for_image_input":
            return RecoveryPlan(
                status: "Image input for ask requires macOS 27 or later.",
                steps: [
                    RecoveryStep(
                        action: "Update this Mac to macOS 27 or later.",
                        expected: "sw_vers reports macOS 27 or later."),
                    doctorStep,
                ],
                verify: doctorVerification,
                ifUnresolved: diagnosticFallback)

        case "model_assets_unavailable":
            return RecoveryPlan(
                status: "The on-device model assets are not available yet.",
                steps: [
                    RecoveryStep(
                        action: "Wait for the Apple Intelligence model download to finish.",
                        expected: "System Settings no longer shows an active model download."),
                    RecoveryStep(
                        action: "Keep the Mac connected to power and a stable network, then retry.",
                        expected: "The model assets remain available for the next request."),
                ],
                verify: doctorVerification,
                ifUnresolved: diagnosticFallback)

        case "session_busy":
            return RecoveryPlan(
                status: "Another request is already using this language model session.",
                steps: [
                    RecoveryStep(
                        action: "Wait for the in-flight ask request to finish before retrying.",
                        expected: "Only one request is using the session."),
                ],
                verify: RecoveryVerification(
                    command: "Retry the original macvis ask command.",
                    success: "The command exits 0 and returns an answer."),
                ifUnresolved: diagnosticFallback)

        case "content_safety_model_not_ready":
            return RecoveryPlan(
                status: "A secondary safety model is still initializing.",
                steps: [
                    RecoveryStep(
                        action: "Wait briefly after the main model download completes, then retry.",
                        expected: "The secondary model finishes initializing."),
                ],
                verify: RecoveryVerification(
                    command: "Retry the original macvis ask command.",
                    success: "The command exits 0 and returns an answer."),
                ifUnresolved: diagnosticFallback)

        case "rate_limited":
            return RecoveryPlan(
                status: "The on-device model temporarily rate limited this session.",
                steps: [
                    RecoveryStep(
                        action: "Wait briefly before retrying the request.",
                        expected: "The temporary request limit clears."),
                ],
                verify: RecoveryVerification(
                    command: "Retry the original macvis ask command.",
                    success: "The command exits 0 and returns an answer."),
                ifUnresolved: diagnosticFallback)

        case "timeout":
            return RecoveryPlan(
                status: "The model did not respond before the request timed out.",
                steps: [
                    RecoveryStep(
                        action: "Retry with a smaller image or a shorter prompt.",
                        expected: "The request completes within the timeout."),
                ],
                verify: RecoveryVerification(
                    command: "Retry the adjusted macvis ask command.",
                    success: "The command exits 0 and returns an answer."),
                ifUnresolved: diagnosticFallback)

        default:
            return nil
        }
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
    public let recovery: RecoveryPlan?
    public let exitCode: Int32

    public init(name: String, reason: String? = nil, detail: String? = nil,
                hint: String? = nil, recovery: RecoveryPlan? = nil, exitCode: Int32) {
        self.name = name; self.reason = reason; self.detail = detail
        self.hint = hint; self.recovery = recovery; self.exitCode = exitCode
    }

    /// Renderable error envelope (stderr / wire / MCP).
    public func envelope() -> YAMLValue {
        var fields: [(String, YAMLValue)] = [("error", .string(name))]
        if let reason { fields.append(("reason", .string(reason))) }
        if let detail { fields.append(("detail", .string(detail))) }
        if let hint { fields.append(("hint", .string(hint))) }
        if let recovery { fields.append(("recovery", recovery.value())) }
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
