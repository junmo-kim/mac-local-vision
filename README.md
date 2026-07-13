# mac-local-vision (`macvis`)

[![CI](https://github.com/junmo-kim/mac-local-vision/actions/workflows/ci.yml/badge.svg)](https://github.com/junmo-kim/mac-local-vision/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 26+ · Apple Silicon](https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20Apple%20Silicon-lightgrey)

Zero-token, on-device vision for AI agents and E2E tests — built as a **100% Pure
Swift single binary** on Apple's native `Vision` and `FoundationModels` frameworks.
No Node, no Python, no runtime dependencies: the OS *is* the dependency.

- **Zero-Token OCR** — extract text/layout locally, never spending cloud vision tokens.
- **Fast E2E targeting** — `find` returns the exact pixel center of a word for click/assert.
- **QR/barcode scanning** — `barcode` decodes every symbology Vision supports (QR, Code128, EAN, PDF417, ...) in one call.
- **QR generation** — `make-qr` writes a scannable QR code PNG (CoreImage, no Vision needed).
- **Document rectification** — `rectify-document` finds a photographed document's boundary and flattens it into a straightened, top-down scan; `document-bounds` returns just the four corners.
- **Structured document OCR** — `document-ocr` extracts title/paragraphs/tables/lists with layout preserved, not just flat lines of text.
- **Image classification** — `classify` tags an image against a 1,303-label taxonomy (outdoor, document, people, ...).
- **On-device semantic `ask`** *(Beta)* — multimodal reasoning via Apple Foundation Models (macOS 27 Beta).
- **Local face sorting** — cluster photos by person without uploading anything.

## Tiny & fast

A **~240 KB stripped single binary** (the frameworks are the OS, nothing is bundled — no
Node, no Python, no `node_modules`), and every call is a fresh **~0.3 s end-to-end** —
process launch *plus* recognition, no daemon to keep warm:

| command | latency |
| --- | --- |
| `find` (locate a word) | **0.30 s** |
| `ocr` (full page) | **0.29 s** |
| `doctor` | **0.13 s** |

<sub>Best of 5, on a 1080×2400 screenshot (19 lines, Korean + English), Apple M4.</sub>

Versus shipping that screenshot to a cloud vision API: no network round-trip, no vision
tokens, no per-call cost, and nothing leaves the machine.

`ask` (multimodal LLM inference, needs macOS 27 (Beta) + Apple Intelligence) is a
different kind of fast — still no cloud round-trip, but the cost is real generation
time, not process launch:

| prompt | latency |
| --- | --- |
| short prompt, simple image | **0.8 s** |
| longer prompt, simple image | **3.0 s** |
| complex real-world screenshot, detailed prompt | **6.8 s** |

<sub>Small sample, MacMini-M4, macOS 27 Beta.</sub>

## Requirements

Apple Silicon Mac, macOS 26+. No other dependencies — `Vision` and `FoundationModels`
ship with the OS. Building the `ask` (multimodal) path additionally needs the macOS 27 SDK
(Xcode 27); everything else builds and runs on macOS 26.

## Install

Apple Silicon, macOS 26+.

**Homebrew**

```bash
brew install junmo-kim/tap/macvis
```

**mise**

```bash
mise use -g github:junmo-kim/mac-local-vision      # add @0.1.0 to pin a version
```

Both fetch the same prebuilt binary — it's ask-enabled, so the Vision commands run on macOS 26+
and `ask` lights up on macOS 27. Then run `macvis doctor` to see what's available here.

<details><summary><b>Direct download / build from source</b></summary>

**Direct download** — grab `macvis-<version>-macos-arm64.tar.gz` from
[Releases](https://github.com/junmo-kim/mac-local-vision/releases), then:

```bash
shasum -a 256 -c macvis-*-macos-arm64.tar.gz.sha256   # verify the download
tar xzf macvis-*-macos-arm64.tar.gz
sudo mv macvis /usr/local/bin/                        # or ~/.local/bin on your $PATH
```

The binary is ad-hoc signed (not notarized), so a directly-downloaded copy may trip Gatekeeper —
approve it under System Settings → Privacy & Security. (Homebrew / mise installs avoid this.)

**From source** (Swift 6.2+ toolchain / Xcode 26):

```bash
swift build -c release && cp .build/release/macvis /usr/local/bin/
```

</details>

## Status

| Command | State | Requires |
| --- | --- | --- |
| `ocr` / `find` | ✅ working | Apple Silicon · macOS 26 |
| `barcode` | ✅ working — QR + every Vision-supported 1D/2D symbology in one command | Apple Silicon · macOS 26 |
| `qr` | ✅ working — `barcode` restricted to QR only, server-side (no `--symbology` flag) | Apple Silicon · macOS 26 |
| `classify` | ✅ working — 1,303-label taxonomy; Vision scores every label, so `--min-confidence`/`--top` are applied by the engine, not just a pass-through filter (see note) | Apple Silicon · macOS 26 |
| `make-qr` | ✅ working — CoreImage, no Vision needed; round-trips through `barcode`/`qr` | any Mac · macOS 26 |
| `document-bounds` | ✅ working — finds a document's 4 corners (`VNDetectDocumentSegmentationRequest`) | Apple Silicon · macOS 26 |
| `rectify-document` | ✅ working — detects + perspective-corrects a photographed document into a flattened scan; round-trips through `ocr` | Apple Silicon · macOS 26 |
| `document-ocr` | ✅ working — structured OCR (title/paragraphs/tables/lists), nested alongside plain-text `ocr` | Apple Silicon · macOS 26 |
| `classify` | ✅ working — tags an image against Vision's 1,303-label taxonomy | Apple Silicon · macOS 26 |
| `doctor` | ✅ working | macOS 26 |
| `sort-faces` / `find-person` | ✅ working — same-session grouping; cross-time identity is approximate (see note) | Apple Silicon · macOS 26 |
| `mcp` | ✅ working — stdio JSON-RPC, exposes ocr/find/barcode/qr/classify/make-qr/document-bounds/rectify-document/document-ocr/doctor as tools (+ask on macOS 27 builds) | macOS 26 |
| `serve` | ✅ working — HTTP JSON-RPC MCP server for remote/non-Mac nodes | macOS 26 |
| `ask` | 🟢 Beta — targets a pre-release Apple stack; real end-to-end inference verified on a macOS 27 Beta boot (see note) | macOS 27 (Beta) + Apple Intelligence |

> **`sort-faces` accuracy**: faces are grouped by an image feature print over the face
> crop (Apple exposes no public face-embedding API). This reliably groups near-duplicate
> / same-session faces, but is a weak identity signal across large pose/lighting/age
> changes — tune `--threshold` (distances are in the output). Not a person-recognition DB.

> **`classify` result shape**: unlike `barcode`/`ocr`, Vision doesn't return "only what it
> detected" here — `VNClassifyImageRequest` scores all 1,303 taxonomy labels for every
> image, most near-zero. `classify` applies `--min-confidence` (default `0.1`) and `--top`
> (default `20`, min `1`) itself before returning anything, or every call would be a
> 1,303-line response. Real photos produce a handful of much higher-confidence labels;
> flat/synthetic (non-photographic) images tend to score everything near zero —
> `label_count: 0` is a valid outcome (not an error), same as `barcode`'s `code_count: 0`.

> **`ask` is Beta** because it rides on a pre-release Apple stack — macOS 27 (Beta) and the new
> Foundation Models *multimodal* API. The call — `session.respond { prompt; Attachment(image) }` —
> matches Apple's official [WWDC26 Foundation Models session](https://developer.apple.com/videos/play/wwdc2026/241/)
> and builds against the macOS 27 SDK. On a real macOS 27 Beta boot, both the error path
> (Apple Intelligence off → `apple_intelligence_not_enabled`, exit `71`) and real end-to-end
> inference are verified: accurate answers, full `--stream` output (not deltas), and **~1-7 s**
> latency depending on image complexity and answer length. Apple Intelligence itself is gated to
> eligible, internal-boot installs, so `ask` tracks the platform: it graduates from Beta as macOS 27
> ships. The rest of macvis (`ocr` / `find` / `sort-faces` / `mcp`) is stable on macOS 26 today.

> **`ask --schema`** forces a structured JSON answer via Apple's Guided Generation
> (`session.respond(to:schema:)`/`DynamicGenerationSchema`, available since the ordinary macOS 26
> SDK — independent of the macOS-27-only multimodal image path). Give it a JSON Schema (a file
> path, or inline JSON) and `answer` comes back as structured data instead of free text. Supports
> an MVP subset — `object` / `string` (+ `enum`) / `integer` / `number` / `boolean` / `array`
> (single-item schema) / `required` — deliberately not `$ref` / `oneOf` / `allOf` / `not` / `pattern` /
> `$defs`, which are rejected with `bad_request`/`unsupported_schema_feature` before any model
> call, rather than silently ignored. Schema mapping is pure logic, fully independent of the model
> call itself — a malformed `--schema` is rejected (`bad_request`/`invalid_schema`, exit `64`)
> without ever touching FoundationModels, so it can't be the thing that reaches `ask`'s
> crash-prone real-model-call path.

## Build & test

```bash
swift build -c release       # binary at .build/release/macvis
swift test                   # pure logic + ask plumbing + JSON Schema mapping + Vision OCR fixtures
```

> Building the `ask` path against real macOS 27 APIs needs the Xcode 27 SDK; the
> current target compiles on macOS 26 with `ask` behind `@available(macOS 27, *)`
> + runtime availability guards.

## Usage

```bash
macvis ocr ./receipt.png                                # extract text
macvis find ./screen.png --target "Submit"              # pixel center of a word
macvis find ./screen.png --target "결제하기"             # non-Latin works too (locale-aware)
macvis barcode ./ticket.png                              # scan every QR/barcode symbology
macvis qr ./ticket.png                                   # scan for QR codes only
macvis classify ./photo.jpg                              # tag against a 1,303-label taxonomy
macvis make-qr "https://example.com" --out ./qr.png     # write a scannable QR PNG
macvis document-bounds ./receipt.jpg                     # find a document's 4 corners
macvis rectify-document ./receipt.jpg --out ./flat.png  # flatten a photographed document
macvis document-ocr ./invoice.png                        # title/paragraphs/tables/lists, structured
macvis ask ./design.png --prompt "main theme color?"    # Beta — needs macOS 27 (Beta)
macvis ask ./receipt.png --prompt "extract the fields" --schema ./receipt-schema.json  # structured JSON, Guided Generation
macvis doctor                                           # which modes work here
```

`find` filters at `--min-confidence 0.3` by default (`ocr` keeps everything, default `0.0`);
lower it for blurry or headless renders.

Output is YAML by default (`--format json` for `jq`). Data goes to stdout; logs and
structured errors go to stderr. Exit codes distinguish bad args (`64`), permanent `ask`
ineligibility (`70`), and retryable failures (`71`).

### Sample output

`find` returns the exact click point (`x`,`y` = center) plus the bounding box:

```yaml
$ macvis find ./screen.png --target "Submit"
found: true
x: 456
y: 66
left: 380
top: 48
width: 152
height: 36
confidence: 1
text_found: Submit
```

`--format json` for `jq`:

```json
$ macvis find ./screen.png --target "Settings" --format json
{"found":true,"x":126,"y":69,"left":38,"top":48,"width":176,"height":42,"confidence":1,"text_found":"Settings"}
```

`barcode` scans every QR/barcode symbology in one call and returns each code's payload,
symbology, and pixel box; `code_count: 0` (not an error, exit `0`) when none are found:

```yaml
$ macvis barcode ./ticket.png
image_width: 1080
image_height: 2400
code_count: 1
codes:
  - payload: "https://example.com/ticket/abc123"
    symbology: qr
    x: 512
    y: 300
    left: 480
    top: 270
    width: 64
    height: 64
    confidence: 1
```

Restrict to specific symbologies with `--symbology qr,code128` (comma-separated); an unknown
symbology name is a structured `bad_request`/`unknown_symbology` error, exit `64`.

`qr` is `barcode` narrowed to QR only, enforced server-side — there's no `--symbology` flag
to override it. Same output shape as `barcode`, just always QR-scoped:

```yaml
$ macvis qr ./ticket.png
image_width: 1080
image_height: 2400
code_count: 1
codes:
  - payload: "https://example.com/ticket/abc123"
    symbology: qr
    x: 512
    y: 300
    left: 480
    top: 270
    width: 64
    height: 64
    confidence: 1
```

`classify` tags an image against Vision's 1,303-label taxonomy — labels are unlocalized
technical identifiers (not meant for direct UI display), sorted by confidence descending.
`label_count: 0` (not an error) when nothing clears `--min-confidence`:

```yaml
$ macvis classify ./beach-photo.jpg
image_width: 3000
image_height: 4000
label_count: 6
labels:
  - identifier: people
    confidence: 0.9566
  - identifier: outdoor
    confidence: 0.9483
  - identifier: sky
    confidence: 0.9482
  - identifier: blue_sky
    confidence: 0.9482
  - identifier: child
    confidence: 0.8843
  - identifier: adult
    confidence: 0.873
```

`--min-confidence N` (default `0.1`) drops labels below that confidence; `--top N` (default
`20`, clamped to a minimum of `1`) caps how many are returned, highest confidence first.

`make-qr` is the write counterpart to `barcode`/`qr` — it encodes text into a scannable QR PNG
via CoreImage (`CIQRCodeGenerator`), not Vision, so it works on any Mac regardless of
Vision/Apple Intelligence availability. Give `--out` to write a file and get its path back;
omit it to get the PNG as base64 in `image_data` instead (for remote/MCP callers with no local
filesystem access):

```yaml
$ macvis make-qr "https://example.com" --out ./qr.png
path: ./qr.png
width: 250
height: 250
correction_level: M
```

`--correction-level L|M|Q|H` trades code density for damage tolerance (default `M`); `--size N`
sets the per-module pixel magnification (default `10`), not the overall image side length — the
reported `width`/`height` are the image actually produced, since module count depends on payload
length and correction level. An unknown correction level is `bad_request`/`invalid_correction_level`,
exit `64`.

`document-bounds` finds a document's four corners (`VNDetectDocumentSegmentationRequest`) without
producing a new image — `found: false` (not an error, exit `0`) when nothing is detected, same
detect-only semantics as `barcode`'s `code_count: 0`. When multiple document-like regions are
present, it reports the largest by area:

```yaml
$ macvis document-bounds ./receipt.jpg
image_width: 1200
image_height: 1600
found: true
corners:
  top_left:     { x: 120, y: 180 }
  top_right:    { x: 1080, y: 210 }
  bottom_right: { x: 1050, y: 1520 }
  bottom_left:  { x: 90, y: 1490 }
confidence: 0.94
```

`rectify-document` is the write counterpart to `document-bounds` — same corner detection, then a
CoreImage `CIPerspectiveCorrection` pass flattens and crops the document into a straightened,
top-down scan. Give `--out` to write a file and get its path back; omit it for base64 in
`image_data` instead (same convention as `make-qr`). Unlike `document-bounds`, this is a
production command: no document detected is a `bad_request`/`no_document_detected` error (exit
`64`), since there's nothing to produce — feed the result to `macvis ocr` to read the flattened text:

```yaml
$ macvis rectify-document ./receipt.jpg --out ./receipt-flat.png
path: ./receipt-flat.png
width: 960
height: 1310
```

`document-ocr` extracts a document's layout — title, full text, paragraphs, tables (row/column
grid with per-cell text), and lists (marker + item text) — each with a pixel bounding box, unlike
`ocr`'s flat lines. Use `ocr` when you only need plain text; reach for `document-ocr` when the
structure (which cells belong to which row, which lines form one list) matters:

```yaml
$ macvis document-ocr ./invoice.png
image_width: 1080
image_height: 1400
title: "Invoice #1234"
text: "Invoice #1234\nBill to: Acme Corp\nItem\nPrice\n..."
paragraph_count: 2
paragraphs:
  - text: "Bill to: Acme Corp"
    x: 190
    y: 72
    left: 40
    top: 60
    width: 300
    height: 24
table_count: 1
tables:
  - rows: 3
    columns: 2
    x: 300
    y: 220
    left: 40
    top: 120
    width: 500
    height: 200
    cells:
      - row: 0
        col: 0
        text: Item
      - row: 0
        col: 1
        text: Price
      # ...
list_count: 0
lists: []
```

Nested tables/lists inside a cell or list item are flattened to text only, not walked
recursively (MVP scope). `--page N --scale S` rasterize PDF pages, same as `ocr`/`barcode`.

`doctor` reports what runs here, plus the locale-derived OCR languages and (once `ask` is
available) which languages it's ready to answer in right now:

```yaml
$ macvis doctor
ocr: available
find: available
sort-faces: available
barcode: available
classify: available
document_bounds: available
document_ocr: available
ask: "unavailable: needs_macos_27_sdk"
ocr_languages:
  - ko-KR
  - en-US
ask_languages: []
```

`ask_languages` mirrors `ask`'s own status — empty whenever `ask` itself is unavailable
(including on macOS 26, where the text-only model can be ready while image-based `ask` isn't),
and the full set of ~24 supported languages once `ask` reports `available`. Once ready, `ask`
isn't limited to the device's system language — it answers fluently in whichever of those
languages the prompt is written in. There's no flag to force a different *response* language,
though: Apple's API doesn't expose one, so `ask` follows the prompt's language rather than a
`--lang`-style override.

## Use from an LLM agent

Two equivalent integrations — both run the same `VisionService` engine, so the output is identical.

**MCP server (stdio)** — `macvis mcp` speaks stdio JSON-RPC and exposes `ocr` / `find` / `barcode` /
`qr` / `classify` / `make-qr` / `document-bounds` / `rectify-document` / `document-ocr` / `doctor`
as tools (plus `ask` when the binary is built with the macOS 27 multimodal path):

```json
{ "mcpServers": { "mac-vision": { "command": "/path/to/macvis", "args": ["mcp"] } } }
```

**MCP server (HTTP)** — `macvis serve` runs an HTTP JSON-RPC endpoint for non-Mac or remote nodes
that cannot launch a local process. Defaults to `0.0.0.0:9090`; use `--host` / `--port` to restrict:

```bash
macvis serve --host 127.0.0.1 --port 9090   # loopback only (safest)
macvis serve                                  # all interfaces — warns on startup; restrict with a firewall
```

Configure remote nodes to use `type: http` with the Mac's LAN address:

```json
{ "mcpServers": { "macvis": { "type": "http", "url": "http://192.168.x.y:9090/mcp" } } }
```

Remote callers pass images as base64 in the `data` field instead of `path`. There is no built-in
authentication — treat this as a filesystem read service on your LAN and secure accordingly.

**Claude Code skill** — this repo ships one in [`skills/macvis/`](skills/macvis/SKILL.md).
Symlink it into your skills directory:

```bash
ln -s "$PWD/skills/macvis" ~/.claude/skills/macvis
```

The agent then invokes `macvis` on natural-language triggers (read text from an image, find a
UI element's coordinates, …). The skill calls `macvis` from your `PATH`, so install it first
(see [Install](#install)).

## Architecture

A single `VisionService` seam executes every request and is shared by the CLI and the MCP
server, so both produce identical output. Calls run in-process — Vision OCR has no heavy
model to keep resident and the MCP server is already long-lived, so there's no daemon to
manage.

## License

MIT © 2026 Kim Junmo
