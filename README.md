# mac-local-vision (`macvis`)

[![CI](https://github.com/junmo-kim/mac-local-vision/actions/workflows/ci.yml/badge.svg)](https://github.com/junmo-kim/mac-local-vision/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 26+ · Apple Silicon](https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20Apple%20Silicon-lightgrey)

Zero-token, on-device vision for AI agents and E2E tests — built as a **100% Pure
Swift single binary** on Apple's native `Vision` and `FoundationModels` frameworks.
No Node, no Python, no runtime dependencies: the OS *is* the dependency.

- **Zero-Token OCR** — extract text/layout locally, never spending cloud vision tokens.
- **Fast E2E targeting** — `find` returns the exact pixel center of a word for click/assert.
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
| `doctor` | ✅ working | macOS 26 |
| `sort-faces` / `find-person` | ✅ working — same-session grouping; cross-time identity is approximate (see note) | Apple Silicon · macOS 26 |
| `mcp` | ✅ working — stdio JSON-RPC, exposes ocr/find/doctor as tools (+ask on macOS 27 builds) | macOS 26 |
| `serve` | ✅ working — HTTP JSON-RPC MCP server for remote/non-Mac nodes | macOS 26 |
| `ask` | 🟢 Beta — targets a pre-release Apple stack (macOS 27 Beta + Foundation Models multimodal). Built against the macOS 27 SDK with the call shape from Apple's official WWDC26 example; availability/error path verified on a real macOS 27 boot. Graduates from Beta as macOS 27 ships (see note). | macOS 27 (Beta) + Apple Intelligence |

> **`sort-faces` accuracy**: faces are grouped by an image feature print over the face
> crop (Apple exposes no public face-embedding API). This reliably groups near-duplicate
> / same-session faces, but is a weak identity signal across large pose/lighting/age
> changes — tune `--threshold` (distances are in the output). Not a person-recognition DB.

> **`ask` is Beta** because it rides on a pre-release Apple stack — macOS 27 (Beta) and the new
> Foundation Models *multimodal* API, both still in beta. The call — `session.respond { prompt; Attachment(image) }` —
> matches Apple's official [WWDC26 Foundation Models session](https://developer.apple.com/videos/play/wwdc2026/241/)
> (which lists `CGImage` among the accepted inputs) and builds clean against the macOS 27 SDK; on a real
> macOS 27 boot the availability/error path is verified (Apple Intelligence off → structured
> `apple_intelligence_not_enabled`, exit `71`). Apple Intelligence itself is gated to eligible,
> internal-boot installs, so `ask` tracks the platform: it graduates from Beta as macOS 27 ships. The
> rest of macvis (`ocr` / `find` / `sort-faces` / `mcp`) is stable on macOS 26 today.

## Build & test

```bash
swift build -c release       # binary at .build/release/macvis
swift test                   # pure logic + ask plumbing + Vision OCR fixtures
```

> Building the `ask` path against real macOS 27 APIs needs the Xcode 27 SDK; the
> current target compiles on macOS 26 with `ask` behind `@available(macOS 27, *)`
> + runtime availability guards.

## Usage

```bash
macvis ocr ./receipt.png                                # extract text
macvis find ./screen.png --target "Submit"              # pixel center of a word
macvis find ./screen.png --target "결제하기"             # non-Latin works too (locale-aware)
macvis ask ./design.png --prompt "main theme color?"    # Beta — needs macOS 27 (Beta)
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

`doctor` reports what runs here, plus the locale-derived OCR languages:

```yaml
$ macvis doctor
ocr: available
find: available
sort-faces: available
ask: "unavailable: needs_macos_27_sdk"
ocr_languages:
  - ko-KR
  - en-US
```

## Use from an LLM agent

Two equivalent integrations — both run the same `VisionService` engine, so the output is identical.

**MCP server (stdio)** — `macvis mcp` speaks stdio JSON-RPC and exposes `ocr` / `find` / `doctor` as tools
(plus `ask` when the binary is built with the macOS 27 multimodal path):

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
