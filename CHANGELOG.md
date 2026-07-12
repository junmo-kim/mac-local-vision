# Changelog

## Unreleased

Adds `macvis barcode` — scans QR codes and every 1D/2D barcode symbology Vision supports
(Code128, EAN, PDF417, DataMatrix, Aztec, and more) in a single command, exposed on the CLI
and as an MCP tool. No barcode found is a valid outcome (`code_count: 0`, exit `0`), matching
`ocr`'s whole-image-scan semantics rather than `find`'s single-target lookup. Restrict to
specific symbologies with `--symbology qr,code128,...`. Adds a `barcode` field to `doctor`.

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
