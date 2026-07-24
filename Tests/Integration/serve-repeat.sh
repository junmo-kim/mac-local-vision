#!/usr/bin/env bash
set -euo pipefail

binary=${1:-.build/debug/macvis}
requests=${REQUESTS:-40}
port=$(python3 - <<"PY"
import socket
s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()
PY
)

"$binary" serve --host 0.0.0.0 --port "$port" >"${TMPDIR:-/tmp}/macvis-serve-repeat.out" 2>"${TMPDIR:-/tmp}/macvis-serve-repeat.err" &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 50); do
  if lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || { cat "${TMPDIR:-/tmp}/macvis-serve-repeat.err" >&2; exit 1; }
  sleep 0.1
done

for i in $(seq 1 "$requests"); do
  code=$(curl -sS -o /dev/null --max-time 1 -w "%{http_code}" "http://127.0.0.1:$port/mcp" || true)
  if [[ "$code" != "404" ]]; then
    echo "request $i failed: HTTP $code" >&2
    exit 1
  fi
done

echo "serve repeat test: $requests/requests passed"
