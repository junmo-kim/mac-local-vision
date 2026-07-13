import Foundation
import VisionCore
import SemanticEngine
import FoundationModels  // GenerationSchema — see SemanticEngine.swift's import comment

/// The single engine seam. CLI commands and the MCP server both go through here, so
/// output is identical across interfaces.
enum VisionService {
    static func handle(_ req: VisionRequest) async throws -> ServiceResult {
        switch req.op {
        case "ocr":    return try await ocr(req)
        case "find":   return try await find(req)
        case "doctor": return ServiceResult(await doctor())
        case "ask":    return try await ask(req)
        case "ping":   return ServiceResult(.dict([("ok", .bool(true))]))
        case "barcode": return try await barcode(req)
        case "qr": return try await qr(req)
        case "make-qr": return try generateQR(req)
        case "document-bounds": return try await documentBounds(req)
        case "rectify-document": return try await rectifyDocument(req)
        case "document-ocr": return try await documentOCR(req)
        case "classify": return try await classify(req)
        default:
            throw ServiceError(name: "bad_request", reason: "unknown_op", detail: req.op,
                               hint: "ops: ocr | find | doctor | ask | barcode | qr | make-qr | document-bounds | rectify-document | document-ocr | classify",
                               exitCode: ExitCode.usage.rawValue)
        }
    }

    // MARK: - Input resolution (pure logic lives in VisionCore.InputSource.resolve)

    // MARK: - ocr

    static func ocr(_ req: VisionRequest) async throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        let withWords = req.words ?? false
        let withBoxes = (req.boxes ?? false) || withWords  // --words implies line boxes
        do {
            let r: OCRResult
            switch input {
            case .path(let p):
                r = try await OCREngine.recognize(
                    path: p, fast: req.fast ?? false, minConfidence: req.minConfidence ?? 0.0,
                    languages: req.languages ?? [], includeWords: withWords,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try await OCREngine.recognize(
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

    static func find(_ req: VisionRequest) async throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        guard let target = req.target, !target.isEmpty else {
            throw ServiceError(name: "bad_request", reason: "missing_target",
                               hint: "find requires the target text to locate", exitCode: ExitCode.usage.rawValue)
        }
        do {
            let hit: FindResult?
            switch input {
            case .path(let p):
                hit = try await OCREngine.find(
                    path: p, target: target, minConfidence: req.minConfidence ?? 0.3,
                    languages: req.languages ?? [], page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                hit = try await OCREngine.find(
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

    static func barcode(_ req: VisionRequest) async throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        do {
            let r: BarcodeScanResult
            switch input {
            case .path(let p):
                r = try await BarcodeEngine.detect(
                    path: p, symbologies: req.symbologies ?? [],
                    minConfidence: req.minConfidence ?? 0.0,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try await BarcodeEngine.detect(
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

    // MARK: - qr

    /// `barcode`'s QR-only counterpart. The `qr` CLI/MCP surface has no --symbology flag,
    /// so a caller has no way to ask for anything but QR — this forces `symbologies` to
    /// `["qr"]` here, server-side, rather than trusting a client-supplied value, and reuses
    /// `barcode(_:)` wholesale so there's exactly one scan code path (Micro QR is a distinct
    /// Vision symbology and is intentionally excluded — use `barcode --symbology microQR`
    /// for that).
    static func qr(_ req: VisionRequest) async throws -> ServiceResult {
        var forced = req
        forced.symbologies = ["qr"]
        return try await barcode(forced)
    }

    // MARK: - make-qr

    /// Unlike every other op, this one *produces* an image rather than consuming one —
    /// `req.text` is the payload to encode, and the result is either written to disk
    /// (`outPath` given) or returned in-band as base64 (`image_data`, for remote/MCP
    /// callers that can't write to this machine's filesystem — plan §2.4.5).
    static func generateQR(_ req: VisionRequest) throws -> ServiceResult {
        let correctionLevel = req.correctionLevel ?? "M"
        // QRGenerator.generate validates text/correctionLevel itself and throws the same
        // bad_request/{missing_text,invalid_correction_level} ServiceError shape — no need
        // to duplicate that check here (same pattern as BarcodeEngine.resolveSymbologies's
        // unknown_symbology, which VisionService.barcode() also lets propagate untouched).
        let result = try QRGenerator.generate(text: req.text ?? "", correctionLevel: correctionLevel, size: req.size)
        var fields: [(String, YAMLValue)]
        if let outPath = req.outPath, !outPath.isEmpty {
            // Intentional curl-o-style overwrite (no collision guard): outPath is a single
            // user-specified destination file, not a curated directory tree of generated
            // artifacts like FaceEngine.writeClusters's symlink farm (which guards against
            // deleting a bystander file it doesn't own) — re-running the same --out is the
            // expected "regenerate this file" workflow.
            try QRGenerator.writePNG(result.png, to: outPath)
            fields = [("path", .string(outPath))]
        } else {
            fields = [("image_data", .string(result.png.base64EncodedString()))]
        }
        // width/height (not image_width/image_height, unlike ocr/barcode) is unambiguous
        // here: make-qr's output has no bounding-box concept at all, so there's no
        // sibling "box vs whole image" pair to disambiguate within this op's own response.
        fields.append(contentsOf: [
            ("width", .int(result.width)), ("height", .int(result.height)),
            ("correction_level", .string(correctionLevel)),
        ])
        return ServiceResult(.dict(fields))
    }

    // MARK: - document-bounds

    /// `barcode`'s detection-only shape, applied to documents: `found: false` (not an error,
    /// exit 0) when no document quad clears `minConfidence` — see `Geometry.pickLargestQuad`
    /// for why an exact-zero-confidence Vision candidate never counts as found.
    static func documentBounds(_ req: VisionRequest) async throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        do {
            let r: DocumentBoundsResult
            switch input {
            case .path(let p):
                r = try await DocumentEngine.detectBounds(
                    path: p, minConfidence: req.minConfidence ?? DocumentEngine.defaultMinConfidence,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try await DocumentEngine.detectBounds(
                    data: d, minConfidence: req.minConfidence ?? DocumentEngine.defaultMinConfidence,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            }
            guard let corners = r.corners, let confidence = r.confidence else {
                return ServiceResult(.dict([
                    ("image_width", .int(r.imageWidth)), ("image_height", .int(r.imageHeight)),
                    ("found", .bool(false)),
                ]))
            }
            func point(_ c: DocumentCorner) -> YAMLValue { .dict([("x", .int(c.x)), ("y", .int(c.y))]) }
            return ServiceResult(.dict([
                ("image_width", .int(r.imageWidth)), ("image_height", .int(r.imageHeight)),
                ("found", .bool(true)),
                ("corners", .dict([
                    ("top_left", point(corners.topLeft)), ("top_right", point(corners.topRight)),
                    ("bottom_right", point(corners.bottomRight)), ("bottom_left", point(corners.bottomLeft)),
                ])),
                ("confidence", .double(confidence)),
            ]))
        } catch let e as VisionError {
            throw imageError(e, label: input.label)
        }
    }

    // MARK: - rectify-document

    /// Unlike `document-bounds` (detect-only), this op *produces* an image — reuses
    /// `DocumentEngine.rectify`, which internally shares `document-bounds`'s detection core
    /// (`detectQuad`) and throws `bad_request/no_document_detected` itself when nothing is
    /// found (a production command with nothing to produce is an error, matching `make-qr`'s
    /// "reject empty text" precedent — plan §2.5). `--out` / base64 branching mirrors `make-qr`.
    static func rectifyDocument(_ req: VisionRequest) async throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        do {
            let r: RectifyResult
            switch input {
            case .path(let p):
                r = try await DocumentEngine.rectify(
                    path: p, minConfidence: req.minConfidence ?? DocumentEngine.defaultMinConfidence,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try await DocumentEngine.rectify(
                    data: d, minConfidence: req.minConfidence ?? DocumentEngine.defaultMinConfidence,
                    page: req.page ?? 1, scale: req.scale ?? 2.0)
            }
            var fields: [(String, YAMLValue)]
            if let outPath = req.outPath, !outPath.isEmpty {
                try DocumentEngine.writePNG(r.png, to: outPath)
                fields = [("path", .string(outPath))]
            } else {
                fields = [("image_data", .string(r.png.base64EncodedString()))]
            }
            fields.append(contentsOf: [("width", .int(r.width)), ("height", .int(r.height))])
            return ServiceResult(.dict(fields))
        } catch let e as VisionError {
            throw imageError(e, label: input.label)
        }
    }

    // MARK: - document-ocr

    /// `RecognizeDocumentsRequest` (macOS 26.0+, Swift-native async API — see
    /// `DocumentOCREngine`'s doc comment) rather than `OCREngine`'s synchronous
    /// `VNRecognizeTextRequest`. Nested alongside `ocr`, not replacing it: `ocr` stays the
    /// lightweight plain-text path, this is the structured (title/paragraphs/tables/lists)
    /// path (plan §2.4).
    static func documentOCR(_ req: VisionRequest) async throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        do {
            let r: DocumentOCRResult
            switch input {
            case .path(let p):
                r = try await DocumentOCREngine.recognize(path: p, page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try await DocumentOCREngine.recognize(data: d, page: req.page ?? 1, scale: req.scale ?? 2.0)
            }
            let w = r.imageWidth, h = r.imageHeight
            let paragraphs = r.paragraphs.map { p -> YAMLValue in
                .dict([("text", .string(p.text))] + boxFields(p.rect, w, h))
            }
            let tables = r.tables.map { t -> YAMLValue in
                let cells = t.cells.map { cell -> YAMLValue in
                    .dict([("row", .int(cell.row)), ("col", .int(cell.col)), ("text", .string(cell.text))])
                }
                return .dict([("rows", .int(t.rows)), ("columns", .int(t.columns))]
                    + boxFields(t.rect, w, h)
                    + [("cells", .array(cells))])
            }
            let lists = r.lists.map { l -> YAMLValue in
                let items = l.items.map { item -> YAMLValue in
                    .dict([("marker", .string(item.marker)), ("text", .string(item.text))])
                }
                return .dict([("item_count", .int(l.items.count))]
                    + boxFields(l.rect, w, h)
                    + [("items", .array(items))])
            }
            return ServiceResult(.dict([
                ("image_width", .int(w)), ("image_height", .int(h)),
                ("title", r.title.map(YAMLValue.string) ?? .null),
                ("text", .string(r.text)),
                ("paragraph_count", .int(r.paragraphs.count)),
                ("paragraphs", .array(paragraphs)),
                ("table_count", .int(r.tables.count)),
                ("tables", .array(tables)),
                ("list_count", .int(r.lists.count)),
                ("lists", .array(lists)),
            ]))
        } catch let e as VisionError {
            throw imageError(e, label: input.label)
        }
    }

    // MARK: - classify

    /// Unlike `barcode`/`ocr`, Vision returns all 1,303 taxonomy identifiers for every
    /// image (not just detections — plan §2.6 Phase 0 spike), so `ClassifyEngine` applies
    /// `minConfidence`/`top` itself; this handler just passes them through and shapes the
    /// response. `label_count: 0` (all below threshold) is a valid outcome, same as
    /// `code_count: 0` for `barcode` — not an error.
    static func classify(_ req: VisionRequest) async throws -> ServiceResult {
        let input = try InputSource.resolve(path: req.path, data: req.data)
        do {
            let r: ClassificationScanResult
            switch input {
            case .path(let p):
                r = try await ClassifyEngine.classify(
                    path: p, minConfidence: req.minConfidence ?? ClassifyEngine.defaultMinConfidence,
                    top: req.top, page: req.page ?? 1, scale: req.scale ?? 2.0)
            case .data(let d):
                r = try await ClassifyEngine.classify(
                    data: d, minConfidence: req.minConfidence ?? ClassifyEngine.defaultMinConfidence,
                    top: req.top, page: req.page ?? 1, scale: req.scale ?? 2.0)
            }
            let labels = r.labels.map { label -> YAMLValue in
                .dict([
                    ("identifier", .string(label.identifier)),
                    ("confidence", .double(label.confidence)),
                ])
            }
            return ServiceResult(.dict([
                ("image_width", .int(r.imageWidth)), ("image_height", .int(r.imageHeight)),
                ("label_count", .int(r.labels.count)),
                ("labels", .array(labels)),
            ]))
        } catch let e as VisionError {
            throw imageError(e, label: input.label)
        }
    }

    // MARK: - doctor

    static func doctor() async -> YAMLValue {
        // Real probes, not hardcoded constants — and per request family, since text and
        // face recognition have independent availability.
        func status(_ ok: Bool) -> YAMLValue { .string(ok ? "available" : "unavailable") }
        let text = status(await OCREngine.textVisionAvailable())
        let face = status(await OCREngine.faceVisionAvailable())
        let barcodeStatus = status(await BarcodeEngine.barcodeVisionAvailable())
        // Represents both document-bounds and rectify-document (rectify's other half,
        // CIPerspectiveCorrection, is a plain CoreImage filter with no availability gate —
        // plan §2.3 — so this single Vision probe is representative of both, same precedent
        // as `qr` not getting its own doctor entry alongside `barcode`).
        let documentStatus = status(await DocumentEngine.documentVisionAvailable())
        let documentOCRStatus = status(await DocumentOCREngine.documentOCRAvailable())
        let classifyStatus = status(await ClassifyEngine.classifyVisionAvailable())
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
            ("barcode", barcodeStatus), ("classify", classifyStatus),
            ("document_bounds", documentStatus),
            ("document_ocr", documentOCRStatus),
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
        // Schema mapping is pure logic — fully independent of AFMEngine/probeAskAvailability
        // (see JSONSchemaMapper's doc comment) — so a malformed --schema is rejected here,
        // before AFMEngine.ask is ever called, same as the missing-prompt check above.
        let schema: GenerationSchema?
        if let schemaText = req.schema, !schemaText.isEmpty {
            schema = try JSONSchemaMapper.map(schemaText)
        } else {
            schema = nil
        }
        do {
            let outcome = try await AFMEngine().ask(imagePath: path, prompt: prompt,
                                                    stream: req.stream ?? false,
                                                    page: req.page ?? 1, scale: req.scale ?? 2.0,
                                                    schema: schema)
            let answer: YAMLValue
            if schema != nil {
                // Guided Generation: outcome.text is GeneratedContent.jsonString — decode it
                // into structured data instead of wrapping it as one opaque string.
                do {
                    answer = try YAMLValue.parseJSON(outcome.text)
                } catch {
                    throw ServiceError(name: "ask_failed", reason: "invalid_model_json_output",
                                       detail: "the model's schema-constrained answer wasn't valid JSON: \(error)",
                                       hint: "retry — if this repeats, the schema may be too complex for the model to honor reliably.",
                                       exitCode: ExitCode.runtimeError.rawValue)
                }
            } else {
                answer = .string(outcome.text)
            }
            return ServiceResult(.dict([
                ("answer", answer),
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
