# Handover

Session handover for the Ararat track. Overwritten each time; history lives in git.
Read `AGENTS.md` and `docs/architecture.md` first.

## State

- Phase 3 U17a done: relaunch selects the adopted window's selected row, other rows stay
  Unloaded; a cancelled, withdrawn or rejected Open rolls the row back; the core keeps a
  durable outbox of history purges (written, not yet consumed); a crashed renderer keeps its
  row Open, the strip marks it and selecting it reloads (sad-tab guard patch). Hidden checks
  `relaunch`, `crash` (two-run driver) and `sadtab` pass on the host with the full suite,
  `cargo test` and `swift test`.
- Phase 3 U17b done (c8263c9): per-row navigation history files survive relaunch and crash,
  purges from the core outbox delete them, explicit history deletion fences live writers, and
  crash recovery holds Chromium's CrashedLock until the workspace restores. Hidden checks
  `history-clear`, `history-purge`, `relaunch`, `crash`, the 22 exit checks,
  `history_files_unittests` (15) and all 63 U16 cases pass (6 screen cases ran in the
  `ararat-test` VM, the rest on the host). Not run: the crash-lock-abandon browser test; the
  abandon path and the clear-marker failure UI are not exercised natively. In the VM the app
  spawns `screencapture`, which still cannot capture after re-signing with `ararat-test-sign`
  and granting Screen Recording (superseded below).
- E2E checks run only in the `ararat-test` VM now (the owner works on the host): `design/vm-u16matrix.sh
  <wt> <bundle> <out> <id> . all` runs the 22 exit checks and all 63 U16 cases. The guest re-signs
  each build with `ararat-test-sign` (Screen Recording is granted to that identity) and launches
  through `disclaim` so TCC attributes capture to Ararat, not sshd. 92/92 pass on main.
- Phase 3 U18 done (86badef): every split shape renders (N panes, nested, free ratios, 240 pt minimum,
  frozen divider drag), live pages move between windows without reload, a failed partial handoff
  cancels the close. Full VM suite passes: 63 U16 cases (rater `u16-coverage.jq`; `u16_complete`
  stays false), 22 exit checks, `split` (incl. clipped panes during drag), `transfer`, `transfer-ext`.
  Unverified: drag dropped frames and presented-frame timestamps (`--ararat-measure=split` not run;
  the VM is not representative and the host is the owner's), real 30 s recovery/orphan drain,
  the extension `chrome.tabs.move` path (`transfer-ext` uses `TabListInterface`).
- Phase 3 U19 rehearsal done on branch `practice-rebase-158` (5967411, not on main) and root
  `~/chromium-build-next`: 158.0.8127.18 builds, smoke passes, the VM suite passes (63 U16, 22 exit checks,
  split, transfer, transfer-ext). Five generic patches are hand-ported (ungoogled had no 158). Measurements in
  architecture §4.7 (6f17c17). **Open for the owner: make 158 the pin or not** (conditions in §4.9; review
  Low: the new `--google-base-suggestion-url` switch stays live). Discarding = deleting that root and branch.
- screenfix (67db1bc): the U9-U12 screen checks (quit, links, profiles, prompts) pass in the VM; quit checks
  print JSON before teardown and name failed conditions; the window calls
  `TearDownPreBrowserWindowDestruction()` first (latent use-after-free on 157, crash on 158). All 92 VM runs
  pass with exit 0.
- VM runner reboots `ararat-test` before each run: after ~10 h its paravirtual GPU wedges the GPU process at
  exit (teardown watchdog, exit 2) and checks slow down; a fresh guest runs the full suite in minutes.
  `exit.sh` passes `TOOLCHAINS` because xcrun stopped resolving the installed Metal toolchain (2026-11-10).
- vmkeys (d46224a): a late selection report no longer selects a tab outside the shown space (core
  re-activates the selected tab); keyboard checks wait for their own selection to apply.
- focusnone (a3cafc3): extensions get `windows.onFocusChanged(WINDOW_ID_NONE)` when Ararat loses focus.
- Phase 3 U16 checks pass (8229e80): all 63 U16 coverage cases (C1/C2, default/RTL,
  hidden/screen) pass on one host build, with the 22 exit checks (`design/exitchecks.sh`,
  each with its fixture), `cargo test` and 368 Swift tests. Running them exposed and fixed
  shifted core shortcuts, Chrome accelerator collisions on redispatch, app-menu Settings,
  C2 find-bar stacking, beforeunload-cancel state and find-command state. Acceptance stays
  open for the reasons architecture lists. Screen checks on the host fail whenever another
  app comes to the front; a test VM `ararat-test` (Lume, macOS 26.4, auto-login, bundle
  shared read-only, runner `design/vm-u16matrix.sh`) exists, but there ⌘S with the page
  focused does not toggle the sidebar (phase 404), so the VM is not yet a substitute.
  Follow-ups: that macOS 26 difference; unloaded-only cross-profile space; extension
  focus-none on app hide; C2 find re-stack on tab switch; one unidentified `cargo test`
  timing flake.
- Phase 3 U15 done: tab and browser fullscreen use the native window, with sidebar
  behavior and exclusive access integrated into the host. Hidden fullscreen checks pass
  under C1 and C2. The unlocked screen check passed native entry, Escape, the menu,
  edge reveal, the green button and focused Control-Command-F; its exit gate waits for
  native exit and engine transition completion. Engine build, GN checks, Rust tests and
  346 Swift tests passed. Hidden DevTools C1 first reported a front-app change, then
  passed unchanged on rerun; the cause of that first observation remains unknown.
- Phase 3 U14 done: extension actions are listed in the sidebar header and open Chrome's real
  action popup; `chrome.action.openPopup()` uses the same host and anchor. Extension-created app
  popups use our page-only host. Hidden extension checks and the wide floating-menu screen check
  pass; the API-opened popup's own on-screen placement remains unverified. The U9-U12 screen checks pass
  on main (see the screenfix entry).
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

- Phase 4 (goal: finish the UI to the approved U20 mock; units on main, not pushed):
  - U20: the owner approved the mock (canvas 51, 2026-11-11); decisions in §7 "UI mock decisions" and §14 (3eb6cf2, a9e9cf8).
  - U21 favourites and folders (75de575..7767179): reorder, drag, collapse, the favourites grid; checks `organize` and `screen-organize`. VM suite 94 of 94. Open: KeyBindingsModel.apply still writes shifted letters in the form AppKit never matches (review S1), fixed in U23.
  - U24 part 1, the Look controls (36dc9e3..4793bdc): Transparency wave slider with the Liquid Glass socket past 100 % (detent, haptic, socket only from 100 %), Grain knob 0–100 % in 5 % steps, … menu with Use for All Spaces and Reset Look, grain opacity = grain, default grain 5 %. Checks `look` and `screen-look` (19 phases; the popover opens from Settings until U25 adds the space menu's Edit Look…). The VM cannot read SwiftUI's AX tree in process, so the controls' VoiceOver behaviour is reviewed by reading only; a VoiceOver pass is owner work. keyboard-screen failed twice at phase 405 on 4793bdc and passed on two re-runs of the same bundle: a VM flake, not a code fault (diagnostics on scratch/u24-diag-ref, not merged).
  - U24 part 2 pass A, grain and the look's fills (dea16c3..): the grain layer is the mock's field — white specks, alpha clamp(1.4·N − 0.35) of a two-octave value noise on 1.2 pt cells in one 120 pt tile that wraps (`LookGrainTile`, 120 px and 240 px representations), drawn at opacity = the stored grain, so the colour still shows through at 100 % and the grain never darkens. The dock's open cell and the URL field's resting fill take the mock's white overlay (55 % light, 10 % dark; hover and pressed from the C-UrlField board, 82/40 % and 14/6 %), and the Library keeps the accent fill. `screen-look` gains four grain phases (0/5/50/100 % on a fixed Slate probe written through the popover editor's commit path) that capture the window and hold the flat-patch sd, chroma and mean to the mock's rule calibrated by the run's own grain-0 capture (grain_0_flat, grain_5, grain_50, grain_100, grain_100_keeps_colour, grain_never_darkens, grain_linear), with the numbers in the diagnostics. The band mapping and the estimator are unit tested on a synthetic capture. `cargo test --workspace`, `build-core.sh`, `swift build` and `swift test` pass; the full suite passes serially (486 tests) — under parallel load the two long SpaceScroll timing tests fail, as on main. Pass B (the polar picker and chip page 2 as analogous 40°) follows in the same worktree. Owner's open item: the per-percent grain strength (one gain, now 1, on the tile's alpha) is tuned on the real app.
  - U24 part 2 pass B, the polar picker (62880c0..83f4732) and its first VM round: one to three handles on one shared radius turn as one group, a press with no movement only selects, the radius comes from the pointer, the sidebar previews while the button is down and the look is written once on release; chip page 2 applies the analogous 40° harmony. Conditions `picker_write`, `picker_input`, `picker_preview`, `picker_one_write` run in `look` and `screen-look`. The VM round found four check faults and no product fault: (1) `screen-look`'s grain band measured the Look editor's popover — it is a child window of the browser window, so the window's capture composites it over the sidebar and its flat background (mean 220, chroma 5) won the estimator's modal patch, which made both grain steps report the same numbers; the capture now hides the editor's window for its one screenshot, `grain_0_flat` requires the band to be the probe's Slate (it used to pass on a white band), and a band that is not the look is retried for 20 ticks and then named with its numbers. (2) `picker_preview` read `probe.editing` after it had posted the release, which always clears it. (3) phase 23 counted its own journal row into the drag's "no write" baseline; it now reads the count before its write and waits for exactly one row. (4) The VM's window captures leave the bottom ~70 px of the window uninitialised (noise), which the estimator ignores. Posted NSEvents do reach the SwiftUI DragGesture (the drag lands the exact hue and radius), so the real-event path stays.
  - U23 the command bar (8c418b2..e0638cf): the typed row first and run by Return, then open tabs, history (a thin HistoryService query) and commands, one best command promoted; no inline completion and no archive rows; the shown space's five recent tabs when empty; ⌃Tab / ⌃⇧Tab switcher; Force Reload; the URL field opens Edit URL; shifted shortcuts written one way (S1). Checks `commandbar` and `screen-commandbar`; VM suite 98 of 98. A private window cannot open the bar yet (it is a popup host); the private rule is tested at the core/FFI level until the private window slice.
  - U22 dock and window state (83116a7..4b13952): dock cells as letters or dots below a 22 pt share, 24 pt cells with the accent fill on the open space and the open Library following the page offset, the space menu on dock cells (rename in place, Edit Look… from the cell), refused-drop dim and pointer, Reduce Motion for the floating sidebar, the inactive window without tint, the minimum window width. Checks `dock` and `screen-dock`; VM suite passed (the screen variant needed three check fixes for coarse VM frames and a run-loop re-entry during screencapture).
  - U26a error and crashed pages (96bcb07..): our page for DNS, offline and connection failures, Chromium's certificate interstitial with a layout patch, Reload and Archive Tab or Close Tab on crashed tabs, and the download confirmation instead of a crash when the last private window closes. Checks `download-close`, `errorpages` and `screen-errorpages`; VM suite 103/103. Not verified: a real expired-certificate interstitial, VoiceOver and keyboard on the overlay.
  - U26b page dialogs (1c0e3a6..): a modal host per tab pane, the 340 pt permission sheet with our button row and a dimmed pane, Esc without remembering and no default button, Chromium's web-modal queue and its per-kind drop rules, a split pane's prompt waiting until the pane is active. Checks `permissions`, `dialogs`, `screen-dialogs` (also `+c2` on the shared compositor); VM suite passed. Found for U25d: moving one split member to another window leaves it in the split layout there.
  - U26c downloads (0cf7731..): Chromium's download manager observed per profile with actions through its download commands, the Library button's progress ring, the hover/click list with Open Library, the Library Downloads page, the icon flight, private downloads saved to the regular download folder without asking. Checks `downloads` and `screen-downloads`; VM suite 107/107. Also: the transfer check now waits for its snapshot (u26x).
  - U26d part 1 toasts and history banner (c9e1a04..): the per-window toast host, Link copied from every Copy Link, the per-profile history-failure banner with Retry and Dismiss. Fixed: a new window of a non-first profile drew the first space until the next snapshot. Checks `toasts` and `screen-toasts`; VM suite 109/109. Part 2 (Tabs cleared with Undo) follows U25b.
  - U25b rows, folders, Today and the space name row (2527e81..a256b66): the core carries the pinned-section state (device only), the New Tab row setting and clear_today in one transaction; the space name row with chevron, … and the space menu; Archive Tab / Close Tab words on rows and ⌘W; unread dots; folders with a "No tabs" line; Today's divider and Clear. The holder rule keeps the path to the current pin visible under a collapsed section, and selection ignores collapse. Spinner, speaker and mute are part 3 (u25b-3.md). The merge of main once dropped a screen-argument line (fixed in a256b66).
  - U26d part 2 Tabs cleared with Undo (2c9fdb5): core undo_clear_today(space, batch) reverses one Clear in one transaction (order kept, rows unloaded, splits whole, selection back, changed rows skipped); the toast in the Clear's window for 5 s and the Edit menu's Undo Clear Tabs while the batch lives its own 5 s; no shortcut, ⌘Z stays the page's. Today cannot hold folders under the current move rules.
  - U26f passes 1-2 private boundary (099014d..dc0dcd4): off_the_record on every transaction and tab, rejected when missing or mismatched; a separate in-memory private workspace with one admission policy (close/archive/Clear remove; import, settings, folders, pins, favourites, restore and foreign moves rejected). Pass 3 (private window host and sidebar, implementation-2) and pass 4 (integration checks) remain; decisions in design-u26f-decisions.md.
  - U25b part 3 loading and audio on rows (c86fb0e..30b9522): the strip carries loading, audible, muted and canGoForward with a host mute command (SetTabAudioMuted, kept across navigation); rows show a spinner and a speaker that mutes. Metadata-only changes emit no selection; a closing window admits no selection or non-empty strip; identical in-flight selections coalesce (the matrix check joins the in-flight command). The matrix traces from 8708e43 stay.
  - U26e site controls and extension actions (3f07bce..501425b): PageInfo-backed site state, region and full-page capture to the clipboard, the certificate panel, the red dot (this tab refused, or a site-specific Block); pinned actions from Chrome's pin prefs in the URL field or the overflow row, badges per focused tab, Pin/Unpin, Manage Extension and Remove…. The test HTTPS fixture imports its identity in memory only. Suite extras: site-controls, screen-site-controls, ext-actions@windows, screen-ext-actions@windows, relaunch-pins@windows. The full-page capture's readback limit (16384 px) is provisional; fixes after review 5 were checked in the VM, not re-reviewed.
  - U25a pass 1 sidebar header (ded75ff..02862a2): the sidebar button from 232 pt, Back, Forward, Reload/Stop from 200 pt, one … menu (Reload, Force Reload, Find in Page… / Clear Cache, Clear Cookies / Toggle Sidebar / Zoom In, Zoom Out / Print…, Settings…), keycap tooltips and the shared pressed look, all acting on the focused pane through a whitelisted host command runner. Clear Cookies takes the registrable domain (the host for an IP or internal name), Clear Cache the origin. The phase 3 Extensions button is gone; screen-extensions opens the in-field action first. Pass 2 (URL field) next. A busy host (load ~20 from another project) made timing checks fail; run the suite when the host is quiet.
  - U25c split focus (4165fef..ca55770): the 2 pt ring above the page inside the focused pane, click focus, Focus Next/Previous Pane ⌥⌘→/⌥⌘← as core commands (Chrome's Select Next/Previous Tab mapped to them), the URL field on the focused pane, 10 pt between panes, the split row as segments. The segment menu and drag-to-split are U25d. screen-dock fails about half the time on every branch (wheel_mid, capture_mid at phase 9): a flaky check to fix, not a unit regression.
  - U26f passes 3-4 private window (77b0d61..a994322): a full host per off-the-record Browser on one shared in-memory workspace per OTR Profile*, same-profile strip routing, the window closing with its last tab, private downloads to the regular folder with a released list, the dark window with the mask; checks private-window, private-isolation, private-downloads, private-durability (clean and kill, no disk hits). relaunch-pins fails on this branch as on others: a race fixed in U25d (Runtime.profilePinned).
  - U25d split commands (15475a2..37a2b7c): core add_split_pane, move_pane, separate_pane, convert_split and make-split-from-two-rows; the segment menu with icons, drag-to-split with the drop indicator joining a shown split without nesting, a lone pane in a second window taken back on key change, the vertical split's first pane on top; checks split-commands, screen-split-commands. Also fixed: the relaunch-pins race (Runtime.profilePinned) and, with U26f merged, a private window stuck with no selection after its first adoption (core live.rs).
  - U25a pass 2 URL field (1079768..aa64a08): URLFieldContent (host, failed URL's host, file name, data:, placeholder for blank/new tab and no tab, gear + full URL for internal pages), the long host fading at its start, Copy Link and site controls 24 pt with radius 6 and their states, 16 pt action icons, wrapping action rows, the private mask in the field with Private in the space row, 8 pt text insets; checks urlfield, screen-urlfield; ext-actions now loads three fixtures (windows, urlfield-one, urlfield-two). Open: the field's context menu (mock board C-UrlField, not in the decision log).
  - U24 part 2 grain and picker (dea16c3..9024a9a): the grain is the mock's white specks (alpha clamp(1.4N-0.35), two-octave noise, 1.2 pt cells, 120 pt tile, opacity grain/100); measured in the VM on the Slate probe at 0/5/50/100 %: mean 38.7/42.5/76.3/113.3, sd 0.0/1.6/17.0/33.4, chroma 89 -> 58 (the mock: 39/43/77/115, 0/1.7/17.3/34.6). The dock's open cell and the URL field take the F boards' white 55 % light / 10 % dark (the F boards supersede the A/C boards). The Look picker is polar (one to three handles on one radius turning together, 24/32 pt handles, an 8 pt dot lattice); chips keep the handle count and apply page 1 split / page 2 analogous 40 deg. Open for the owner: the per-percent grain strength on the real app, the White chip reading pale pink (fixed saturation 0.65), a VoiceOver pass on the picker.
  - U27a settings frame, U27c scroll direction, U27d Appearance part 1 (a4cf662..1906264): a pane registry showing only built panes, the grouped card, search with the first result selected, arrows and Return; Spaces: Scroll sideways Natural (today's behaviour) / Reversed (inverts at the end of the paging pipeline); Appearance: New Tab row and Tooltips switches (synced core settings) and a Look link; checks screen-settings-frame, -search, -tabs, -shortcuts, -air-traffic, -spaces, -appearance. Open for the owner: whether Natural should follow macOS's natural-scrolling switch (watch Arc on the trackball). split-commands phase 26 fails on about half the runs: being traced on fix/split-commands-p26.
  - U27h Little Window (64fc231..78cb929 on feat/u27h-little-window): the page-only popup with our 48 pt bar (profile menu, centred address, Copy Link, Extensions, Open in ⌘O with the space menu, ⌘L command bar at 504 pt), the per-device frame record and the live handoff into a space's Today; checks little-window, screen-little-window. Open: after a profile switch, Manage on the Little Window's extensions opens the origin window's profile's page (guard on origin.host?.profileDirectory() == profileName if it matters); two overlapping profile switches could leave two windows; a refused reopen is silent (the old window stays); a typed data: URL searches (the shared classifier, kept); Manage has no VM condition (Swift regression only). page-only-popup phase 42 fails now and then (3 of 31 full suites).
  - U27b Clear Cache / Clear Cookies (4ff5610..d7e76ff): core commands in the command bar, the Ararat Commands menu and the header's … menu; Cache clears the current origin, Cookies the registrable domain and its subdomains (the host itself for an IP or an internal name); both disabled without an http(s) page; no default key. Full suite 144/144.
  - U27i Little Window settings (47adf4f..50b2c46): the pane (Air Traffic Control link, Open-in default, close after opening, remember size and place, the global shortcut recorder, default ⌥⌘N), synced Open-in and close-after (D8), the per-device remember switch, a Carbon hot key outside the key-binding table that reports a key another registrar holds; with close-after off the Little Window stays as an empty start instead of reloading the page (design's M3 choice: a one-time link must not load twice). Check screen-settings-little-window; full suite 144/145 (page-only-popup phase 42, the known intermittent). Open: whether Carbon's exclusive answer covers another process is not verified on hardware.
  - U27b2 (e4954c7): the Shortcuts pane refuses the global Little Window key, read from the device record at each write; changing the global key frees the old one. Open (review L1): Reset, Reset All or sync can put the global key back into the table; the full fix is a Conflicting display in the Shortcuts rows. Full suite 142/145, the three failures (quit-multiple phase 19, close-multiple timeout, screen-dock) passed on a rerun and have failed the same way before.
  - U27j onboarding and Arc import screens (screens only): a 640 × 480 window walking welcome, source, what to import, default browser, progress, done with the report and the two error screens; the four Arc files arrive as injected strings and the core's string import writes the store at the check's `--ararat-db` (no Arc path API, no Keychain, no filesystem read); the showcase fixture produces 3 spaces · 21 pinned tabs · 5 folders · 8 favourites · 3 looks · 6 routes with 2 peeked folders, 2 differing folder states, 1 skipped profile route and 3 key bindings; the default-browser button goes through an injected setter; the entry (File › Import from Arc… and the command bar row) exists only under a check (O7). Checks onboarding, screen-onboarding (registered in the engine's launch guard with the scratch database). The done line counts the import's own spaces/tabs/folders/favourites/looks from the core ImportReport, not the store's totals. Open: the shipping entry waits for the owner's verification of the real importer; 3a and the sign-in/password rows stay out (§14).
  - U27k Appearance part 2, Theme: one synced `theme` field in the core `settings` record (System by default, Light and Dark), the Appearance pane's Theme card above the Look link with System / Light / Dark, and `NSApp.appearance` set to nil / aqua / darkAqua so every browser window, the settings window, popovers, menus and the command bar follow together; a space's Look still colours only the sidebar and its Auto text follows the resolved appearance. The theme is read before the first window exists and re-applied at each window start and at a space switch, so a second Mac (or a reopen) shows the stored choice; private windows keep the dark appearance they force. `screen-settings-appearance` gains `theme_dark`, `theme_light`, `theme_page`, `theme_reopen`, `theme_system` and three captures; the page condition reads a real page's `prefers-color-scheme`, and Chromium follows the app's theme live (it is not assumed and no engine patch was needed). The page's own tab comes through the command bar's URL path, because the engine's check-only navigation gate does not name settings screens. VM run on design's Dev engine build: all 18 conditions pass (15 ticks).
  - U27w Settings › Websites (engine-backed): seven per-permission defaults in one synced core record applied to every regular profile (menus offer only the values Chromium accepts as a default: Ask/Block for Camera and Microphone, Allow/Block for Pop-ups and Sound, all three for Location, Notifications and Automatic downloads; the core refuses the rest, and a stored unaccepted value stops startup with no data loss), sites with their own settings from Chromium per origin and profile, a site page with per-kind menus, Reset permissions and Clear cookies and site data (one BrowsingDataRemover task by registrable domain), and All Site Settings… in the site-controls popover. Checks: screen-settings-websites (fake media device for this check only). Carried to U27x: a nil check on the site-data clear completion and one test-comment label.
  - U27x Settings › Extensions (engine-backed): a profile chooser over the regular profiles (an unloaded profile is loaded on demand), the list chrome://extensions shows for that profile (external-pref installs included, Chromium's rules for which items may be disabled or removed), an enable switch, the site-access summary and a … menu (On all sites / On click, Pin/Unpin from Sidebar, Manage Extension, Remove…), Review… through Chromium's re-enable prompt, live refresh from the registry and the toolbar model. Remove… in the pane is our AppKit sheet on Settings (Settings has no Views host for Chromium's dialog) calling ExtensionRegistrar::UninstallExtension, so it has no report-abuse box; the URL field's menu keeps Chromium's dialog. Unpacked installs follow Chromium's developer-mode rule; no Developer mode switch, Load unpacked, Add from Arc or Find more. Check: screen-settings-extensions (two profiles, fixture install with developer mode on in the scratch profile only, the Views accept seam for the re-enable prompt).
  - U27p Settings › Privacy (engine-backed): one synced core record for Third-party cookies (Block by default / Allow), Ask sites not to sell or share my data (on by default; GPC) and Keep history for (One week, One month, Three months, One year, Forever; default One year), pushed into every regular profile at every window start and after every write. Block/Allow writes Chromium's `profile.cookie_controls_mode` (block third party / off); GPC writes `universal_optout.enabled` and Chromium 157's `Sec-GPC` header and `navigator.globalPrivacyControl` follow from `UniversalOptOut`, `UniversalOptOutSettings` and `GlobalPrivacyControlApi`, enabled by AraratMain before Chrome starts (no patch). The history retention replaces the fixed 90 days in the expiry loop (`history-retention.patch`): shortening it deletes older visits at the next pass (30 s) with no relaunch, Forever never expires, and a failed deletion reaches the U26d banner. Clear browsing data… opens a sheet over Settings for the profile of the window that opened Settings (Last hour / Last 24 hours / Last 7 days / Last 4 weeks / All time; History, Cookies and other site data, Cached images and files) and runs one BrowsingDataRemover task. No Protection card and no disabled rows: the blocker and Safe Browsing wait for §14. Check: screen-settings-privacy.
  - In progress: U27 (settings panes, the Little Window, onboarding and import screens, in sub-units U27a–k and the engine-backed panes). Design checks for the mock's open items are in §14.

## Next

1. Owner decisions open (§14): favourites per space or per profile, content blocker, page translation, the Natural scroll direction on the trackball, a date to verify Arc sign-in import, favicon drawing. Owner work: a VoiceOver pass on the Look popover, and the grain's strength on the real app (one gain on the tile's alpha, now 1, U24 part 2).
2. Measure on Arc: how long a dragged tab rests on a collapsed folder before it opens (now 0.6 s, ours, `folderHoverDelay`).
3. Phase 4 (UI to the approved mock): U22–U27 in the order of the design session's goal; Phase 3 is complete except the owner's 158 pin decision (U19). The team runs on herdr-agent-team (`~/.config/herdr-agent-team/ararat/`). Seats never write to `~/chromium-build` (Codex's sandbox refuses it): design runs apply, gen, build and the checks at each unit's exit. Run `macos/scripts/build-core.sh` in the plain devshell; Xcode's environment (README's `xc`) is for `swift` only. A new worktree needs `direnv allow` before a seat uses it. Engine scripts need a clean PATH (no `/nix`) and run under `/bin/bash` 3.2: `env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash engine/scripts/<cmd>`. Every engine launch passes `--use-mock-keychain`.

## Known loose ends

- `macos/scripts/build-core.sh` exits non-zero in a checkout whose path contains spaces
  (uniffi step, "No such file or directory"); not fixed yet.
- `macos/Generated/` is a stale leftover (gitignored); delete when allowed.
- Synthetic fixture exists twice (`core/ararat-core/tests/fixtures/`, `macos/Sources/AraratHarness/Fixtures/`).
- Fresh clone must run `macos/scripts/build-core.sh` before `swift build`.
- Inside the devshell `swift` and `swiftc` are hidden by nix's apple-sdk; use the README's `xc`.
  `mkShellNoCC` was tried to avoid this and breaks Rust linking (`-liconv`).
- Open owner decisions: architecture §14 (per-space settings mock first, favorites per profile or per space, DRM, content blocker, Safe Browsing source, sync hosting).
