# Contributing to macvis

Thanks for your interest! macvis is a **zero-dependency, single-binary** macOS CLI — staying
small and dependency-free is a core goal, so PRs that pull in third-party packages are unlikely
to land without a strong reason.

## Build & test

```bash
swift build -c release
swift test                   # must stay green
```

The `ask` (macOS 27 multimodal) path is compiled out by default. Build it against the macOS 27
SDK (Xcode 27) with `-Xswiftc -DMACVIS_ASK_IMAGE`; see `scripts/release-ask.sh`.

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
the core binary, generates the release notes, and publishes the GitHub Release; the
`ask`-enabled binary is attached manually afterwards.

1. **Bump the version** in `Sources/macvis/main.swift` (`let version = "X.Y.Z"`).
2. **Promote the changelog**: rename `## Unreleased` to `## vX.Y.Z` in `CHANGELOG.md`. That
   section becomes the release-notes keynote — `scripts/gen-release-notes.sh` renders it under
   the title, then appends a "What's Changed" list built from the Conventional-Commit subjects
   since the previous tag (so keep commit messages clean).
3. **Commit** (`chore(release): vX.Y.Z`).
4. **Tag and push**: `git push origin main && git tag vX.Y.Z && git push origin vX.Y.Z`. The
   tag triggers CI, which builds the stripped core binary (macOS 26 SDK), attaches it, and
   publishes the release with the generated notes.
5. **Attach the `ask` binary**: on a Mac with a matching Xcode 27 beta, run
   `scripts/release-ask.sh vX.Y.Z`. It builds the multimodal `ask` superset and uploads it,
   replacing the core asset under the same name.

> ⚠️ **FoundationModels SDK ↔ runtime match (`ask` binary).** FoundationModels is still beta, so
> its ABI isn't stable across beta builds: build the `ask` binary with the Xcode 27 beta whose
> FoundationModels SDK matches the macOS 27 runtime it will run on — a mismatch can SIGSEGV
> inside a live model call. `release-ask.sh` warns on a detected mismatch. This caveat goes away
> once FoundationModels reaches a stable ABI (GA).
