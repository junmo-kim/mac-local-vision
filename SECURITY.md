# Security Policy

## Threat model

macvis runs **entirely on-device**: no telemetry, no analytics, no cloud calls. No networking
APIs are linked or used in the current code, and CI fails if any appear (see
`.github/workflows/ci.yml`). It exposes only on-device vision commands and a stdio MCP server
(`macvis mcp`) — no listening socket is ever opened. It reads the image/PDF paths you pass it
and, for face clustering, writes **only symlinks** — never overwriting a file that isn't already
a symlink. Image and PDF decoding is delegated to Apple's ImageIO / Vision / CoreGraphics
frameworks rather than a custom parser.

The realistic attack surface is therefore a **malicious image or PDF** handed to
`ocr` / `find` / `sort-faces`: a decoder bug in the OS frameworks, or resource exhaustion via
crafted dimensions (image and PDF rasterization sizes are bounded — see
`OCREngine.maxRasterPixels` / `clampedRasterSize`).

## Reporting a vulnerability

Please report security issues **privately** via GitHub's *Security → Report a vulnerability*
(private advisory), not a public issue. Include reproduction steps and the input that triggers
the problem. We'll acknowledge and aim to respond promptly.
