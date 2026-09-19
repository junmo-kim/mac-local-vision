#!/usr/bin/env bash
set -euo pipefail

# Exercise the contracts that can regress even when a release build compiles and links:
# basic CLI launch, core Vision behavior, the canonical ask capability, and a long-running
# process surviving dyld/code-signing checks.
#
# Usage: Tests/Integration/release-binary-launch-smoke.sh [path-to-macvis-binary]

binary=${1:-.build/release/macvis}
binary=$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/macvis-release-smoke.XXXXXX")
pid=""

cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

version=$("$binary" --version)
if ! [[ "$version" =~ ^macvis\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release binary smoke test failed: unexpected version output: $version" >&2
  exit 1
fi
"$binary" --help >/dev/null

doctor_json=$("$binary" doctor --format json)
os_major=$(sw_vers -productVersion | cut -d. -f1)
DOCTOR_JSON="$doctor_json" OS_MAJOR="$os_major" python3 - <<'PY'
import json
import os

doctor = json.loads(os.environ["DOCTOR_JSON"])
os_major = int(os.environ["OS_MAJOR"])
required = {"ocr", "find", "barcode", "classify", "document_bounds", "document_ocr", "segment", "ask"}
missing = sorted(required - doctor.keys())
if missing:
    raise SystemExit(f"doctor is missing capability keys: {', '.join(missing)}")
if "sdk" in doctor["ask"]:
    raise SystemExit("doctor reports a compile-time-disabled ask path")
expected_old_os = "unavailable: needs_macos_27_for_image_input"
if os_major < 27 and doctor["ask"] != expected_old_os:
    raise SystemExit(f"macOS {os_major} must report {expected_old_os!r}, got {doctor['ask']!r}")
if os_major >= 27 and doctor["ask"] == expected_old_os:
    raise SystemExit(f"macOS {os_major} incorrectly reports that image input needs macOS 27")
if os_major < 27 and doctor["segment"] != "unavailable: needs_macos_27":
    raise SystemExit(f"macOS {os_major} must report the segment OS gate, got {doctor['segment']!r}")
if not isinstance(doctor.get("ocr_languages"), list) or not isinstance(doctor.get("ask_languages"), list):
    raise SystemExit("doctor language fields must be arrays")
PY

qr_path="$tmpdir/smoke.png"
"$binary" make-qr macvis-release-smoke --out "$qr_path" --format json >/dev/null
qr_json=$("$binary" qr "$qr_path" --format json)
QR_JSON="$qr_json" python3 - <<'PY'
import json
import os

result = json.loads(os.environ["QR_JSON"])
payloads = [code.get("payload") for code in result.get("codes", [])]
if "macvis-release-smoke" not in payloads:
    raise SystemExit(f"QR round trip failed: {payloads!r}")
PY

set +e
"$binary" segment "$qr_path" --point --box 1,1,10,10 >/dev/null 2>"$tmpdir/segment-cli-error"
segment_cli_code=$?
set -e
if [ "$segment_cli_code" -ne 64 ] || ! grep -q 'invalid --point' "$tmpdir/segment-cli-error"; then
  echo "release binary smoke test failed: valueless --point was not rejected" >&2
  exit 1
fi

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"segment\",\"arguments\":{\"path\":\"$qr_path\",\"point\":[true,false],\"format\":\"json\"}}}" \
  | "$binary" mcp > "$tmpdir/mcp.jsonl"
MCP_OUTPUT="$tmpdir/mcp.jsonl" python3 - <<'PY'
import json
import os

responses = [json.loads(line) for line in open(os.environ["MCP_OUTPUT"], encoding="utf-8")]
response = next((item for item in responses if item.get("id") == 2), None)
if response is None:
    raise SystemExit("MCP tools/list response is missing")
names = {tool.get("name") for tool in response["result"]["tools"]}
if "ask" not in names:
    raise SystemExit("MCP tools/list does not advertise ask")
if "segment" not in names:
    raise SystemExit("MCP tools/list does not advertise segment")
segment = next((item for item in responses if item.get("id") == 3), None)
if segment is None or not segment.get("result", {}).get("isError"):
    raise SystemExit("MCP boolean segment seed was not rejected")
content = segment["result"]["content"][0]["text"]
error = json.loads(content)
if (error.get("error"), error.get("reason")) != ("bad_request", "invalid_seed"):
    raise SystemExit(f"MCP boolean segment seed returned the wrong error: {error!r}")
PY

port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("", 0))
print(s.getsockname()[1])
s.close()
PY
)

"$binary" serve --host 0.0.0.0 --port "$port" >/dev/null 2>&1 &
pid=$!
sleep 3

if ! kill -0 "$pid" 2>/dev/null; then
  echo "release binary smoke test failed: server died within 3 seconds" >&2
  echo "check dyld errors and the macOS code-signing log" >&2
  exit 1
fi

echo "release binary smoke test passed: CLI, doctor, QR, MCP, and server launch"
