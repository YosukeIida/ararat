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
  imported items carry a zero HLC. The Arc importer calls `repair_tree` and keeps its result (the
  file is the origin of those registers). Elsewhere repair is to be a view over unmodified
  registers (architecture 6.1, Codex A2): `repair_tree` still mutates, so the view form is built
  with the sync merge in phase 8, together with delivery-order tests.
- Importer ran on the owner's real `StorableSidebar.json` without error: 6 spaces, favorites and
  pinned counted, **today 0 in every space**. Most likely Arc's auto-archive (the owner's
  setting archives Today after a set time; one space was seen empty in Arc on 2026-10-31). The
  importer does not read `StorableArchiveItems` yet. Do not read
  `~/Library/Application Support/Arc` yourself; a structure-only diagnostic (keys and counts, no
  titles or URLs) needs the owner's approval first.
- Harness window not yet viewed by the owner (README: `xc swift run AraratHarness [path]`).
- Everything up to here is in the initial commit. Xcode 27.1 installed and selected; `.mcp.json`
  registers the Xcode MCP (`xcrun mcpbridge`).
- Yab static analysis done: findings in `docs/research/yab-static.md`, method and scripts in
  `docs/research/yab/`. The floating sidebar's logic was not located (stripped Swift closures in
  the `Column*` classes); its values come from observing Yab. The saved Ghidra project (1.2 GB) and the arm64
  slice are in `analysis/yab/` (gitignored); reopen with `docs/research/yab/README.md` section 3. No REA MCP registration was made.

- Yab observation done by GUI automation: findings in `docs/research/yab-observed.md`, tools in
  `docs/research/yab/` (README section 4). Phase 1's parallel research track is complete.
- Phase-1 review findings fixed after three Codex rounds (`docs/reviews/2026-10-31-phase1-judgement.md`).
  Left open on purpose: the C1 starvation and an interrupted commit have no deterministic test
  (a writer hook was not taken); repair as a view waits for the sync merge (phase 8).
- Arc and Ardia floating sidebars measured the same way: `docs/research/arc-ardia-observed.md`.
  Arc, like Yab, keeps the sidebar while the pointer is left of the window, up to about 250 pt
  away; above the window and on deactivation Arc hides, Yab stays. Ardia hides on leaving the
  window in any direction. The owner chose Arc's values and rules for Ararat, including
  hiding on deactivation (architecture §7).
- Owner's settings choices (2026-10-31), in architecture §7: one settings window for all spaces,
  opened at the current space's settings; extensions added from a settings pane per profile,
  with an "add from Arc" path.
- Space switching by scrolling measured on Arc, Yab and Ardia with the owner's trackball and trackpad
  (`docs/research/arc-ardia-observed.md` section 5). The owner chose Arc's rule (architecture §7), and
  Arc's values replace Dia's for all motion. Arc's trackpad paging, wheel rule, ⌘S motion and tab
  close were then measured (sections 5–6); most coincide with Dia's published values.

## Next

1. Expose `Store` through UniFFI and load the harness from SQLite; show the repaired view after
   `load` without writing it back. Run it on herdr-agent-team from a Claude session started inside
   herdr (`AGENTS.md`): Opus scopes and reviews, Codex `gpt-6.1-sol` medium (labteam) implements.
   Scope, decided 2026-10-31:
   - `core/ararat-ffi/src/lib.rs`: a `uniffi::Object` wrapping `Store` with `open(path)` (returns
     the object; the snapshot is read separately), `snapshot()`, `import_arc_sidebar(json)` (imports,
     writes `Workspace::to_ops()` through the store, flushes, returns the snapshot), `flush()` and
     `last_error()`. Store errors become a new `CoreError` variant. Keep the existing free
     `import_arc_sidebar` for the JSON-only path.
   - Repair as a view: `snapshot()` clones the loaded `Workspace`, runs `repair_tree` on the clone
     and builds rows from it; the store is never written by it. The view form proper waits for phase 8.
   - `macos/Sources/AraratHarness/main.swift`: `--db <path>` opens the store; an empty store first
     imports the bundled synthetic fixture (or the given `StorableSidebar.json`); without `--db`
     behaviour is unchanged and no file is created. Flush on quit and report its error.
   - Tests (Rust): import, close, reopen gives the same snapshot; a store holding a cycle gives a
     snapshot without hanging and its rows in SQLite are unchanged afterwards; the FFI object can be
     used from two threads. Harness: `--db` on a temp file answers the stdin `state` command.
   - Not in scope: saving edits made in the UI.
2. Owner: view the harness window.

## Known loose ends

- `macos/Generated/` is a stale leftover (gitignored); delete when allowed.
- Synthetic fixture exists twice (`core/ararat-core/tests/fixtures/`, `macos/Sources/AraratHarness/Fixtures/`).
- Fresh clone must run `macos/scripts/build-core.sh` before `swift build`.
- Inside the devshell `swift` and `swiftc` are hidden by nix's apple-sdk; use the README's `xc`.
  `mkShellNoCC` was tried to avoid this and breaks Rust linking (`-liconv`).
- Open owner decisions: architecture §14 (per-space settings mock first, favorites per profile or per space, DRM, content blocker, Safe Browsing source, sync hosting).
