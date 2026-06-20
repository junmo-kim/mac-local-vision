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
                send(error: (-32700, "Parse error"), id: nil)
                continue
            }
            let id = obj["id"]
            guard let method = obj["method"] as? String else {
                if id != nil { send(error: (-32600, "Invalid Request"), id: id) }
                continue
            }
            let params = obj["params"] as? [String: Any] ?? [:]
            await dispatch(method: method, id: id, params: params)
        }
        return ExitCode.success.rawValue
    }

    private static func dispatch(method: String, id: Any?, params: [String: Any]) async {
        switch method {
        case "initialize":
            // Negotiate: echo the client's version only if we support it; otherwise pin
            // our own preferred version (the client then decides whether to proceed).
            let supported: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
            let requested = params["protocolVersion"] as? String
            let negotiated = (requested != nil && supported.contains(requested!)) ? requested! : "2024-11-05"
            send(result: [
                "protocolVersion": negotiated,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "mac-local-vision", "version": version],
            ], id: id)
        case "notifications/initialized", "initialized":
            break // notification — no reply
        case "ping":
            send(result: [String: Any](), id: id)
        case "tools/list":
            send(result: ["tools": MCPTools.all], id: id)
        case "tools/call":
            await handleToolCall(params: params, id: id)
        default:
            if id != nil { send(error: (-32601, "Method not found: \(method)"), id: id) }
        }
    }

    private static func handleToolCall(params: [String: Any], id: Any?) async {
        guard let name = params["name"] as? String else {
            send(error: (-32602, "Missing tool name"), id: id); return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let req = MCPTools.request(for: name, args: args) else {
            send(error: (-32602, "Unknown tool: \(name)"), id: id); return
        }
        // Default to YAML (token-lean, readable for an LLM); honor json on request.
        let fmt = OutputFormat(rawValue: (args["format"] as? String) ?? "yaml") ?? .yaml
        do {
            let result = try await VisionService.handle(req)
            // find-not-found (exitCode 1) is a valid answer, not a tool error.
            send(toolText: result.value.render(as: fmt), isError: false, id: id)
        } catch let e as ServiceError {
            send(toolText: e.envelope().render(as: fmt), isError: true, id: id)
        } catch {
            send(toolText: "error: \(error)", isError: true, id: id)
        }
    }

    // MARK: - JSON-RPC framing

    private static func send(result: [String: Any], id: Any?) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func send(toolText text: String, isError: Bool, id: Any?) {
        send(result: ["content": [["type": "text", "text": text]], "isError": isError], id: id)
    }

    private static func send(error: (Int, String), id: Any?) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(),
               "error": ["code": error.0, "message": error.1]])
    }

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
            Use this to read a whole screen; use `find` to target one specific word.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path to an image (png/jpg/heic/tiff/...) or a PDF."],
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
                "required": ["path"],
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
            headless/blurry renders. Languages auto-detect from the system locale.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path to an image or PDF."],
                    "target": ["type": "string", "description": "The exact text to locate."],
                    "minConfidence": ["type": "number", "description": "Confidence threshold (0..1). Default 0.3."],
                    "languages": ["type": "array", "items": ["type": "string"],
                                  "description": "Recognition languages. Default: system locale."],
                    "page": ["type": "integer", "description": "PDF page. Default 1."],
                    "scale": ["type": "number", "description": "PDF scale. Default 2.0."],
                    "format": ["type": "string", "enum": ["yaml", "json"], "description": "Output format. Default yaml."],
                ],
                "required": ["path", "target"],
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
            (describe this UI, what's the error, which button is primary, summarize this page).
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
                op: "ocr", path: args["path"] as? String,
                fast: args["fast"] as? Bool, words: args["words"] as? Bool, boxes: args["boxes"] as? Bool,
                minConfidence: number(args["minConfidence"]),
                languages: args["languages"] as? [String],
                page: int(args["page"]), scale: number(args["scale"]))
        case "find":
            return VisionRequest(
                op: "find", path: args["path"] as? String, target: args["target"] as? String,
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
