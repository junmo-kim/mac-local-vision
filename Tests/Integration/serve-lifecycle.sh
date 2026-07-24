#!/usr/bin/env bash
set -euo pipefail

binary=${1:-.build/debug/macvis}
# Regression fixture for v0.3.0's mistaken lifetime connection limit. This is
# not a supported server limit and must remain independent of implementation.
readonly historical_connection_budget=32
port=$(python3 - <<"PY"
import socket
s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()
PY
)

"$binary" serve --host 0.0.0.0 --port "$port" >/dev/null &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
trap cleanup EXIT

ready=false
for _ in $(seq 1 50); do
  if lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    ready=true
    break
  fi
  kill -0 "$pid" 2>/dev/null || { echo "server exited before listening" >&2; exit 1; }
  sleep 0.1
done
[[ "$ready" == true ]] || { echo "server did not start listening" >&2; exit 1; }

request() {
  local description=$1 timeout=$2
  local code
  code=$(curl -sS -o /dev/null --max-time "$timeout" -w "%{http_code}" "http://127.0.0.1:$port/mcp" || true)
  if [[ "$code" != "404" ]]; then
    echo "$description failed: expected HTTP 404, got ${code:-no response}" >&2
    exit 1
  fi
}

for i in $(seq 1 "$historical_connection_budget"); do
  request "historical setup connection $i" 3
done

request "canary connection after historical lifetime budget" 5

echo "serve lifecycle test: accepted a canary connection after the historical lifetime budget"
