# Handover

Session handover for the Ararat track. Overwritten each time; history lives in git.
Read `AGENTS.md` and `docs/architecture.md` first.

## State

- Phase 0 (design) done: `docs/architecture.md` draft 2, all Codex round-1 findings judged
  (`docs/reviews/2026-10-30-architecture-draft1-judgement.md`).
- Phase 1 in progress. Done: Rust core model (membership register + fractional order keys),
  ATC routing, Arc sidebar importer, UniFFI binding, AppKit sidebar harness (`macos/`),
  SQLite storage (`core/ararat-core/src/storage.rs`, tests in `tests/storage.rs`), exposed through
  UniFFI as `WorkspaceStore` (`core/ararat-ffi`, tests in `tests/store.rs`); the harness loads from
  SQLite with `--db`. Edits made in the UI are not saved yet. Private-browsing rejection (§5.3) and the backup API (§5.2) are
  not implemented yet. Journal rows carry no HLC or device id; they are not the sync log of §8.3
  until phase 8 adds those.
- Tree repair done (`core/ararat-core/src/tree.rs`, `tests/tree.rs`): cycles, orphans and
  containers given a parent. Not done: "delete wins over a concurrent edit unless it is a
  restore" needs tombstones and belongs to the sync merge (phase 8). Nothing ticks the HLC yet;
  imported items carry a zero HLC. The Arc importer calls `repair_tree` and keeps its result (the
  file is the origin of those registers). Snapshots from the store are a view: they
  repair a clone and never write back (architecture 6.1, Codex A2). The view form inside the merge,
  with delivery-order tests, comes with the sync merge in phase 8.
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
  (a writer hook was not taken); repair as a view inside the sync merge waits for phase 8.
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

- Harness sidebar laid out with Arc's measured dimensions (f6c3ff4; three review rounds, last with no findings). Open nits: empty favorites keep both gaps above the space name (Arc's empty state unmeasured); a focused tile loses focus when the column count changes.
- Sidebar width by drag in the harness: 164–500 pt, follows the pointer, per window in memory, View → Reset Sidebar Width and stdin `width` / `reset-width`; nested rows' fills indented 16 pt per level. Open: no `acceptsFirstMouse`, so a drag on an inactive window may only activate it (Arc unmeasured).
- Floating form in the harness (§7): ⌘S and stdin `toggle-sidebar` / `sidebar`, reveal at the left edge and outside the window, Arc's hide rules, no-tab rule, collapse when a width drag goes left of 81 pt; page card inset 10. Not sampled from frames: the ⌘S hide curve and the reveal overshoot; key-window gating across several windows (the harness has one).
- Space switching by scroll in the harness (§7, 9945e4c; five rounds, last review with no findings): trackpad follow and release, wheel sum and pause, live neighbour views kept out of AX and focus, page pitch = sidebar width. Not verified live: Tab focus (system keyboard navigation off), light appearance, a flick release after round 2, Retina, physical devices. The ends spring back; §7's Library page and space creation are not built.
- Owner's findings fixed on feat/space-scroll-2: the previous space flashed for a frame after a trackpad switch (AppKit resets an NSView layer's model transform; the spring now holds its end until cleanup), and wheel switches now slide with the trackpad's spring. Open nit: the delayed-cleanup test sleeps with `Task.sleep` and can fail if the wake-up is late by more than about 0.1 s.
- Overnight 2026-11-01 (owner asleep, screen locked: nothing below was checked live; all checks in process):
  - Window buttons at Arc's measured centres (9aca21c); hits below the 28 pt titlebar forwarded from `SidebarContainerView`.
  - Rows and favorite tiles reused by id (a6084e6).
  - Close a tab end to end (feat/close-tab): core lifecycle (open, unloaded, closed, archived), successor rule (ours, §5), FFI `close` / `select_item`, ⌘W and stdin `close <id>`, Arc's close motion. The selection is one local record per workspace, not per window (§5.1 asks per window; the harness has one window). The harness calls the core on the main actor, not a serial adapter queue (§5.2). The schema changed: delete old `--db` files. Pinned and favorite tabs ignore ⌘W (Arc unloads a pinned tab; not done). Those two nits were fixed in 68c16fb (stdin `quit`, error replies, temp database removed on quit). The subprocess tests run the harness with `--headless`.
- Successor by selection history (§5): per window, limited to the shown space, split first, pinned/favorite ⌘W unloads; core calls go through one serial `WorkspaceAdapter` (§5.2). Schema changed again: delete old `--db` files. Arc was measured through AppleScript only; ⌘W and the cross-space case still need Arc in the foreground.
- Library with the Archive page (§7). Open: restoring an archived tab does not stamp the membership HLC (§6.1); no clock ticks yet, so do it with the sync merge (phase 8).
- Library scroll fix (fix/library-scroll): a gesture keeps its owner (page, rail, list) from began to its end, so a zero-delta end over the Archive list no longer strands the Library preview; pages are clipped at the sidebar; the rail takes horizontal input back to space 0, the list only scrolls vertically. A stale-state report from review 1 was not reproduced (an event injector artefact). Real trackpad/wheel input and the floating form were not verified live (Screen Sharing was frontmost).
- Next design work is not chosen yet: candidates are tab motion and the Library / space-creation pages.

- 2026-11-02/03 (units 12–24, orca-agent-team, all on main, not pushed): row polish, dock, floating holds, Library rules, space edits and looks in the core with Arc theme import, sidebar looks, traffic lights on the sidebar, the settings window (Spaces, Tabs, Shortcuts, search, per-space pages, Look popover), auto-archive (local `LastSelected`), item moves and folders in the core (local `FolderState`), sidebar drag and drop, folder controls, rename in place and row menus. Rules and values are in §6.1, §6.2 and §7; Arc's drag measurement in `docs/research/arc-ardia-observed.md` §8. None of units 16b–24 has been checked on screen by the owner.

## Next

1. Owner: try units 16b–24 in the harness; decide the gradient direction and docked Glass (questions kept outside the repo by the design session).
2. Measure on Arc: how long a dragged tab rests on a collapsed folder before it opens (now 0.6 s, ours, `folderHoverDelay`).
3. Open nits: the screen-lock Library test; a vertical scroll's ready signal fires before momentum.

## Known loose ends

- `macos/Generated/` is a stale leftover (gitignored); delete when allowed.
- Synthetic fixture exists twice (`core/ararat-core/tests/fixtures/`, `macos/Sources/AraratHarness/Fixtures/`).
- Fresh clone must run `macos/scripts/build-core.sh` before `swift build`.
- Inside the devshell `swift` and `swiftc` are hidden by nix's apple-sdk; use the README's `xc`.
  `mkShellNoCC` was tried to avoid this and breaks Rust linking (`-liconv`).
- Open owner decisions: architecture §14 (per-space settings mock first, favorites per profile or per space, DRM, content blocker, Safe Browsing source, sync hosting).
