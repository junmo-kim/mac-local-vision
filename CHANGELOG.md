# Changelog

## Unreleased

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
