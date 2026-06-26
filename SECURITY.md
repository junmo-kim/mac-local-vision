# Security Policy

## Threat model

macvis runs **entirely on-device**: no telemetry, no analytics, no outbound cloud calls.

**`macvis mcp` (stdio mode):** No networking APIs, no listening socket. CI enforces this — it
fails if any banned networking API appears outside `HTTPServer.swift` (see `.github/workflows/ci.yml`).

**`macvis serve` (HTTP mode):** Network.framework is linked to provide an HTTP JSON-RPC endpoint
for remote nodes on the same LAN. A TCP listening socket is opened on the specified port
(default `0.0.0.0:9090`). There is **no authentication** — any host that can reach the port can
call tools. The server prints a warning when binding to all interfaces; use `--host 127.0.0.1`
to restrict to localhost, or place it behind a firewall/VPN for trusted-LAN use. Over HTTP,
callers can supply a `path` argument pointing to any file the macvis process can read, and
receive its OCR output — treat this like exposing a filesystem read service on your LAN.

Both modes delegate image/PDF decoding to Apple's ImageIO / Vision / CoreGraphics frameworks
and write **only symlinks** (face clustering) — never overwriting other files. Rasterization
sizes are bounded (`OCREngine.maxRasterPixels` / `clampedRasterSize`).

The realistic attack surface is:
- **`mcp` / CLI**: a malicious image or PDF (decoder bug or resource exhaustion).
- **`serve`**: the above, plus an unauthenticated LAN caller with filesystem read access
  (bounded to 20 MB per request; path traversal is limited to what the OS process can open).

## Reporting a vulnerability

Please report security issues **privately** via GitHub's *Security → Report a vulnerability*
(private advisory), not a public issue. Include reproduction steps and the input that triggers
the problem. We'll acknowledge and aim to respond promptly.
