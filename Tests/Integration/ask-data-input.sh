#!/usr/bin/env bash
# Contract test for `ask` image input over the network: base64 `data` via MCP and raw
# bytes via HTTP QUERY, plus the existing Mac-local `path` input.
#
# Model-free checks always run (CI). Live-model checks run only when
# `macvis doctor` reports ask as available; otherwise they are skipped.
set -euo pipefail

binary=${1:-.build/debug/macvis}
script_dir=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

xcrun swiftc "$script_dir/ask-golden-gate-fixture.swift" -o "$tmp/gen"
"$tmp/gen" "$tmp/fixture.png"
sips -s format jpeg "$tmp/fixture.png" --out "$tmp/fixture.jpg" >/dev/null

port=$(python3 -I - <<"PY"
import socket
s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()
PY
)
"$binary" serve --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
server_pid=$!
ready=false
for _ in $(seq 1 50); do
  if lsof -nP -a -p "$server_pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    ready=true
    break
  fi
  kill -0 "$server_pid" 2>/dev/null || { echo "server exited before listening" >&2; exit 1; }
  sleep 0.1
done
[[ "$ready" == true ]] || { echo "server did not start listening" >&2; exit 1; }

base="http://127.0.0.1:$port"

# MCP tools/call over HTTP. Prints the tool's text payload; fails the script on a transport
# or JSON-RPC error (no `result`).
mcp_call() {
  local timeout=$1 args_json=$2
  local body
  body=$(python3 -I -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":json.loads(sys.argv[1])}}))' "$args_json")
  curl -sS --max-time "$timeout" -X POST "$base/mcp" \
    -H 'Content-Type: application/json' --data-binary "$body" |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["content"][0]["text"])'
}

# QUERY /ask with a file body (or empty). Writes body to $tmp/out and prints the status.
query_ask() {
  local timeout=$1 qs=$2 file=${3:-}
  if [[ -n "$file" ]]; then
    curl -sS -o "$tmp/out" -w '%{http_code}' --max-time "$timeout" -X QUERY "$base/ask?$qs" \
      -H 'Content-Type: application/octet-stream' --data-binary "@$file"
  else
    curl -sS -o "$tmp/out" -w '%{http_code}' --max-time "$timeout" -X QUERY "$base/ask?$qs" \
      -H 'Content-Type: application/octet-stream' -H 'Content-Length: 0'
  fi
}

# expect_json <label> <json-text> <python-expr over `d`>
expect_json() {
  local label=$1 text=$2 expr=$3
  if ! python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if eval(sys.argv[2]) else 1)' "$text" "$expr"; then
    echo "FAIL $label: expected $expr, got: $text" >&2
    exit 1
  fi
  echo "ok   $label"
}

expect_status() {
  local label=$1 got=$2 want=$3
  if [[ "$got" != "$want" ]]; then
    echo "FAIL $label: expected HTTP $want, got $got: $(cat "$tmp/out")" >&2
    exit 1
  fi
}

png_b64=$(base64 -i "$tmp/fixture.png")
jpg_b64=$(base64 -i "$tmp/fixture.jpg")

# --- model-free checks ---------------------------------------------------------------

out=$(mcp_call 10 "{\"data\":\"$png_b64\",\"format\":\"json\"}")
expect_json "M1 MCP data without prompt -> missing_prompt" "$out" 'd.get("reason") == "missing_prompt"'

out=$(mcp_call 10 '{"prompt":"x","format":"json"}')
expect_json "M2 MCP neither path nor data -> missing_input" "$out" 'd.get("reason") == "missing_input"'

tools=$(curl -sS --max-time 10 -X POST "$base/mcp" -H 'Content-Type: application/json' \
  --data-binary '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' |
  python3 -I -c 'import json,sys; t=[x for x in json.load(sys.stdin)["result"]["tools"] if x["name"]=="ask"][0]["inputSchema"]; print(json.dumps(t))')
expect_json "M3 tools/list ask schema requires only prompt and offers data" "$tools" \
  'd.get("required") == ["prompt"] and "data" in d.get("properties", {})'

status=$(query_ask 10 'format=json' "$tmp/fixture.png")
expect_status "M4 QUERY raw bytes without prompt" "$status" 400
expect_json "M4 QUERY raw bytes without prompt -> missing_prompt" "$(cat "$tmp/out")" 'd.get("reason") == "missing_prompt"'

# --- live-model checks -----------------------------------------------------------------

ask_state=$("$binary" doctor --format json | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("ask",""))')
if [[ "$ask_state" != "available" ]]; then
  echo "skip: ask unavailable ($ask_state)"
  exit 0
fi

prompt='What%20text%20is%20shown%3F'
answered='d.get("compute") == "on-device" and bool(d.get("answer"))'

status=$(query_ask 120 "prompt=$prompt&format=json" "$tmp/fixture.png")
expect_status "L1 QUERY raw PNG bytes" "$status" 200
expect_json "L1 QUERY raw PNG bytes -> on-device answer" "$(cat "$tmp/out")" "$answered"

out=$(mcp_call 120 "{\"data\":\"$jpg_b64\",\"prompt\":\"What text is shown?\",\"format\":\"json\"}")
expect_json "L2 MCP base64 JPEG data -> on-device answer" "$out" "$answered"

status=$(query_ask 120 "path=$tmp/fixture.png&prompt=$prompt&format=json")
expect_status "L3 QUERY path (regression)" "$status" 200
expect_json "L3 QUERY path (regression) -> on-device answer" "$(cat "$tmp/out")" "$answered"

echo "ask data input contract: all checks passed"
