# Changelog

## v0.3.0

`macvis` grows from OCR/find into a full on-device vision toolkit — still one Pure-Swift binary, zero deps, every command on the CLI **and** as an MCP tool.

**New commands:**
- **`barcode`** — scan QR + every 1D/2D symbology Vision supports; `--symbology` to narrow. No code found → `code_count: 0`, exit 0.
- **`qr`** — `barcode` narrowed to QR only (server-enforced).
- **`make-qr <text>`** — generate a scannable QR PNG via CoreImage (no Vision); round-trip verified.
- **`classify`** — tag an image/PDF against Vision's 1,303-label taxonomy (`--min-confidence`/`--top` applied by the engine).
- **`document-ocr`** — structured document OCR: title / paragraphs / tables / lists with layout, alongside plain-text `ocr`.
- **`document-bounds`** / **`rectify-document`** — detect a document's four corners and flatten it into a straight top-down scan.
- **`ask --schema <path|json>`** *(Beta, macOS 27)* — force a structured JSON answer via Foundation Models guided generation. JSON Schema MVP subset (object / string(+enum) / integer / number / boolean / array / required); unsupported keywords are rejected (`bad_request`), never silently ignored. Schema mapping is pure logic — a malformed schema is rejected before any model call, and the existing `probeAskAvailability()` crash-gate is unchanged. On the CLI and the MCP `ask` tool's `schema` argument.

**Fixed:** a concurrency deadlock in `ocr` / `find` / `sort-faces` / `find-person` (and preventively `barcode` / `qr` / `document-bounds` / `rectify-document`) under concurrent load — e.g. `macvis serve` fielding overlapping MCP requests. `VNImageRequestHandler.perform()` blocks its thread internally, so concurrent tasks could exhaust Swift's cooperative pool and hang; Vision engines now route through a serial queue that suspends the caller instead.

**Build:** release binaries are now `-Osize` (~15% smaller, no measurable latency change). The `ask` binary must be built with the Xcode 27 beta whose FoundationModels SDK matches the target macOS 27 runtime — FoundationModels is still beta, so a mismatch can crash at runtime; `scripts/release-ask.sh` warns on a detected mismatch. See [CONTRIBUTING → Releasing](CONTRIBUTING.md#releasing).

`ask` needs macOS 27 (Beta) + Apple Intelligence; everything else runs on macOS 26+.

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
