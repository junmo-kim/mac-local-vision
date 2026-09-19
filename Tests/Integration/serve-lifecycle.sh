#!/usr/bin/env bash
set -euo pipefail

binary=${1:-.build/debug/macvis}
# Regression fixture for v0.3.0's mistaken lifetime connection limit. This is
# not a supported server limit and must remain independent of implementation.
readonly historical_connection_budget=32
active_pid=""
cleanup() {
  if [[ -n "$active_pid" ]]; then
    kill "$active_pid" 2>/dev/null || true
    wait "$active_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

run_server() {
local host=$1
local port
port=$(python3 - <<"PY"
import socket
s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()
PY
)

"$binary" serve --host "$host" --port "$port" >/dev/null &
active_pid=$!

local ready=false
for _ in $(seq 1 50); do
  if lsof -nP -a -p "$active_pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    ready=true
    break
  fi
  kill -0 "$active_pid" 2>/dev/null || { echo "server exited before listening on $host" >&2; exit 1; }
  sleep 0.1
done
[[ "$ready" == true ]] || { echo "server did not start listening on $host" >&2; exit 1; }

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

kill "$active_pid" 2>/dev/null || true
wait "$active_pid" 2>/dev/null || true
active_pid=""
echo "serve lifecycle test ($host): accepted a canary connection after the historical lifetime budget"
}

run_server 0.0.0.0
run_server 127.0.0.1
