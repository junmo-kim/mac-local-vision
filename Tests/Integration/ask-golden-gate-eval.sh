#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <path-to-macvis-binary> --output <result.json> [--vision-tools-ab]" >&2
}

if [[ $# -lt 3 ]]; then
  usage
  exit 64
fi

binary=$1
shift
output=""
vision_tools_ab=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      output=$2
      shift 2
      ;;
    --vision-tools-ab)
      vision_tools_ab=true
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 64
      ;;
  esac
done

[[ -n "$output" ]] || { echo "--output is required" >&2; usage; exit 64; }
[[ -x "$binary" ]] || { echo "macvis binary is not executable: $binary" >&2; exit 66; }

binary=$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/macvis-ask-golden-gate-eval.XXXXXX")
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

fixture_generator="$tmpdir/ask-golden-gate-fixture"
xcrun swiftc \
  "$script_dir/ask-golden-gate-fixture.swift" \
  -o "$fixture_generator"

fixture="$tmpdir/ask-golden-gate.png"
fixture_repeat="$tmpdir/ask-golden-gate-repeat.png"
"$fixture_generator" "$fixture"
"$fixture_generator" "$fixture_repeat"
cmp -s "$fixture" "$fixture_repeat" || {
  echo "fixture generation is not byte-for-byte deterministic" >&2
  exit 1
}

evaluator_args=(
  "$script_dir/ask_golden_gate_eval.py"
  "$binary"
  --fixture "$fixture"
  --output "$output"
)
if [[ "$vision_tools_ab" == true ]]; then
  evaluator_args+=(--vision-tools-ab)
fi

python3 "${evaluator_args[@]}"
