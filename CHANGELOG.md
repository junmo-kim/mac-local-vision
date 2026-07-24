# Changelog

## v0.3.1

Fixes `macvis serve` refusing new connections after a leftover 32-connection cap. Also
corrects the README's Gatekeeper guidance — a quarantined ad-hoc binary run from Terminal
is killed outright, not gated by a System Settings prompt; clear it with
`xattr -d com.apple.quarantine` (Homebrew / mise / `curl` unaffected).

## v0.3.0

`macvis` grows from OCR/find into a full on-device vision toolkit — one Pure-Swift binary, zero dependencies, every command on the CLI **and** as an MCP tool.

**New commands**
- **`barcode`** / **`qr`** — scan QR and every 1D/2D symbology Vision supports.
- **`make-qr`** — generate a scannable QR PNG (CoreImage, no Vision needed).
- **`classify`** — tag an image or PDF against Vision's 1,303-label taxonomy.
- **`document-ocr`** — structured document OCR (title, paragraphs, tables, lists), alongside plain-text `ocr`.
- **`document-bounds`** / **`rectify-document`** — find a document's corners and flatten it into a straight top-down scan.
- **`ask --schema`** *(Beta, macOS 27)* — force a structured-JSON answer from Apple Foundation Models via a JSON Schema, instead of free text.

**Fixed** — a concurrency deadlock that could hang `ocr` / `find` / `sort-faces` and the other Vision commands under concurrent load (e.g. `macvis serve` fielding overlapping requests).

Release binaries are now built `-Osize`. `ask` needs macOS 27 (Beta) + Apple Intelligence; everything else runs on macOS 26+ — see [CONTRIBUTING](CONTRIBUTING.md#releasing) for building the `ask` binary.

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
