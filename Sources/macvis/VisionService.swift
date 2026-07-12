import Foundation
import VisionCore
import SemanticEngine

/// The single engine seam. CLI commands and the MCP server both go through here, so
/// output is identical across interfaces.
enum VisionService {
    static func handle(_ req: VisionRequest) async throws -> ServiceResult {
        switch req.op {
        case "ocr":    return try ocr(req)
        case "find":   return try find(req)
        case "doctor": return ServiceResult(doctor())
        case "ask":    return try await ask(req)
        case "ping":   return ServiceResult(.dict([("ok", .bool(true))]))
        case "barcode": return try barcode(req)
        default:
            throw ServiceError(name: "bad_request", reason: "unknown_op", detail: req.op,
                               hint: "ops: ocr | find | doctor | ask | barcode", exitCode: ExitCode.usage.rawValue)
        }
    }

    // MARK: - Input resolution (pure logic lives in VisionCore.InputSource.resolve)

    // MARK: - ocr

    static func ocr(_ req: VisionRequest) throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        let withWords = req.words ?? false
        let withBoxes = (req.boxes ?? false) || withWords  // --words implies line boxes
        do {
            let r: OCRResult
            switch input {
            case .path(let p):
                r = try OCREngine.recognize(
                    path: p, fast: req.fast ?? false, minConfidence: req.minConfidence ?? 0.0,
                    languages: req.languages ?? [], includeWords: withWords,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try OCREngine.recognize(
                    data: d, fast: req.fast ?? false, minConfidence: req.minConfidence ?? 0.0,
                    languages: req.languages ?? [], includeWords: withWords,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            }
            let w = r.imageWidth, h = r.imageHeight
            let lines = r.lines.map { line -> YAMLValue in
                var fields: [(String, YAMLValue)] = [
                    ("text", .string(line.text)), ("confidence", .double(line.confidence)),
                ]
                if withBoxes { fields.append(contentsOf: boxFields(line.rect, w, h)) }
                if withWords {
                    let words = line.words.map { YAMLValue.dict([("text", .string($0.text))] + boxFields($0.rect, w, h)) }
                    fields.append(("words", .array(words)))
                }
                return .dict(fields)
            }
            return ServiceResult(.dict([
                ("image_width", .int(w)), ("image_height", .int(h)),
                ("line_count", .int(r.lines.count)),
                ("text", .string(r.fullText)),
                ("lines", .array(lines)),
            ]))
        } catch let e as VisionError {
            throw imageError(e, label: input.label)
        }
    }

    // MARK: - find

    static func find(_ req: VisionRequest) throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        guard let target = req.target, !target.isEmpty else {
            throw ServiceError(name: "bad_request", reason: "missing_target",
                               hint: "find requires the target text to locate", exitCode: ExitCode.usage.rawValue)
        }
        do {
            let hit: FindResult?
            switch input {
            case .path(let p):
                hit = try OCREngine.find(
                    path: p, target: target, minConfidence: req.minConfidence ?? 0.3,
                    languages: req.languages ?? [], page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                hit = try OCREngine.find(
                    data: d, target: target, minConfidence: req.minConfidence ?? 0.3,
                    languages: req.languages ?? [], page: req.page ?? 1, scale: req.scale ?? 2.0)
            }
            guard let hit else {
                // Not found is a valid outcome (not an error): result + exit 1 for `&&` chains.
                return ServiceResult(.dict([("found", .bool(false)), ("target", .string(target))]), exitCode: 1)
            }
            var fields: [(String, YAMLValue)] = [
                ("found", .bool(true)),
                ("x", .int(hit.rect.centerX)), ("y", .int(hit.rect.centerY)),
                ("left", .int(hit.rect.x)), ("top", .int(hit.rect.y)),
                ("width", .int(hit.rect.width)), ("height", .int(hit.rect.height)),
                ("confidence", .double(hit.confidence)), ("text_found", .string(hit.textFound)),
            ]
            // Only surfaced when the box is line-level (click point is not word-tight).
            if hit.approximate { fields.append(("approximate", .bool(true))) }
            return ServiceResult(.dict(fields))
        } catch let e as VisionError {
            throw imageError(e, label: input.label)
        }
    }

    // MARK: - barcode

    static func barcode(_ req: VisionRequest) throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        do {
            let r: BarcodeScanResult
            switch input {
            case .path(let p):
                r = try BarcodeEngine.detect(
                    path: p, symbologies: req.symbologies ?? [],
                    minConfidence: req.minConfidence ?? 0.0,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try BarcodeEngine.detect(
                    data: d, symbologies: req.symbologies ?? [],
                    minConfidence: req.minConfidence ?? 0.0,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            }
            // No barcode found is a valid outcome (not an error) — same semantics as `ocr`
            // (whole-image scan), not `find` (single-target lookup): code_count: 0, exit 0.
            let codes = r.codes.map { code -> YAMLValue in
                .dict([
                    ("payload", code.payload.map(YAMLValue.string) ?? .null),
                    ("symbology", .string(code.symbologyName)),
                    ("x", .int(code.rect.centerX)), ("y", .int(code.rect.centerY)),
                    ("left", .int(code.rect.x)), ("top", .int(code.rect.y)),
                    ("width", .int(code.rect.width)), ("height", .int(code.rect.height)),
                    ("confidence", .double(code.confidence)),
                ])
            }
            return ServiceResult(.dict([
                ("image_width", .int(r.imageWidth)), ("image_height", .int(r.imageHeight)),
                ("code_count", .int(r.codes.count)),
                ("codes", .array(codes)),
            ]))
        } catch let e as VisionError {
            throw imageError(e, label: input.label)
        }
    }

    // MARK: - doctor

    static func doctor() -> YAMLValue {
        // Real probes, not hardcoded constants — and per request family, since text and
        // face recognition have independent availability.
        func status(_ ok: Bool) -> YAMLValue { .string(ok ? "available" : "unavailable") }
        let text = status(OCREngine.textVisionAvailable())
        let face = status(OCREngine.faceVisionAvailable())
        let barcodeStatus = status(BarcodeEngine.barcodeVisionAvailable())
        let askStatus: YAMLValue
        #if MACVIS_ASK_IMAGE
        switch probeAskAvailability() {
        case .available: askStatus = .string("available")
        case .ineligible(let r), .osTooOld(let r), .notReady(let r): askStatus = .string("unavailable: \(r)")
        }
        #else
        // Built without the multimodal image path: ask can't run regardless of OS — match the
        // real call (needs_macos_27_sdk) and the MCP tool list (which hides ask on this build).
        askStatus = .string("unavailable: needs_macos_27_sdk")
        #endif
        let langs = OCREngine.systemDefaultLanguages().map { YAMLValue.string($0) }
        // Readiness, not capability — empty unless the model is available *now*; when it is,
        // this is what it can currently handle across the languages it supports.
        let askLangs = readyAskLanguages().map { YAMLValue.string($0) }
        return .dict([
            ("ocr", text), ("find", text), ("sort-faces", face),
            ("barcode", barcodeStatus),
            ("ask", askStatus), ("ocr_languages", .array(langs)),
            ("ask_languages", .array(askLangs)),
        ])
    }

    // MARK: - ask

    static func ask(_ req: VisionRequest) async throws -> ServiceResult {
        let path = try requirePath(req)
        guard let prompt = req.prompt, !prompt.isEmpty else {
            throw ServiceError(name: "bad_request", reason: "missing_prompt",
                               hint: "ask requires a natural-language prompt", exitCode: ExitCode.usage.rawValue)
        }
        do {
            let outcome = try await AFMEngine().ask(imagePath: path, prompt: prompt,
                                                    stream: req.stream ?? false,
                                                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            return ServiceResult(.dict([
                ("answer", .string(outcome.text)),
                ("compute", .string(outcome.compute.rawValue)),  // always on-device (PCC not used — see AFMEngine.ask)
            ]))
        } catch let e as SemanticError {
            throw semanticToService(e)
        }
    }

    // MARK: - helpers

    private static func requirePath(_ req: VisionRequest) throws -> String {
        guard let p = req.path, !p.isEmpty else {
            throw ServiceError(name: "bad_request", reason: "missing_path",
                               hint: "provide an image or PDF path", exitCode: ExitCode.usage.rawValue)
        }
        return p
    }

    private static func boxFields(_ rect: NormalizedRect, _ w: Int, _ h: Int) -> [(String, YAMLValue)] {
        let px = Geometry.toPixelRect(rect, imageWidth: w, imageHeight: h)
        // x,y = center (click point); left/top/width/height = bounding box.
        return [("x", .int(px.centerX)), ("y", .int(px.centerY)),
                ("left", .int(px.x)), ("top", .int(px.y)),
                ("width", .int(px.width)), ("height", .int(px.height))]
    }

    private static func imageError(_ e: VisionError, label: String) -> ServiceError {
        switch e {
        case .imageLoadFailed:
            return ServiceError(name: "image_load_failed", reason: "unreadable_or_unsupported", detail: label,
                                hint: "check the path or base64 data; supported: png/jpg/heic/tiff/... or PDF (set page).",
                                exitCode: ExitCode.runtimeError.rawValue)
        case .noFace:
            return ServiceError(name: "no_face", reason: "no_face_detected", detail: label,
                                hint: "provide an image containing a clearly visible face", exitCode: ExitCode.runtimeError.rawValue)
        }
    }

    private static func semanticToService(_ e: SemanticError) -> ServiceError {
        switch e {
        case .ineligible(let reason, let detail, let hint):
            return ServiceError(name: "ask_unavailable", reason: reason, detail: detail, hint: hint,
                                exitCode: ExitCode.askIneligible.rawValue)
        case .temporarilyUnavailable(let reason, let detail, let hint):
            return ServiceError(name: "ask_unavailable", reason: reason, detail: detail, hint: hint,
                                exitCode: ExitCode.askTemporarilyUnavailable.rawValue)
        case .failed(let reason, let detail, let hint):
            return ServiceError(name: "ask_failed", reason: reason, detail: detail, hint: hint,
                                exitCode: ExitCode.runtimeError.rawValue)
        }
    }
}
