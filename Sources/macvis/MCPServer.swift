import Foundation
import VisionCore

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). This is the
/// primary way an LLM/agent uses the tool, so tool descriptions encode *when* to use
/// each one, the coordinate convention, and availability — the LLM UX lives here.
/// Calls run in-process through `VisionService`.
///
/// Transport rule: stdout carries ONLY JSON-RPC messages. Never call IO.emit here.
enum MCPServer {
    static func run() async -> Int32 {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                write(["jsonrpc": "2.0", "id": NSNull(),
                       "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let response = await computeResponse(for: obj) {
                write(response)
            }
        }
        return ExitCode.success.rawValue
    }

    /// Compute a JSON-RPC 2.0 response for a single request object.
    /// Returns nil for notifications (no id / method not requiring reply).
    /// Used by both the stdio transport (run()) and the HTTP transport (HTTPServer).
    static func computeResponse(for obj: [String: Any]) async -> [String: Any]? {
        let id = obj["id"]
        guard let method = obj["method"] as? String else {
            if id != nil { return errorResp((-32600, "Invalid Request"), id: id) }
            return nil
        }
        // JSON-RPC 2.0 §5: a request with no `id` field is a notification — never reply.
        guard id != nil else { return nil }
        let params = obj["params"] as? [String: Any] ?? [:]
        return await dispatch(method: method, id: id, params: params)
    }

    // MARK: - dispatch

    private static func dispatch(method: String, id: Any?, params: [String: Any]) async -> [String: Any]? {
        switch method {
        case "initialize":
            // Negotiate: echo the client's version only if we support it; otherwise pin
            // our own preferred version (the client then decides whether to proceed).
            let supported: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
            let requested = params["protocolVersion"] as? String
            let negotiated = (requested != nil && supported.contains(requested!)) ? requested! : "2024-11-05"
            return resultResp([
                "protocolVersion": negotiated,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "mac-local-vision", "version": version],
            ], id: id)
        case "ping":
            return resultResp([String: Any](), id: id)
        case "tools/list":
            return resultResp(["tools": MCPTools.all], id: id)
        case "tools/call":
            return await handleToolCall(params: params, id: id)
        default:
            return errorResp((-32601, "Method not found: \(method)"), id: id)
        }
    }

    private static func handleToolCall(params: [String: Any], id: Any?) async -> [String: Any]? {
        guard let name = params["name"] as? String else {
            return errorResp((-32602, "Missing tool name"), id: id)
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let req = MCPTools.request(for: name, args: args) else {
            return errorResp((-32602, "Unknown tool: \(name)"), id: id)
        }
        // Default to YAML (token-lean, readable for an LLM); honor json on request.
        let fmt = OutputFormat(rawValue: (args["format"] as? String) ?? "yaml") ?? .yaml
        do {
            let result = try await VisionService.handle(req)
            // find-not-found (exitCode 1) is a valid answer, not a tool error.
            return toolTextResp(result.value.render(as: fmt), isError: false, id: id)
        } catch let e as ServiceError {
            return toolTextResp(e.envelope().render(as: fmt), isError: true, id: id)
        } catch {
            return toolTextResp("error: \(error)", isError: true, id: id)
        }
    }

    // MARK: - response builders

    // Invariant: callers only reach these builders after `guard id != nil` fires in
    // computeResponse(), so `id` is always non-nil here. NSNull() (explicit "id":null from
    // a client) is non-nil in Swift — `if let id` binds it and serializes to "id":null per
    // JSON-RPC 2.0 §5. Do NOT add `!(id is NSNull)` — that would silently drop required fields.

    private static func resultResp(_ result: [String: Any], id: Any?) -> [String: Any] {
        var d: [String: Any] = ["jsonrpc": "2.0", "result": result]
        d["id"] = id ?? NSNull()
        return d
    }

    private static func errorResp(_ error: (Int, String), id: Any?) -> [String: Any] {
        var d: [String: Any] = ["jsonrpc": "2.0",
                                "error": ["code": error.0, "message": error.1]]
        d["id"] = id ?? NSNull()
        return d
    }

    private static func toolTextResp(_ text: String, isError: Bool, id: Any?) -> [String: Any] {
        resultResp(["content": [["type": "text", "text": text]], "isError": isError], id: id)
    }

    // MARK: - stdio write

    private static func write(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

/// Tool catalog + argument mapping to `VisionRequest`. Computed (not stored) so the
/// non-Sendable `[String: Any]` literals don't become shared mutable global state.
enum MCPTools {
    static var all: [[String: Any]] {
        // Capability-matched: only advertise `ask` when this binary was built with the
        // macOS 27 multimodal path. `request(for:)` still maps a direct `ask` call on any
        // build (→ structured needs_macos_27 error, not a bare "unknown tool").
        var tools: [[String: Any]] = [ocr, find, doctor]
        #if MACVIS_ASK_IMAGE
        tools.append(ask)
        #endif
        return tools
    }

    static var ocr: [String: Any] {
        [
            "name": "ocr",
            "description": """
            Zero-token OCR: read all text from an image or PDF locally on the Mac NPU \
            (no cloud, no vision tokens spent). Returns the full text plus per-line entries. \
            Coordinates are opt-in to stay token-lean: set boxes=true for per-line pixel boxes, \
            words=true for per-word boxes. Coordinate convention: x,y = click center; \
            left/top/width/height = bounding box; top-left origin; physical pixels. Recognition \
            languages auto-detect from the system locale (override via languages). \
            Use this to read a whole screen; use `find` to target one specific word. \
            Remote callers (non-Mac nodes): send the image as base64 in the `data` field instead of `path`.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path to an image (png/jpg/heic/tiff/...) or a PDF. Required if `data` is not provided."],
                    "data": ["type": "string", "description": "Base64-encoded image or PDF for remote (non-Mac) callers. Required if `path` is not provided. Takes precedence over `path` when both are supplied."],
                    "boxes": ["type": "boolean", "description": "Include per-line pixel coordinates. Default false."],
                    "words": ["type": "boolean", "description": "Include per-word coordinates (implies boxes). Default false."],
                    "fast": ["type": "boolean", "description": "Faster, lower-accuracy mode. Default false."],
                    "minConfidence": ["type": "number", "description": "Drop results below this confidence (0..1). Default 0."],
                    "languages": ["type": "array", "items": ["type": "string"],
                                  "description": "Recognition languages, e.g. [\"ko-KR\",\"en-US\"]. Default: system locale."],
                    "page": ["type": "integer", "description": "PDF page, 1-based. Default 1."],
                    "scale": ["type": "number", "description": "PDF rasterization scale (2.0 ≈ 144 dpi). Default 2.0."],
                    "format": ["type": "string", "enum": ["yaml", "json"], "description": "Output format of the text block. Default yaml."],
                ],
                // `required` intentionally omitted: path and data are mutually exclusive
                // alternatives (XOR) that JSON Schema `required` cannot express — both are
                // effectively required but only one must be present. `find` includes
                // `required: ["target"]` because target is unconditionally required.
            ],
        ]
    }

    static var find: [String: Any] {
        [
            "name": "find",
            "description": """
            Locate a specific word/phrase on a screenshot and return the exact pixel center \
            to click (x,y) plus its bounding box — for fast E2E/UI targeting. ALWAYS check the \
            `found` field: it is false when the target is absent. When `approximate: true` is \
            present, the box is the whole text line (click point is line-center, not word-tight). \
            Coordinate convention: top-left origin, physical pixels. Lower minConfidence for \
            headless/blurry renders. Languages auto-detect from the system locale. \
            Remote callers (non-Mac nodes): send the image as base64 in the `data` field instead of `path`.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path to an image or PDF. Use for local Mac callers."],
                    "data": ["type": "string", "description": "Base64-encoded image or PDF for remote callers. Takes precedence over `path` when both are supplied."],
                    "target": ["type": "string", "description": "The exact text to locate."],
                    "minConfidence": ["type": "number", "description": "Confidence threshold (0..1). Default 0.3."],
                    "languages": ["type": "array", "items": ["type": "string"],
                                  "description": "Recognition languages. Default: system locale."],
                    "page": ["type": "integer", "description": "PDF page. Default 1."],
                    "scale": ["type": "number", "description": "PDF scale. Default 2.0."],
                    "format": ["type": "string", "enum": ["yaml", "json"], "description": "Output format. Default yaml."],
                ],
                "required": ["target"],
            ],
        ]
    }

    static var doctor: [String: Any] {
        [
            "name": "doctor",
            "description": """
            Report which vision modes work on this machine and the default OCR languages. \
            Call this first if unsure whether `ask` (multimodal reasoning; needs macOS 27 + Apple Intelligence) \
            is available — ocr/find work on any Apple Silicon + macOS 26.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ]
    }

    static var ask: [String: Any] {
        [
            "name": "ask",
            "description": """
            Beta — ask a natural-language question ABOUT an image/screenshot/PDF and get a \
            reasoned answer, computed entirely on-device via Apple Foundation Models (no \
            cloud, no tokens). Needs macOS 27 + Apple Intelligence; on older systems it \
            returns a structured availability error (check `error`/`reason`). Use `ocr`/`find` \
            for plain text or pixel targeting — use `ask` when you need interpretation \
            (describe this UI, what's the error, which button is primary, summarize this page). \
            Requires local filesystem access via `path` — remote HTTP callers cannot pass images \
            in-memory for this tool; use `ocr`/`find` with `data` instead.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path to an image (png/jpg/heic/...) or a PDF."],
                    "prompt": ["type": "string", "description": "The question to ask about the image."],
                    "page": ["type": "integer", "description": "PDF page, 1-based. Default 1."],
                    "scale": ["type": "number", "description": "PDF rasterization scale (2.0 ≈ 144 dpi). Default 2.0."],
                    "format": ["type": "string", "enum": ["yaml", "json"], "description": "Output format. Default yaml."],
                ],
                "required": ["path", "prompt"],
            ],
        ]
    }

    static func request(for name: String, args: [String: Any]) -> VisionRequest? {
        switch name {
        case "ocr":
            return VisionRequest(
                op: "ocr", path: args["path"] as? String, data: args["data"] as? String,
                fast: args["fast"] as? Bool, words: args["words"] as? Bool, boxes: args["boxes"] as? Bool,
                minConfidence: number(args["minConfidence"]),
                languages: args["languages"] as? [String],
                page: int(args["page"]), scale: number(args["scale"]))
        case "find":
            return VisionRequest(
                op: "find", path: args["path"] as? String, data: args["data"] as? String,
                target: args["target"] as? String,
                minConfidence: number(args["minConfidence"]),
                languages: args["languages"] as? [String],
                page: int(args["page"]), scale: number(args["scale"]))
        case "ask":
            return VisionRequest(
                op: "ask", path: args["path"] as? String, prompt: args["prompt"] as? String,
                page: int(args["page"]), scale: number(args["scale"]))
        case "doctor":
            return VisionRequest(op: "doctor")
        default:
            return nil
        }
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
