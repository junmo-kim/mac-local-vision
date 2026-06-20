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
