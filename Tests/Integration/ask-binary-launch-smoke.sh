#!/usr/bin/env bash
set -euo pipefail

# Regression guard for 2026-07-24: a binary can compile and link cleanly yet still get
# SIGKILLed on launch by the kernel's code-signing check (cs_invalid_page) — observed when
# -Xlinker -s was combined with the Xcode-27.0.0-Beta.4.app toolchain. `swift build` succeeding
# says nothing about this; only actually launching the binary does. Run this against any
# freshly built ask-enabled binary (`-DMACVIS_ASK_IMAGE`) — locally during development, not
# just at release time — so a bad build/strip/sign combo is caught before it ships.
#
# Usage: Tests/Integration/ask-binary-launch-smoke.sh [path-to-macvis-binary]

binary=${1:-.build/release/macvis}
port=$(python3 - <<"PY"
import socket
s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()
PY
)

"$binary" serve --host 0.0.0.0 --port "$port" >/dev/null 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
trap cleanup EXIT

sleep 3

if ! kill -0 "$pid" 2>/dev/null; then
  echo "ask binary launch smoke test failed: process died within 3s of starting" \
       "(codesign/AMFI kill and dyld symbol errors look like this — check" \
       "\`log show --last 2m --predicate 'eventMessage CONTAINS \"CODE SIGNING\"'\`)" >&2
  exit 1
fi

echo "ask binary launch smoke test: still running 3s after start"
