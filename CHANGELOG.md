# Changelog

## Unreleased

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
