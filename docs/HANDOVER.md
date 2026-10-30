# Handover

Session handover for the Ararat track. Overwritten each time; history lives in git.
Read `AGENTS.md` and `docs/architecture.md` first.

## State

- Phase 0 (design) done: `docs/architecture.md` draft 2, all Codex round-1 findings judged
  (`docs/reviews/2026-10-30-architecture-draft1-judgement.md`).
- Phase 1 in progress. Done: Rust core model (membership register + fractional order keys),
  ATC routing, Arc sidebar importer, UniFFI binding, AppKit sidebar harness (`macos/`),
  SQLite storage (`core/ararat-core/src/storage.rs`, tests in `tests/storage.rs`). `Store` is not
  exposed through UniFFI yet; private-browsing rejection (§5.3) and the backup API (§5.2) are
  not implemented yet. Journal rows carry no HLC or device id; they are not the sync log of §8.3
  until phase 8 adds those.
- Tree repair done (`core/ararat-core/src/tree.rs`, `tests/tree.rs`): cycles, orphans and
  containers given a parent. Not done: "delete wins over a concurrent edit unless it is a
  restore" needs tombstones and belongs to the sync merge (phase 8). Nothing ticks the HLC yet;
  imported items carry a zero HLC. Nothing calls `repair_tree` yet; the hooks are after `load` in
  `Store::open` and after every sync merge.
- Importer ran on the owner's real `StorableSidebar.json` without error: 6 spaces, favorites and
  pinned counted, **today 0 in every space**. Unresolved: either Arc auto-archived Today, or the
  importer misreads unpinned children. The owner was asked to look in Arc. Do not read
  `~/Library/Application Support/Arc` yourself; a structure-only diagnostic (keys and counts, no
  titles or URLs) needs the owner's approval first.
- Harness window not yet viewed by the owner (README: `xc swift run AraratHarness [path]`).
- Everything up to here is in the initial commit. Xcode 27.1 installed and selected; `.mcp.json`
  registers the Xcode MCP (`xcrun mcpbridge`).

## Next

1. Analyse Yab statically with REA. Ready: REA at `~/workspace/github.com/morluto/rea`
   (commit 8f920bb6, `npm ci && npm run build` done); the devshell has nodejs_22 22.23.4 and, from
   nixpkgs-unstable, Ghidra 12.1.4 (REA's verified version) with OpenJDK 21. `rea doctor` admits
   Ghidra; it still flags the other engines and the agent registrations, which are not wanted
   (no MCP registration made). Yab 0.42.1 (`dev.serafim.fast`) is universal (x86_64 + arm64);
   analyse the arm64 slice (`lipo -thin arm64`). Owner chose Ghidra over IDA Pro (IDA Free has no
   ARM64 decompiler and decompiles in Hex-Rays' cloud; Pro starts at EUR 1,099 a year).
   Yab's terms (2026-09-30) were checked: lawful use allowed, no anti-analysis clause.
2. Observe Yab's floating sidebar and settings; write the spec.

## Blocked

- Codex reviews paused until the labteam account is refilled (owner's choice). Queue:
  `docs/reviews/PENDING.md`. Keep doing non-review-dependent work.

## Known loose ends

- `macos/Generated/` is a stale leftover (gitignored); delete when allowed.
- Synthetic fixture exists twice (`core/ararat-core/tests/fixtures/`, `macos/Sources/AraratHarness/Fixtures/`).
- Fresh clone must run `macos/scripts/build-core.sh` before `swift build`.
- Inside the devshell `swift` and `swiftc` are hidden by nix's apple-sdk; use the README's `xc`.
  `mkShellNoCC` was tried to avoid this and breaks Rust linking (`-liconv`).
- Open owner decisions: architecture §14 (per-space settings mock first, favorites per profile
  or per space, DRM, content blocker, Safe Browsing source, sync hosting).
