#!/usr/bin/env bash
#
# Generate GitHub release notes: optional keynote highlight from CHANGELOG.md
# + a "What's Changed" section built from conventional-commit messages since
# the previous tag. No install instructions here — see README (matches the
# convention used by ripgrep/fd/bat/zoxide/gh/delta release notes).
#
# Usage: scripts/gen-release-notes.sh <tag>   e.g. scripts/gen-release-notes.sh v0.2.0
# Needs: full git history + tags (actions/checkout must use fetch-depth: 0).
# Optional: a "## <tag>" section in CHANGELOG.md — its body, up to the next
# "## " heading, is rendered right under the title if present. Move the
# "## Unreleased" section's content there before tagging.
# Written for bash 3.2 (macOS default / GitHub macos runners) — no associative arrays.
set -euo pipefail

TAG="${1:?usage: scripts/gen-release-notes.sh <tag>}"
PREV_TAG="$(git describe --abbrev=0 --tags "${TAG}^" 2>/dev/null || true)"
RANGE="${TAG}"
[ -n "$PREV_TAG" ] && RANGE="${PREV_TAG}..${TAG}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

echo "## macvis ${TAG}"
echo

if [ -f "$CHANGELOG" ]; then
  keynote="$(awk -v tag="$TAG" '
    $0 == "## " tag { p=1; next }
    /^## / { if (p) exit }
    p { buf[++n]=$0 }
    END {
      first=1; last=n
      while (first<=n && buf[first]=="") first++
      while (last>=first && buf[last]=="") last--
      for (i=first;i<=last;i++) print buf[i]
    }
  ' "$CHANGELOG")"
  if [ -n "$keynote" ]; then
    printf '%s\n\n' "$keynote"
  fi
fi

if [ -n "$PREV_TAG" ]; then
  echo "## What's Changed since ${PREV_TAG}"
else
  echo "## What's Changed"
fi
echo

ALL_LOG="$(git log --no-merges --format='%h %s' "$RANGE")"
KNOWN_TYPES="feat|fix|perf|refactor|docs|test|ci|build|revert"
TYPES="feat:Features fix:Fixes perf:Performance refactor:Refactoring docs:Documentation test:Tests ci:CI build:Build revert:Reverts"

any=0
for pair in $TYPES; do
  type="${pair%%:*}"
  label="${pair#*:}"
  matches="$(printf '%s\n' "$ALL_LOG" | grep -E "^[0-9a-f]+ ${type}(\([^)]*\))?!?: " || true)"
  [ -z "$matches" ] && continue
  any=1
  echo "### ${label}"
  echo
  printf '%s\n' "$matches" | sed -E "s/^([0-9a-f]+) ${type}(\([^)]*\))?!?: (.*)\$/- \\3 (\\1)/"
  echo
done

other="$(printf '%s\n' "$ALL_LOG" | grep -vE "^[0-9a-f]+ (${KNOWN_TYPES})(\([^)]*\))?!?: " | grep -vE '^[0-9a-f]+ chore(\([^)]*\))?: bump version' || true)"
if [ -n "$other" ]; then
  any=1
  echo "### Other"
  echo
  printf '%s\n' "$other" | sed -E 's/^([0-9a-f]+) (.*)$/- \2 (\1)/'
  echo
fi

if [ "$any" -eq 0 ]; then
  echo "_no notable changes_"
fi
