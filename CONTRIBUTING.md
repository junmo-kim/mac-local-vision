# Contributing to macvis

Thanks for your interest! macvis is a **zero-dependency, single-binary** macOS CLI — staying
small and dependency-free is a core goal, so PRs that pull in third-party packages are unlikely
to land without a strong reason.

## Build & test

```bash
swift build -c release
swift test                   # must stay green
Tests/Integration/release-binary-launch-smoke.sh .build/release/macvis
```

Use Xcode 27. The package keeps a macOS 26 deployment target, while its multimodal `ask` code is
runtime-guarded for macOS 27. A clean compile says nothing about whether the binary actually
launches, so run the release smoke test against every candidate binary.

## Pull requests

- One logical change per PR; keep the diff focused.
- Add or keep tests for behavior changes. Pure logic and CLI/MCP plumbing are unit-tested;
  Vision- and FoundationModels-bound paths are verified at the edges (see `Tests/`).
- Match the existing style. No new dependencies.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).

## Scope

Bug reports, OCR/locale fixes, and DX improvements are very welcome. For larger features
(new commands), please open an issue first to discuss the design.

## Releasing

A release is cut by pushing a `vX.Y.Z` tag. CI (`.github/workflows/release.yml`) then builds
the canonical Xcode 27 binary, verifies it, generates the release notes, and publishes the
GitHub Release.

1. **Bump the version** in `Sources/macvis/main.swift` (`let version = "X.Y.Z"`).
2. **Promote the changelog**: rename `## Unreleased` to `## vX.Y.Z` in `CHANGELOG.md`. That
   section becomes the release-notes keynote — `scripts/gen-release-notes.sh` renders it under
   the title, then appends a "What's Changed" list built from the Conventional-Commit subjects
   since the previous tag (so keep commit messages clean).
3. **Commit** (`chore(release): vX.Y.Z`).
4. **Tag and push**: `git push origin main && git tag vX.Y.Z && git push origin vX.Y.Z`. The
   tag triggers CI, which builds the stripped binary with Xcode 27, runs the release smoke test,
   attaches it, and publishes the release with the generated notes.
