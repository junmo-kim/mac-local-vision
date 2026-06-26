#!/usr/bin/env bash
#
# Build the ask-enabled macvis binary (macOS 27 SDK) and attach it to a GitHub Release.
#
# WHY THIS IS MANUAL: the `ask` multimodal path is gated behind -D MACVIS_ASK_IMAGE and
# needs the macOS 27 SDK (Xcode 27 beta). GitHub-hosted runners don't ship Xcode 27 yet
# (actions/runner-images#14196), so CI (.github/workflows/release.yml) only produces the
# core binary. Run this from a machine that HAS Xcode 27 beta to add the ask-enabled asset.
#
# Usage:   scripts/release-ask.sh <tag>          e.g. scripts/release-ask.sh v0.1.0
# Env:     DEVELOPER_DIR  override Xcode path (default: Xcode-27.0.0-Beta.app)
# Needs:   Xcode 27 beta, gh (authenticated).
# NOTE:    the upload step PUBLISHES to the public GitHub release — run it deliberately.
set -euo pipefail

TAG="${1:?usage: scripts/release-ask.sh <tag>  (e.g. v0.1.0)}"
DEV="${DEVELOPER_DIR:-/Applications/Xcode-27.0.0-Beta.app/Contents/Developer}"

[ -d "$DEV" ] || { echo "✗ Xcode 27 SDK not found at: $DEV  (set DEVELOPER_DIR)"; exit 1; }
command -v gh >/dev/null || { echo "✗ gh CLI not found / not on PATH"; exit 1; }

# Privacy guard — mirrors the CI check. HTTPServer.swift is the sole intentional user
# of Network.framework; all other files must stay fully on-device.
if grep -rInE 'URLSession|URLRequest|NWConnection|NWListener|NWPath|NWBrowser|NWEndpoint|NWParameters|import Network([^A-Za-z]|$)|getaddrinfo|CFSocket|dataTask|downloadTask' Sources/ \
    | grep -v 'Sources/macvis/HTTPServer\.swift:'; then
  echo "✗ a networking API appears in Sources/ — refusing to build/publish"; exit 1
fi

echo "▸ building ask-enabled binary ($(basename "$(dirname "$(dirname "$DEV")")"))…"
DEVELOPER_DIR="$DEV" swift build -c release -Xswiftc -DMACVIS_ASK_IMAGE -Xlinker -s

BIN=.build/release/macvis
# The canonical release binary: this ask-enabled build runs on macOS 26+ (ask just returns
# needs_macos_27 there) and enables ask on macOS 27, so it's a strict superset of the core
# build. It overwrites (--clobber) the CI-built core asset under the same canonical name.
TARBALL="macvis-${TAG}-macos-arm64.tar.gz"
mkdir -p dist
tar -C "$(dirname "$BIN")" -czf "dist/${TARBALL}" "$(basename "$BIN")"
( cd dist && shasum -a 256 "${TARBALL}" | tee "${TARBALL}.sha256" )

echo "▸ uploading ${TARBALL} to release ${TAG} (this publishes publicly)…"
gh release upload "$TAG" "dist/${TARBALL}" "dist/${TARBALL}.sha256" --clobber
echo "✓ attached ${TARBALL} to ${TAG}"
