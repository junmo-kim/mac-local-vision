# Changelog

## Unreleased

Adds `macvis ask --schema <path|json>` — forces a structured JSON answer via Apple's Guided
Generation (`session.respond(to:schema:)`/`DynamicGenerationSchema`), instead of `ask`'s usual
free text. Give it a JSON Schema (a file path, or inline JSON) describing the fields you want
(e.g. `{merchant, total, date}` extracted from a receipt) and `answer` comes back as structured
data rather than one string. Supports an MVP subset — `object` / `string` (+ `enum`) / `integer`
/ `number` / `boolean` / `array` (single-item schema) / `required` — deliberately not `$ref` /
`oneOf` / `allOf` / `not` / `pattern` / `$defs`, which are rejected as `bad_request`/`unsupported_schema_feature`
rather than silently ignored. The JSON-Schema-to-`GenerationSchema` mapping
(`JSONSchemaMapper`) is pure logic with zero model dependency — a malformed schema is rejected
(`bad_request`/`invalid_schema`, exit `64`) before `AFMEngine.ask` is ever called, and the
existing `probeAskAvailability()` pre-flight gate (the fix for the real SIGSEGV crash on
macOS 27 Beta when the model isn't ready) runs in the exact same position regardless of whether
a schema was requested — this feature adds no new path that could reach the model unguarded.
Exposed on the CLI (`--schema`) and as the MCP `ask` tool's `schema` argument (a native JSON
object, no string-escaping needed).

Fixes a deadlock in `ocr`/`find`/`sort-faces`/`find-person` (and preventively
`barcode`/`qr`/`document-bounds`/`rectify-document`) when handled concurrently — e.g. via
`macvis serve` fielding overlapping MCP requests. `VNImageRequestHandler.perform()` blocks
its calling thread while dispatching internally; concurrent `Task`s calling it directly can
exhaust Swift concurrency's small, fixed-size cooperative thread pool and hang the process
(reproduced directly: 15 concurrent OCR/face-detection calls hung indefinitely, killed
externally after several minutes at ~0% CPU). Every Vision-bound engine now routes its
`.perform()` calls through a dedicated serial queue that suspends the caller rather than
blocking it, the same fix `classify` already carried.

Adds `macvis classify` — tags an image or PDF against Vision's 1,303-label taxonomy
(`VNClassifyImageRequestRevision2`), exposed on the CLI and as an MCP tool. Unlike
`barcode`/`ocr`, Vision scores all 1,303 labels for every image rather than returning only
detections, so the engine applies `--min-confidence` (default `0.1`) and `--top` (default
`20`, clamped to a minimum of `1`) itself before returning anything — otherwise every call
would be a 1,303-line response. `label_count: 0` (all below threshold) is a valid outcome,
not an error, matching `barcode`'s `code_count: 0` semantics. Adds a `classify` field to
`doctor`.

Adds `macvis document-ocr <image|pdf>` — structured document OCR via `RecognizeDocumentsRequest`,
extracting a title, full text, paragraphs, tables (row/column grid with per-cell text), and lists
(marker + item text), each with a pixel bounding box. Nested alongside `ocr`, not replacing it:
`ocr` stays the lightweight flat-line-of-text path, `document-ocr` is for when the document's
layout (which cells belong to which row, which lines form one list) matters. Tables/lists nested
inside a cell or list item are flattened to their text only (no recursion). `--page N --scale S`
rasterize PDF pages, matching `ocr`/`barcode`. Adds a `document_ocr` field to `doctor` and exposes
`document-ocr` as an MCP tool alongside `ocr`/`find`/`barcode`/`qr`/`make-qr`/`doctor`.

Adds `macvis barcode` — scans QR codes and every 1D/2D barcode symbology Vision supports
(Code128, EAN, PDF417, DataMatrix, Aztec, and more) in a single command, exposed on the CLI
and as an MCP tool. No barcode found is a valid outcome (`code_count: 0`, exit `0`), matching
`ocr`'s whole-image-scan semantics rather than `find`'s single-target lookup. Restrict to
specific symbologies with `--symbology qr,code128,...`. Adds a `barcode` field to `doctor`.

Adds `macvis qr` — `barcode` narrowed to QR codes only, enforced server-side (no
`--symbology` flag exists to override it). Same output shape as `barcode`; reuses its scan
path with `symbologies` forced to `["qr"]`. Exposed as an MCP tool with a smaller schema
than `barcode`'s (no `symbologies` property).

Adds `macvis make-qr <text>` — the write counterpart to `barcode`/`qr`, encoding text into a
scannable QR code PNG via CoreImage (`CIQRCodeGenerator`), not Vision, so it works regardless
of Vision/Apple Intelligence availability. `--out <path>` writes a file and reports its path
plus dimensions; omitting it returns the PNG as base64 in `image_data` for remote/MCP callers
without local filesystem access. `--correction-level L|M|Q|H` (default `M`) and `--size N`
(per-module pixel magnification, default `10`) are configurable, with a shared raster-pixel
cap protecting against unbounded `--size`/payload combinations. Exposed as an MCP tool
alongside `ocr`/`find`/`barcode`/`qr`/`doctor`. Verified round-trip: every generated code is
re-scanned through `macvis barcode`'s own `BarcodeEngine.detect` and checked for exact
payload equality.

Adds `macvis document-bounds` — finds a document's four corners in a photo via
`VNDetectDocumentSegmentationRequest`, mirroring `barcode`'s detect-only shape and
`ocr`/`barcode`'s not-found-is-not-an-error semantics (`found: false`, exit `0`). When
multiple document-like regions are present, reports the largest by area. Adds
`macvis rectify-document <image> --out <path>` — the write counterpart, reusing
`document-bounds`'s detection internally and applying CoreImage's `CIPerspectiveCorrection`
to flatten and crop the document into a straightened, top-down scan; `--out`/base64 branching
mirrors `make-qr`. No document detected is a `bad_request`/`no_document_detected` error (this
is a production command, unlike `document-bounds`). Both exposed as MCP tools; adds a
`document_bounds` field to `doctor`. Verified round-trip: a perspective-warped synthetic
document is rectified and the flattened text is re-read correctly through `macvis ocr`.

## v0.2.1

Fixes a real process crash in `ask` when Apple Intelligence isn't ready yet (SIGSEGV
inside FoundationModels on macOS 27 Beta, not a catchable error) and reclassifies a
transient content-safety-model error as retryable instead of a hard failure. Adds
`ask_languages` to `doctor`, reporting which languages `ask` can answer in right now.

## v0.2.0

Adds `macvis serve` — an HTTP MCP transport for remote MCP clients — plus base64
image input for `ocr`/`find`, so calls no longer need a file on disk.

## v0.1.0

First release. A fully on-device Vision CLI for macOS: OCR, image search (`find`),
face grouping, and natural-language `ask` (Beta) — exposed as both a CLI and an
MCP server, with zero cloud calls.
