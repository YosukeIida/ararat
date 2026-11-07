# Handover

Session handover for the Ararat track. Overwritten each time; history lives in git.
Read `AGENTS.md` and `docs/architecture.md` first.

## State

- Phase 3 U14 done: extension actions are listed in the sidebar header and open Chrome's real
  action popup; `chrome.action.openPopup()` uses the same host and anchor. Extension-created app
  popups use our page-only host. Hidden extension checks and the wide floating-menu screen check
  pass; the API-opened popup's own on-screen placement remains unverified. `screen-quit` and
  `screen-links` also passed on U13. A separate `screenfix` worktree holds reviewed fixes for
  `screen-prompts` (passed, including WebAuthn cancellation without registration) and the still
  failing `screen-profiles`; neither fix is on main yet.
- Phase 3 U13 done: docked DevTools in the page card under C1 and C2; undocked DevTools uses a
  page-only host, including when only a popup remains. Hidden and screen DevTools checks pass for
  both compositors, including resize and redock; `screen-links` also passes through process exit.
  The Developer menu and its shortcuts wait for U16. Sidebar hit testing no longer captures points
  outside the panel when Glass is absent; late activation of a Browser scheduled for deletion is
  suppressed. The C2 screen check covers the right-docked layout; other docking geometries remain
  unverified.
- Phase 3 U12 done (hidden checks): window-modal dialogs (JS alert/confirm/prompt, HTTP auth, permission
  prompts through our hook, external protocol, WebAuthn) attach to our host's modal host, placed in the
  current page card; autofill save bubbles (address, card) come through our handler. Hidden checks
  `permissions`, `dialogs` (incl. a resize), `protocol`, `autofill` need `--disable-features=SystemNotifications`.
  WebAuthn is screen-only (Bluetooth may be touched before the dialog; no `NSBluetoothAlwaysUsageDescription`).
  `--ararat-screen=prompts` has not been run (screen locked), nor U9–U11's screens.
- Phase 3 U11 done (hidden checks): two profiles share one window; showing a space loads its profile and
  creates that profile's Browser in the host (one Browser per profile per host), extension windows APIs see
  each profile's own windows, off-the-record Browsers are hosted, Chrome's session restore is off for every
  Browser and the startup pref is pinned to Chrome's default. Quit and close ask every hosted profile's
  beforeunload; a cancel that switched the shown profile writes that switch like a normal one. Our window's
  command handler forwards every command to AppController (validation too), except New Tab on an empty
  Browser (`chrome::NewTab`) and Search the Web (dropped until U16). `--ararat-screen=profiles`, `quit` and
  `links` have not been run (screen locked).
- Phase 3 U10 done (hidden checks): the Browser-constructor factory is always on. Default-profile
  (the shown space's profile) TYPE_NORMAL Browsers get a second app window, TYPE_POPUP a page-only popup
  host with no rows; DevTools, app/extension windows, PiP, off-the-record and other profiles stay stock and
  counted (U11/U13/U14). Hosts report activation (`BrowserActiveStateManager`). openURLs and Handoff go to
  the app through `app-controller-hooks.patch` (new rows in the key window's Today; ATC is phase 5).
  Adopted Today rows get url and title from the engine (pinned and favorites keep theirs); background
  adoption leaves the selection alone. Window records carry `changed_at`: close deletes, quit keeps, launch
  and reopen adopt the newest kept one. `GetThemeProvider` now returns the profile's (the NTP crashed).
  Checks `newtab`, `popup`, `menu`, `deferred` pass with every earlier check.
  - Open: `--ararat-screen=links` and `--ararat-screen=quit` not yet run (screen locked); the popup check
    loads `about:blank` (renderer-initiated `data:` popups are blocked by Chrome), so a real page loading in
    a popup host is shown only on screen.
  - Recorded: second-launch URL arguments are dropped under `--no-startup-window` (phase 5); openURLs
    bypasses `safeProfileForNewWindows` (U11); a navigation flag can be lost if the core drops a
    transaction.
- Phase 3 U9 done (hidden checks): Chrome's `AppController` stays the app delegate and owns quit, logout,
  the downloads prompt and the keep-alive (§4.5; architecture said it would be replaced, now corrected).
  `engine/patches/ararat/app-controller-hooks.patch` hands Dock reopen, the Dock menu (empty) and the
  downloads-wait case with no Browser to our layer; `AraratCallbacks.reopen` lets the app rebuild or front
  its window. `AraratMain` adds `--no-startup-window`. Quit and window close leave workspace rows as they
  were (the host stops reporting on `OnClosingAllBrowsers(true)` and resends on `false`); the core stamps
  `LastSelected` on the outgoing tab instead of on every strip (§6). The engine window is titled and
  full-size with the sidebar's traffic lights (shared with the harness `BrowserWindow`). ⌘ key equivalents
  from a focused page go to the main menu. Checks `quit`, `quit-cancel`, `close` pass; `started` runs
  without `--no-startup-window`.
  - Open: `--ararat-screen=quit` (⌘Q from the page, the real beforeunload `NSAlert`, sidebar top-row
    clicks under the titlebar, AppKit lights hidden after resize and full screen) not yet run: the screen
    was locked at the exit.
  - Recorded for later units: window close with a download running crashes
    (`ararat_browser_window.cc` `ConfirmBrowserCloseWithPendingDownloads`, phase 5);
    `OnClosingAllBrowsers(false)` is a broadcast (multi-window); the quit-with-apps path never resets
    `closing_all_` (U10/U11).
- Phase 3 U8 done, so the vertical slice (U1–U8) is complete. The compositor was measured on screen
  (§4.6 table) and **C1 stays**: tab switch 2 ms median vs 15 ms for C2. The tooling is
  `--ararat-compositor=c1|c2` and `--ararat-measure=switch|background|occlusion|resize|display`
  (`engine/ararat/ararat_measure.mm`).
  - Open, from the measurement:
    - Covered windows keep painting at about 18 rAF/s instead of stopping, under both C1 and C2. Window
      occlusion is not wired yet.
    - Background CPU is unverified, because the `ps` pattern was not checked against the helper names.
    - The display change was skipped, because only one display is attached.
    - Split panes wait for U18.
    - The first C1 resize run dropped 24 frames; the cause is unknown.

- Phase 3 U7 done: the app drives the engine in one window — `engine/ararat/public/AraratHostAPI.h`
  (`AraratWindowHostCreate(NSView*, windowId)`, exported), `macos/Sources/AraratKit/EngineAdapter.swift`
  (core commands to `ARTab`/`ARWindowHost`, transactions to `liveApply` unchanged or not at all,
  `liveCancel` for a rejected open), the sidebar wiring shared with the harness
  (`AraratUI/SidebarActions.swift`), the store under the engine's user-data dir (`--ararat-db` overrides),
  hosts released at `will_shut_down`. Core: a failed or cancelled open leaves the map and `pending`; closes
  returned by `apply` are registered; one transaction per command (§4.4). Our window has an
  `ExclusiveAccessContext`. `--ararat-check=slice` passes, including a mouse event that reaches
  `ContentsMouseEvent` (`exclusive_input_seen`). Not seen on screen yet: that is U8.
- Phase 3 U5 done: tabs in the page card — `ARTab` (`engine/ararat/ararat_tab.{h,mm}`, `public/ARTab.h`),
  `-[ARWindowHost initWithContentView:windowId:]`, `-openURL:commandId:itemId:` (BOOL accepted) and the
  transaction feed in `live.rs`'s shape (§4.4: one epoch per engine process, opened by an empty `Engine`
  snapshot; a closed window is an empty strip; a failed open is its command's transaction without its
  live id). The host holds its own profile keep-alive, or the profile unloads with the last tab
  (`kDestroyProfileOnBrowserClose`). `viewless-read-anything.patch`. `--ararat-check=tabs` passes
  (10 transactions, causes match, reopen in the same epoch). Left for U7: the core rule for a failed
  open, an `ExclusiveAccessContext`, releasing hosts at `will_shut_down`. `browser_commands.cc:1521`
  (pinned-only close) is still viewless-unsafe.
- Phase 3 U4 done: our window host and BrowserWindow (`engine/ararat/ararat_browser_window.{h,cc}`,
  `ararat_window_host.{h,mm}`, `public/ARWindowHost.h`, `browser-window-factory.patch`; the hook takes
  `BrowserWindowInterface*`, so no Chromium BUILD.gn visibility patch). `--ararat-check=window` passes
  under `--headless=new`: one Browser, no BrowserView, the host's NSWindow is the native window, hit
  testing lands in the app's NSView. `GetExclusiveAccessContext()` and `CreateFindBar()` return null,
  so mouse input over a hosted page or ⌘F would crash: U7 adds the context, the find bar waits for U16.
- Phase 3 U6 done: the live-tab coordinator v0 is in the core — `core/ararat-core/src/live.rs`
  (`open`/`activate`/`close` commands with fresh ids, `apply` of the engine's
  `{epoch, rev, cause, strips}` transactions with the §5.2 reconcile, `live_tab`/`item_for`
  queries), exported through UniFFI as `WorkspaceStore.liveOpen/liveActivate/liveClose/
  liveApply/liveTab/itemForLive`; the map is one to one and the lifecycle change of a close
  commits in the same storage transaction before the command is returned.
- Phase 3 U3 done: the launcher runs our entry through one hook —
  `engine/ararat/public/AraratEngine.h` (`AraratMain`, `AraratCallbacks`, `AraratQuit`),
  `engine/ararat/ararat_main.mm` (the guards, the callbacks and the extra parts that fire
  `started`/`will_shut_down`), three targets (`hooks`/`core`/`entry` in
  `engine/ararat/BUILD.gn`, `gn check` clean), and `extra-parts-hook.patch`
  (`chrome_content_browser_client.cc` hands its browser main parts to
  `g_ararat_add_browser_main_extra_parts` when the launcher set it; helpers stay stock).
  The `--ararat-check=started` run (a scratch `--user-data-dir`, `--use-mock-keychain`)
  prints one JSON line and quits via `AraratQuit`; anything else exits 2.
- Phase 3 U2 done: our bundle runs the stock engine —
  `macos/Sources/Ararat` launcher (dlopen, `ChromeMain`), `macos/scripts/bundle-app.sh`
  (Ararat.app, id `net.iodine2.ararat`, ad-hoc, renderer/GPU helpers carry allow-jit);
  headless dump-dom and `--version` pass from the bundle.
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
- 2026-11-04 (units 25–30, all on main, not pushed): Arc window-state import, count-based test budgets, the owner's sidebar fixes (rename hint after pinning, no focus rings), Duplicate, key bindings with Arc import and the Shortcuts recorder, Air Traffic Control rules with Arc import and their pane, the command bar without the engine. Implementation moved to two seats (Codex Terra high; key-bindings B1/B2 used `opencode/glm-5.3-flash-free`; AGENTS.md). First stock Chromium build measured (§4.7). The owner tried the Shortcuts recorder. Design drove the harness on screen while the owner was away (command bar, Duplicate, Pin Tab ⌘D with the rename hint, the Shortcuts key column, ATC routes and the link test, the + menu) and fixed what it found in unit 32 (tab count wording, route wording, live link test, screen reader labels). Unit 31 removed process history from code comments. Arc's own screens were not compared side by side; units 16b–24 are still unchecked on screen.

- 2026-11-05 (screen locked, owner asked to leave on-screen work for later): §7 audited against units 12–32 and corrected (bd8d7b5); unit 33 holds auto-archive through momentum and makes the Library test independent of a drawn screen (the clip's scroll under a real wheel is unchecked); unit 34 fills a Shortcuts search result and centres the Look dots on the drawn handle; ungoogled-chromium inventoried. Values the audit took from code because Arc could not be measured: the tooltip's title-to-keycap gap (about 12 pt) and the window buttons' fade (100 ms in, 90 ms out).
- 2026-11-05 phase 2 done: unit 35 (drop at a folder's end, rename hides the title, lighter Look field); per-patch inventory (25 of 137 kept plus two of ours, Safe Browsing kept); unit 36 engine scripts; pinned 157.0.8103.39 after one measured rebase (about 8 min, 14 patches from ungoogled's open PR #4032, crashpad rebased by hand); official full build 4,821 s, out/Dev full 2,673 s, one-file incremental 155 s official / 31 s out/Dev; builds capped at 95 % of the CPUs (owner). Smoke passes headless. The generic patches must be re-vendored when PR #4032 merges.

## Next

1. Owner: try units 16b–24 in the harness; decide the gradient direction and docked Glass (questions kept outside the repo by the design session).
2. Measure on Arc: how long a dragged tab rests on a collapsed folder before it opens (now 0.6 s, ours, `folderHoverDelay`).
3. Phase 3 (vertical slice), plan in `phase3-plan` (kept with the design session's envelopes). U1–U14 are done (C1 chosen, §4.6). Next: U15–U19 in plan order (specs `fullscreen-52` … `practice-rebase-56`); finish the separate `screenfix` checks. The team runs on herdr-agent-team (`~/.config/herdr-agent-team/ararat/`). Seats never write to `~/chromium-build` (Codex's sandbox refuses it): design runs apply, gen, build and the checks at each unit's exit. Run `macos/scripts/build-core.sh` in the plain devshell; Xcode's environment (README's `xc`) is for `swift` only. A new worktree needs `direnv allow` before a seat uses it. Engine scripts need a clean PATH (no `/nix`) and run under `/bin/bash` 3.2: `env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash engine/scripts/<cmd>`. Every engine launch passes `--use-mock-keychain`.

## Known loose ends

- `macos/scripts/build-core.sh` exits non-zero in a checkout whose path contains spaces
  (uniffi step, "No such file or directory"); not fixed yet.
- `macos/Generated/` is a stale leftover (gitignored); delete when allowed.
- Synthetic fixture exists twice (`core/ararat-core/tests/fixtures/`, `macos/Sources/AraratHarness/Fixtures/`).
- Fresh clone must run `macos/scripts/build-core.sh` before `swift build`.
- Inside the devshell `swift` and `swiftc` are hidden by nix's apple-sdk; use the README's `xc`.
  `mkShellNoCC` was tried to avoid this and breaks Rust linking (`-liconv`).
- Open owner decisions: architecture §14 (per-space settings mock first, favorites per profile or per space, DRM, content blocker, Safe Browsing source, sync hosting).
