#!/usr/bin/env bash
# Contract test for PDF page metadata: PDF input reports `page` and `page_count` at the
# top of every image tool's output across CLI, HTTP QUERY and HTTP MCP; raster input
# output carries no page keys. Model-free (runs in CI).
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

xcrun swiftc "$script_dir/pdf-page-fixture.swift" -o "$tmp/gen"
"$tmp/gen" "$tmp/fixture.pdf" "$tmp/fixture.png"

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
  local tool=$1 args_json=$2
  local body
  body=$(python3 -I -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$tool" "$args_json")
  curl -sS --max-time 30 -X POST "$base/mcp" \
    -H 'Content-Type: application/json' --data-binary "$body" |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["content"][0]["text"])'
}

# QUERY /<tool>?<qs> with a file body. Writes the body to $tmp/out and prints the status.
query_tool() {
  local path_qs=$1 file=$2
  curl -sS -o "$tmp/out" -w '%{http_code}' --max-time 30 -X QUERY "$base/$path_qs" \
    -H 'Content-Type: application/octet-stream' --data-binary "@$file"
}

# expect_json <label> <json-text> <python-expr over `d` (parsed) and `keys` (top-level order)>
expect_json() {
  local label=$1 text=$2 expr=$3
  if ! python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); keys=list(d) if isinstance(d, dict) else []; sys.exit(0 if eval(sys.argv[2]) else 1)' "$text" "$expr"; then
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

pdf_b64=$(base64 -i "$tmp/fixture.pdf")

out=$("$binary" ocr "$tmp/fixture.pdf" --format json)
expect_json "P1 CLI ocr PDF defaults to page 1 and reports page_count first" "$out" \
  'keys[:2] == ["page", "page_count"] and d["page"] == 1 and d["page_count"] == 3 and "PAGE ONE" in d["text"]'

out=$("$binary" ocr "$tmp/fixture.pdf" --page 2 --format json)
expect_json "P2 CLI ocr --page 2 reports the processed page" "$out" \
  'd["page"] == 2 and d["page_count"] == 3 and "PAGE TWO" in d["text"]'

status=$(query_tool 'document-ocr?page=3&format=json' "$tmp/fixture.pdf")
expect_status "P3 QUERY document-ocr page 3" "$status" 200
expect_json "P3 QUERY document-ocr page 3 -> page meta" "$(cat "$tmp/out")" \
  'd["page"] == 3 and d["page_count"] == 3'

out=$(mcp_call classify "{\"data\":\"$pdf_b64\",\"format\":\"json\"}")
expect_json "P4 MCP classify PDF data -> page meta" "$out" 'd["page"] == 1 and d["page_count"] == 3'

out=$("$binary" ocr "$tmp/fixture.png" --format json 2>"$tmp/stderr")
expect_json "P5 CLI ocr raster output has no page keys" "$out" '"page" not in d and "page_count" not in d'
if [[ -s "$tmp/stderr" ]]; then
  echo "FAIL P5 raster input must not write diagnostics to stderr: $(cat "$tmp/stderr")" >&2
  exit 1
fi
echo "ok   P5 raster input writes nothing to stderr"

# --- out-of-range pages ----------------------------------------------------------------

set +e
"$binary" ocr "$tmp/fixture.pdf" --page 4 --format json >/dev/null 2>"$tmp/stderr"
code=$?
set -e
[[ "$code" == 64 ]] || { echo "FAIL R1 CLI ocr --page 4: expected exit 64, got $code: $(cat "$tmp/stderr")" >&2; exit 1; }
expect_json "R1 CLI ocr --page 4 -> page_out_of_range naming the page count" "$(cat "$tmp/stderr")" \
  'd.get("reason") == "page_out_of_range" and "3 page" in d.get("detail", "")'

status=$(query_tool 'barcode?page=0&format=json' "$tmp/fixture.pdf")
expect_status "R2 QUERY barcode page 0" "$status" 400
expect_json "R2 QUERY barcode page 0 -> page_out_of_range" "$(cat "$tmp/out")" 'd.get("reason") == "page_out_of_range"'

out=$(mcp_call ask "{\"data\":\"$pdf_b64\",\"prompt\":\"x\",\"page\":9,\"format\":\"json\"}")
expect_json "R3 MCP ask PDF page 9 -> page_out_of_range before any model call" "$out" 'd.get("reason") == "page_out_of_range"'

out=$("$binary" ocr "$tmp/fixture.png" --page 5 --format json)
expect_json "R4 CLI ocr raster ignores page as before" "$out" '"page" not in d and "text" in d'

echo "PDF page metadata contract: all checks passed"
