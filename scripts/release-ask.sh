#!/usr/bin/env bash
#
# Build the ask-enabled macvis binary (macOS 27 SDK) and attach it to a GitHub Release.
#
# WHY THIS IS MANUAL: the `ask` multimodal path is gated behind -D MACVIS_ASK_IMAGE and
# needs the macOS 27 SDK (Xcode 27 beta). GitHub-hosted runners don't ship Xcode 27 yet
# (actions/runner-images#14196), so CI (.github/workflows/release.yml) only produces the
# core binary. Run this from a machine that HAS Xcode 27 beta to add the ask-enabled asset.
#
# ⚠️ SDK ↔ runtime match: FoundationModels is still beta, so Apple does not guarantee ABI
# stability across beta builds. Build with the Xcode 27 beta whose FoundationModels SDK
# matches the macOS 27 runtime you'll run on — a mismatch (e.g. an older Xcode beta's FM vs
# a newer OS beta's FM) can SIGSEGV inside a live model call, even though the older-SDK build
# would normally be forward-compatible. This script warns on a detected mismatch (below).
# Once FoundationModels ships a stable ABI (GA), this concern goes away.
#
# Usage:   scripts/release-ask.sh <tag>          e.g. scripts/release-ask.sh v0.1.0
# Env:     DEVELOPER_DIR  override Xcode path (default: Xcode-27.0.0-Beta.3.app)
# Needs:   Xcode 27 beta (matching the target runtime's FoundationModels), gh (authenticated).
# NOTE:    the upload step PUBLISHES to the public GitHub release — run it deliberately.
set -euo pipefail

TAG="${1:?usage: scripts/release-ask.sh <tag>  (e.g. v0.1.0)}"
DEV="${DEVELOPER_DIR:-/Applications/Xcode-27.0.0-Beta.3.app/Contents/Developer}"

[ -d "$DEV" ] || { echo "✗ Xcode 27 SDK not found at: $DEV  (set DEVELOPER_DIR)"; exit 1; }
command -v gh >/dev/null || { echo "✗ gh CLI not found / not on PATH"; exit 1; }

# FoundationModels ABI-skew check (beta-only safety net; warn, don't block). FoundationModels
# is still beta, so Apple doesn't guarantee ABI stability across beta builds: if the FM this
# binary is *built* against differs from the FM in the macOS 27 *runtime* it runs on, a live
# model call can SIGSEGV (observed: built against 2.0.51, ran on 2.0.59). Once FoundationModels
# ships a stable ABI (GA), this goes away.
SDK_TBD="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/FoundationModels.tbd"
SDK_FM=$(grep -m1 'current-version:' "$SDK_TBD" 2>/dev/null | awk '{print $2}')
if [ "$(sw_vers -productVersion | cut -d. -f1)" = 27 ]; then
  # Building on a macOS 27 host: its runtime FM is the one this build will actually run against,
  # so an SDK-vs-runtime mismatch is a real, checkable risk right here.
  RT_FM=$(plutil -extract CFBundleVersion raw /System/Library/Frameworks/FoundationModels.framework/Resources/Info.plist 2>/dev/null || true)
  if [ -n "$SDK_FM" ] && [ -n "$RT_FM" ] && [ "$SDK_FM" != "$RT_FM" ]; then
    echo "⚠️  FoundationModels ABI mismatch: build SDK FM=$SDK_FM vs runtime FM=$RT_FM"
    echo "   Beta ABI is unstable; this build may SIGSEGV at runtime. Build with the Xcode 27"
    echo "   beta whose FoundationModels matches this runtime, or verify 'ask' on-device."
  fi
else
  # Building on macOS < 27 for a macOS 27 runtime: that runtime's FM isn't visible here, so the
  # SDK-vs-runtime comparison would only ever compare against the wrong (local) FM. Just flag it.
  echo "ℹ️  building the ask binary (SDK FoundationModels ${SDK_FM:-?}) on $(sw_vers -productVersion) for a"
  echo "   macOS 27 runtime — can't verify the FM ABI match from here; check 'ask' on the target device."
fi

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
