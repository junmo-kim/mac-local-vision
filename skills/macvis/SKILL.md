---
name: macvis
description: >
  On-device, zero-token vision for AI agents (mac-local-vision, macOS). Read text from an
  image / screenshot / PDF (OCR), find the exact click-pixel of a word for E2E/UI assertions,
  scan QR codes and barcodes, group photos by face, or ask a question about an image. Apple
  Vision + Foundation Models, fully on-device — no cloud, no vision tokens, ~0.3s per call.
  Reach for this whenever an agent needs to read or locate something in a screenshot/image
  instead of sending it to a cloud vision API. Triggers: read text from an image, OCR a
  screenshot/PDF, find a button's pixel coordinates, click-point for E2E, assert text is on
  screen, scan a QR code, read a barcode, decode a barcode payload, on-device/local vision,
  sort photos by person. Apple Silicon + macOS 26+ (`ask` needs macOS 27).
user_invocable: true
---

# macvis

`macvis` reads and locates things in images, on-device. Put the binary on your `PATH`
(repo README → Install) and call it. Output is YAML by default; add `--format json` to parse.

## Which command

| You need | Command |
| --- | --- |
| Read all text from an image / screenshot / PDF | `macvis ocr <path>` |
| The click-point `(x,y)` of a specific word — E2E / UI targeting | `macvis find <path> --target "<text>"` |
| Scan a QR code or barcode (any symbology) | `macvis barcode <path>` |
| To *interpret* an image (describe, reason, summarize) — macOS 27 | `macvis ask <path> --prompt "<question>"` |
| Group photos by person | `macvis sort-faces <dir>` |
| Find photos matching a given face | `macvis find-person --target <face.jpg> --dir <dir>` |
| Check what runs on this machine | `macvis doctor` |

Rule of thumb: `ocr` to read everything, `find` to get one word's pixel to click/assert,
`ask` only when you need interpretation rather than raw text.

## Examples

```bash
macvis ocr ./receipt.png                          # full text + per-line entries
macvis ocr ./receipt.png --words --format json    # per-word pixel boxes, JSON
macvis find ./screen.png --target "Submit"        # → x,y click center + bounding box
macvis find ./screen.png --target "결제하기"        # non-Latin works (locale-aware)
macvis ocr ./doc.pdf --page 2                      # PDF page (rasterized)
macvis barcode ./ticket.png                        # scan every QR/barcode symbology
macvis sort-faces ./photos --output-dir ./by-person  # cluster a folder of photos by person
```

## Reading the output

- **stdout = data, stderr = structured errors** (`error` / `reason` / `hint`) — keep them apart.
- **Exit codes:** `0` ok · `1` ran but no result (e.g. `find` miss) · `64` bad args ·
  `70` permanently unavailable · `71` retry later.
- **`find`:** always check `found` — it's `false` (with exit 1) when the target isn't on
  screen. `x,y` is the click center; `approximate: true` means the box is the whole text line,
  not word-tight.
- Recognition languages auto-detect from the system locale; override with `--lang ko-KR,en-US`.
- `find` filters at `--min-confidence 0.3` by default (`ocr` keeps everything); lower it for blurry/headless renders.

Full flags for any command live in `macvis <command> --help` (the canonical, code-generated
reference). To drive it as a tool server instead of the CLI, run `macvis mcp` — same engine,
exposes `ocr` / `find` / `barcode` / `doctor` (and `ask` on macOS 27 builds) as MCP tools.
