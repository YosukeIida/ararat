# Ararat architecture

Status: draft 2, 2026-10-30. Japanese translation: `architecture.ja.md`. Review history: `reviews/`.

This document fixes the technology choices, the layers, what is tightly coupled and what is isolated, how state and sync work, and the roadmap. It builds on three research notes:

- `research/ardia-ledger.md`: design decisions and rewrites in Ardia (Chromium fork, React Native UI).
- `research/cra-ledger.md`: design decisions in Cra (Swift + CEF) and the CEF workarounds it needed.
- `research/arc-dia-components.md`: the component inventory, data formats and Chromium seams of Arc and Dia, collected from published reverse-engineering.

References like "Ardia ledger 1.4" point to sections of those notes.

## 1. Goal and constraints

Ararat is a browser with Arc's workflow (spaces, pinned and Today tabs, favorites, folders, archive, command bar, Little Arc, Air Traffic Control, split view) and Yab's vertical-tab behaviour, on Chromium, with Chrome extensions.

Constraints, set by the owner:

- macOS first, with a native UI in Swift.
- The engine is a Chromium fork, with our own layer inside the Chromium tree.
- Windows, Linux and iPhone come later. The structure must not need a rewrite to add them.
- The cross-platform core is Rust.
- Sync runs through our own server and never requires an account or a login.
- Licence: GPL-3.0.
- Arc, Dia and Yab are closed source. We use published analyses and static analysis their terms allow, and copy no code or assets. Ardia's code (GPL-3.0) may be reused with its source noted.

## 2. Decisions at a glance

| Area | Decision | Why | Section |
|---|---|---|---|
| Engine embedding | Chromium fork with our layer `//ararat/core` linked into `//chrome:chrome_framework` (the ArcCore / ArdiaCore model). No CEF at any stage | CEF fights the window model, tab creation and the run loop; 77% of Ardia's engine patch lines existed only to pass Chrome objects through CEF (Ardia ledger 1.1). Cra needed about 30 CEF workarounds (Cra ledger 3.1) | 4 |
| Engine base | Provisional: Chromium plus the Helium patch set. Decided in phase 2 against Chromium plus ungoogled-chromium | Helium brings de-googling, codecs and multi-platform packaging and matches GPL-3.0, but its net maintenance benefit is unproven (Ardia ledger 1.2 marks the reason for its own move as inferred) | 4.2 |
| Engine ↔ app API | A handwritten, typed Objective-C API exported from the framework, called from Swift | Swift imports Objective-C with no generated glue. Dia also exposes Objective-C to Swift, but generates its 146 classes from mojom | 4.4 |
| Run loop | Chromium owns the process and the main loop; the AppKit UI starts inside it | Removes the external-pump bugs (Ardia ledger 1.1) | 4.5 |
| Window model | One Views-backed `NSWindow` per app window, holding one Chrome `Browser` per profile shown in it. Tab views go into our view tree | Chrome's bubbles and dialogs attach to the window; profile switching is a view swap; overlays are ordinary subviews | 4.6 |
| State ownership | The Rust core owns the workspace and the live-tab coordinator; Chrome's `TabStripModel` owns live tabs; they meet through epoch-qualified, revisioned transactions | One writer per fact (Ardia ledger 1.4); the coordinator in Rust is reused on every platform | 5 |
| Core | Rust crate `ararat-core`, SQLite storage, UniFFI bindings for Swift, a C ABI for C++ | Same core on macOS, Windows, Linux and iPhone | 6 |
| macOS UI | AppKit for everything that moves; SwiftUI for settings and onboarding | Cra measured 1900 → 440 ms main-thread time on a space swipe after moving from SwiftUI to AppKit (Cra ledger 12) | 7 |
| Sync | End-to-end encrypted, account-free; our server is a blind relay of authenticated, append-only blobs; devices join with a recovery phrase or a PAKE-authenticated pairing code | "Own server, no login"; works where no Chromium sync engine or shared folder exists (iPhone, Windows) | 8 |
| Process | Every unit goes scope (Opus 5.5) → implement (Codex gpt-6.1-sol) → review (Opus 5.5); hard edge-case bugs start from Codex | Owner's rule (`AGENTS.md`) | 13 |

## 3. Layers and repository layout

```
ararat/
  core/            Rust workspace: ararat-core (model, rules, coordinator, import, sync client), ararat-ffi (UniFFI + C ABI)
  server/          Rust: the sync relay (phase 8)
  engine/
    build-inputs.toml  the pinned build identity (4.7)
    ararat/        our in-tree layer, copied to //ararat/core
    chrome/        our files under //chrome/browser/ararat
    patches/       series + patches against the base
    apply.sh       copies our code in, applies hooks (idempotent, --check)
  macos/           one SwiftPM package
    Sources/ararat_ffiFFI/  C module for the core's UniFFI header; links the Rust static library
    Sources/AraratKit/      Swift adapter over the core bindings (generated) and, later, the engine API
    Sources/AraratUI/       AppKit + SwiftUI components (library)
    Sources/AraratHarness/  UI harness: real components on real core data, a placeholder where the page goes
    scripts/build-core.sh   builds the core and regenerates the bindings
    App/                    the browser app (Xcode project, from phase 3)
  docs/
```

The harness is a permanent development tool, not a stand-in for the app, so UI work never waits for a Chromium build. Cra's command file and Ardia's dev harness play the same role.

### Dependency directions

```
macOS App ──► AraratUI ──► AraratKit ──► ararat-ffi ──► ararat-core
                               │
                               └──► engine ObjC API (//ararat/core) ──► Chromium //chrome
```

- `ararat-core` depends on nothing platform-specific and never calls the engine or the UI. It decides; adapters execute.
- `AraratUI` never calls the engine directly. Only `AraratKit` holds engine and core handles.
- `AraratKit` is a thin adapter: it forwards engine transactions to the core's coordinator and executes the engine commands the coordinator returns. Rules live in the core, so Windows and Linux reimplement only the adapter.
- On macOS the engine does not link the core; the adapter bridges them inside the same browser process. On Windows and Linux the Views UI links the core through its C ABI (section 10).
- Chrome's files know only our hook header (4.3), never our classes.

## 4. Engine

### 4.1 What is tightly coupled and what is isolated

| Part | Coupling | Where | Rule |
|---|---|---|---|
| Our `BrowserWindow`, `BrowserDelegate`, UI seam implementations, session persistence, ObjC API | Tight, inside the tree | `//ararat/core`, `//chrome/browser/ararat` | New files only. Built with Chrome's GN rules |
| Edits to Chrome's own files | Minimal, isolated as hooks | `engine/patches/` | Each edit is a function-pointer hook declared in one shared header; one concern per patch |
| Base patch set (Helium if chosen) | Imported, guarded | `engine/patches/series` | A skip list plus guards check that skipped patches stay out and that nothing touches what the skips protect |
| Rust core, sync, import | Isolated | `core/` | No Chromium types |
| AppKit UI | Isolated | `macos/` | Talks to the engine only through `AraratKit` |

### 4.2 Base and patch management

- The clean Chromium revision and the base patch set are pinned separately in `engine/build-inputs.toml`.
- Helium is provisional. Phase 2 decides between Chromium + Helium and Chromium + ungoogled-chromium using: a pinned inventory of every base patch marked kept, skipped or counter-patched, with its security consequence (for example, Helium's build flags disable Safe Browsing); and one measured rebase.
- If Helium is kept, skip what fights our choices, following Ardia: password manager removal, keychain renaming, Sparkle integration, crash dialog, onboarding, services pages, !bangs, the Web Store proxy (Ardia ledger 1.2).
- `engine/patches/series` is the only source of patch order. Patch names state their concern; no ordering prefixes.
- `series check` applies the whole series to the pinned base in a scratch tree with no fuzz and compares bytes with the build tree. It runs before every engine release.
- Large edits to Chrome files are rewritten as a new class plus a small hook (Ardia rewrote a 1,012-line PiP patch this way).
- The metric is the number of hunks inside Chrome's files, not the number of patches.

### 4.3 Hooks

Hooks are `g_ararat_*` function pointers declared in `ararat_hooks.h`, included by both Chrome's patched file and our layer. Unset, Chrome behaves as stock. A signature change fails at compile time.

### 4.4 Engine ↔ app API

- The framework exports handwritten Objective-C classes from `//ararat/core` (for example `ARWindowHost`, `ARTab`, `ARProfile`, `ARExtensions`, `ARDownloads`, `ARAutocomplete`, `ARPasswords`). Swift imports them through the framework's module map.
- Contract for every class: main-thread affinity (calls from other threads are a programming error and abort in debug builds); objects that wrap Chrome objects are invalidated when the Chrome object dies and every call on an invalidated object is a no-op returning an error; callbacks carry a cancellation token and never fire after invalidation; Swift owns wrappers, the engine owns Chrome objects.
- Services the UI needs (passwords, autofill, extensions, zoom, search engines, history, bookmarks, downloads) are called directly on Chrome's services from our layer. We never script `chrome://` WebUI pages (Ardia ledger 1.4).
- App and engine ship together. There are no compatibility branches: one API version check at startup, a mismatch aborts.

### 4.5 Process and run loop

- `main` calls our entry point, which calls `ChromeMain` with our `ChromeMainDelegate` subclass. `NSApp` is Chrome's `BrowserCrApplication`. Nothing touches `NSApp` before Chromium starts, and the AppKit UI is created from a Chromium startup callback.
- We replace Chrome's `AppController` with our own owner of quit, Dock and logout events, implementing cancellable close and quit (beforeunload, download confirmation) and a keep-alive when no window is open (Ardia ledger 1.1).

### 4.6 Windows, tabs and the duties we take over from Chrome's UI

**Windows and profiles.**

- One app window is one Views-backed `NSWindow` (`NativeWidgetMacNSWindow`), so Chrome's bubbles, dialogs, menus and autofill dropdowns attach to it as child windows.
- Each profile shown in the window has its own Chrome `Browser` whose `BrowserWindow` is our object with no `BrowserView`, frame, tab strip or toolbar.
- Extension window semantics: each profile `Browser` is a separate extension window id. While the app is active, the `Browser` of the profile shown in the key window is the focused window; the `Browser` shown in each other app window is unfocused but not minimised, and hidden profiles' `Browser`s report unfocused and minimised-equivalent bounds. Deactivating the app unfocuses all of them. `currentWindow` for an extension's own context (popup, side panel, a tab's content script) is the `Browser` that context lives in; for a background context it is the focused `Browser`, or the last focused one while the app is inactive. With these rules `windows.getCurrent`, focus events and `tabs.query({active: true, currentWindow: true})` follow what the user sees. `windows.update({focused: true})` on a hidden profile's window switches the app window to that profile. The spike verifies this with two profiles in two app windows, focus moving between them, app deactivation, extension-created windows and an extension active in a hidden profile.
- Extension popup windows (`windows.create({type: "popup"})`) stay real popup windows (Cra ledger 10). Our internal helper windows are hidden from extensions (Ardia ledger 1.7). Profile `Browser`s are not internal: extensions see them.

**Tabs.**

- A tab's `WebContentsViewCocoa` goes into our view tree. Which compositor owns those views (per tab view, per profile, or shared per window) is a spike decision, because Ardia found that per-view compositors cost 1–2 refreshes on every tab switch and that changing later means a rendering rewrite (Ardia ledger 1.3, 1.6). The spike measures first-frame latency on switch, background-page activity, occlusion, resize, split panes and display changes for the candidates.
- New contents: renderer-created windows reach us through `AddNewContents` with an existing `WebContents` and its pending navigation state preserved; modified clicks and form targets may take other paths (`OpenURLFromTab`). Every creation path on the pinned revision is enumerated and tested separately: POST targets, `window.open` with and without features, ⌘-click, shift-click, opener relationships, blocked popups. Windows Chrome creates on its own (`chrome.windows.create`, incognito, undocked DevTools) are routed to us through a hook in the `Browser` constructor.
- One page, one place. A live page is shown in exactly one pane. When a second window or pane selects the same workspace tab, the window that becomes key takes the page and the other shows a blurred snapshot placeholder until it becomes key again (Arc's behaviour, Cra ledger 19). Within one window, the pane that takes focus takes the page and the other pane shows the placeholder; the split-pane spike covers this. Closing a window moves pages that another window still shows instead of reloading them (Cra ledger 20).
- Split panes: each pane hosts one tab; the focused pane's tab is Chrome's active tab for its `Browser`; other panes are visible but inactive. During a divider drag, page sizes are frozen and resized once on release (Cra ledger 21).

**Duties we take over from Chrome's UI.** Without `BrowserView`, every responsibility it carried needs an owner. The spike completes this matrix; the first entries:

| Duty | Owner |
|---|---|
| Permission prompts and their rejection | Seam implementation (host UI) |
| External protocol confirmation | Seam implementation |
| Device choosers (USB, HID, Bluetooth, serial), Cast | Seam implementation |
| Fullscreen and pointer-lock exit warnings | Seam implementation (`ExclusiveAccessContext`) |
| Extension action popup, install prompt, installed bubble, side panel | Seam implementation |
| Password and autofill bubbles | Seam implementation; autofill dropdown stays Chrome's child window |
| Find in page | Chrome's `FindTabHelper`, host UI |
| Keyboard dispatch between page and browser commands | Host, following Chrome's rules: page first, unhandled keys back to menus, reserved keys taken first (Cra ledger 11) |
| Focus handoff (⌘L, ⌘T then immediate paste) | Host, synchronous on the main thread (Ardia ledger 1.10) |
| Accessibility tree for the window | Host views plus Chrome's web accessibility |
| Downloads UI | Host (Chrome's bubble disabled) |
| Session persistence | Our layer (below) |

**Sessions.** Chrome's automatic window restore is disabled for our `Browser`s, but its persistence duty is not dropped: our layer serialises each tab's navigation stack, selected entry and session-storage namespace with Chrome's own session code, keyed by the core's stable item id. Retention: live tabs and unloaded workspace tabs keep their entry; archived tabs keep it for the archive's lifetime; recently closed tabs follow Chrome's limit. Restoring a tab hands the engine the core id, the engine rebuilds the `WebContents` with its history.

### 4.7 Build and artifact identity

- Builds live outside the repo in `~/chromium-build`. Incremental builds only during normal work.
- Ardia's figures: first build about 2–2.5 h on an M5 Pro, incremental about 7 min (compile plus ThinLTO relink), about 45 GB of disk. We measure ours on the Mac Studio in phase 2.
- One engine build at a time, under a lock.
- GN args live in one file: official build, ThinLTO, PGO, no DCHECK, stripped symbols, `proprietary_codecs=true`, `ffmpeg_branding="Chrome"`, our branding.
- `engine/build-inputs.toml` pins everything that determines the binary: Chromium commit, base patch set tag, hash of the resolved DEPS, GN args, Xcode and SDK versions, architecture. The engine artifact is keyed by the hash of that manifest plus the git tree of `engine/`. Published artifacts carry their SHA-256 and a provenance record.
- CI does not build the engine; it is built locally and published as a prerelease under that key.
- Corresponding Source for each release: the tag, `build-inputs.toml`, the patch series and a script that fetches the pinned upstream and reproduces the tree.

### 4.8 Security and data integrity from day one

- The Safe Storage keychain item name is fixed in the first build and never changed. The key is never silently recreated: create only for a provably new profile, otherwise retry and fail closed (Ardia ledger 1.8).
- Decrypted passwords are zeroed before free, in the engine and in the core.
- Child processes run in the macOS sandbox.
- Nothing writes into the app bundle; release checks re-verify the signature after a launch.
- The automation channel for tests is unreachable from web pages, and test-only switches work only in non-distribution builds with a scratch data directory (Cra ledger 33, Ardia ledger 1.8).
- WebRTC exposes no local IP: mDNS off, `default_public_interface_only` (Cra ledger 27).

### 4.9 Security maintenance

- A daily job detects new Chromium stable releases and new base-patch-set tags (Cra ledger 6).
- Patch-lag limits, counted from the upstream stable release: fixes for vulnerabilities exploited in the wild ship within 48 hours; other High and Critical fixes within 7 days.
- Security-only rebuilds on the same Chromium milestone are incremental and pre-authorised. Milestone bumps need a full build; whether they are pre-authorised is an owner decision (14).
- If the base patch set lags Chromium beyond the limit, we rebase onto the newer Chromium ourselves and carry the base patches.
- Daily use by anyone, including the owner, requires: a working update path (Sparkle) and a URL and download reputation check (Safe Browsing or a chosen equivalent, 14).

## 5. State ownership

### 5.1 Who writes what

| Fact | Owner | Notes |
|---|---|---|
| Spaces, pinned/Today membership, favorites, folders, split items, archive, per-window view state, Air Traffic Control rules, key bindings | Rust core | Arc's model shape (components note 3) |
| Which `WebContents` exists, in which `Browser`, order, active tab | Chrome `TabStripModel` | Chrome commits; the app is never asked first, because extension APIs read their result back in the same call (Ardia ledger 1.4) |
| Navigation stacks and session storage | Engine session persistence (4.6) | Keyed by core item id |
| History, bookmarks, favicons, closed tabs, zoom, downloads, passwords, autofill | Chrome services | Never duplicated in the core |

- Workspace tabs that are not loaded have no `WebContents`.
- The coordinator in the core issues live-tab commands with ids. The engine replies with transactions `{epoch, rev, cause, strips}`: `epoch` changes on every engine start; `rev` increases monotonically within an epoch; `cause` is our command id, our own engine call, or Chrome itself. One transaction never mixes causes. No echo windows, no "did we cause this" flags.
- Changes Chrome makes on its own (an extension moves a tab, the successor after a close) are diffed and applied to the workspace by the core's rules; the successor follows the core's rule (split continuity, skipping collapsed and unloaded tabs), not Chrome's choice. The successor is the most recently selected tab in that window, among the tabs of the space it shows, that is still open and visible (closing never pages the sidebar to another space; measured in Arc), as in Arc (measured 2026-11-01 with ⌘W and with AppleScript: closing went back through the selection history, not to a neighbour; `docs/research/arc-ardia-observed.md` section 7). With no such tab, the nearest visible open tab below the closed one in the same list, else above, else none (our fallback). A split member's successor is its split, and a split closes with its last open member. ⌘W on a pinned tab or a favorite unloads it, keeps its row, and moves to the successor the same way. The selection history is per window, local, and not synced.
- Tab switching shows the page natively first; no round trip through UI state is on the display path.

### 5.2 Crash consistency

- Every live tab has a stable core item id, stored in the engine's per-tab session data, so the mapping survives restarts.
- On start the engine reports a full snapshot for the new epoch; the coordinator reconciles it with the workspace. The workspace is the authority: each item records its lifecycle state (open, unloaded, closed, archived) in the same transaction as the change, and closes and archives are committed before the coordinator tells the engine. Tabs the workspace knows as open or unloaded but the engine does not are restored or marked unloaded. Engine tabs whose item is closed, archived or deleted are closed again, never adopted. Engine tabs with no item at all (created in the last uncommitted second before a crash) are adopted into Today. Command completions carry the epoch they were issued in and are dropped if it is not the current one.
- Crash-loss window: a workspace change is durable when its SQLite transaction commits, at most 1 second after the event (batched off the main thread) while storage works; during failed writes (next point) the window grows until a retry succeeds. A crash can lose at most that last second of workspace changes; it can never leave the workspace and the outgoing sync log inconsistent, because both are written in the same transaction.
- Disk full or a failed write keeps the in-memory state, retries with backoff and tells the user; it never truncates the database.
- Backups use the SQLite backup API, so the WAL is included.

### 5.3 Private browsing

Off-the-record profiles are a property in the engine contract: every transaction and tab carries it. The core keeps off-the-record workspace state in memory only and rejects, in one place, any durable write, archive entry, sync record or command-bar learning for it. Tests cover close, crash, archive and sync with private tabs open.

## 6. Rust core

### 6.1 Contents

- Workspace model: profile, space, container (favorites per profile or per space, 14), item (tab, folder, split), archive entry, window state.
- Tree representation: each item has one membership register `(parent id, fractional order key, HLC, previous parent id)`. Child lists are derived, never stored separately. Deterministic repair: a move that would create a cycle is resolved by keeping the move with the higher HLC timestamp and re-parenting the other item to its previous parent; items whose parent is missing go to their space's Today container, the space being found from the item's previous parent (kept in the register) or, failing that, the first space; an item whose move back to its previous parent still leaves a cycle goes to Today; delete wins over a concurrent edit unless the edit is a restore. Repair is a deterministic view over the merged registers: it never writes its result back into the registers that sync, so devices that receive the same moves in different orders compute the same tree. Only an import writes repaired registers, because the imported file is the origin of those registers. Tree-invariant tests (no cycles, every item reachable once) and delivery-order tests run on every merge test.
- Rules: Air Traffic Control matching exactly as measured on Arc (case, scheme and leading `www.` dropped; "Contains" also checks query and fragment; "Is equal to" compares host and path only; first match wins), auto-archive thresholds, the successor-tab rule, split layout math.
- Live-tab coordinator: applies engine transactions, issues commands, reconciles on start (5).
- Import: Arc (`StorableSidebar`, `StorableWindows`, `StorableArchiveItems`, `StorableKeyBindings`, `StorableLinkRouting`), later Dia, Chrome, Safari, Firefox. Import produces a neutral plan; Chromium data (passwords, cookies, history) is written through the engine into Chrome's stores.
- Command bar ranking over sources the engine supplies (Chromium's `AutocompleteController` results, open tabs, workspace items, commands).
- Sync client (8).

### 6.2 Storage

SQLite (WAL) for the workspace, archive and the sync journal. Writes run off the main thread. Cra's JSON files cost about 30 ms per write of a 2,000-item archive on the main thread before it moved writes off-main (Cra ledger 16); SQLite gives the transactions 5.2 needs.

Every record (space, item, favorites container) is one row `(kind, id, JSON body)`; spaces carry a fractional order key like items, so no list is stored. Each change is also appended to the journal table, in the same transaction. Rows of kinds this version does not know are kept untouched (8.3). The writer thread commits a batch at most 1 second after its first change, with `synchronous = FULL`.

### 6.3 Bindings

- `ararat-ffi` exposes the core through UniFFI (Swift on macOS and iPhone) and a C ABI (C++ in the Chromium tree for Windows and Linux).
- The core is synchronous and owns no threads except the storage writer and the sync worker. The Swift adapter calls it from one serial queue and publishes snapshots to the UI.
- Secrets cross the boundary as byte buffers that the core zeroises; they are never turned into Swift `String`s.

## 7. macOS UI

- AppKit for the sidebar, space paging, favorites grid, list rows, dock, command bar, Little window, window chrome and tooltips. Rows are layer-backed views reused by key; space paging moves layers only (Cra ledger 12, 4). Row list scrolling (Arc not measured; ours, from Cra's and Yab's recent fixes, `analysis/peers/2026-11-02-recent-updates.md` 2.2): only the row list scrolls, favorites and the header stay fixed, and pinned rows scroll with Today. 1 pt hairlines (Cra's Arc measurement: 5 % black light, 7 % white dark) show at the top while scrolled from the top and at the bottom while rows are hidden below, fading over 0.25 s. Selecting a row from a click, the keyboard or stdin, restoring one, landing on a space or creating one reveals the selected row by the least scroll that shows it whole, never centred, over 0.22 s with an ease-out cubic; a row already in view never moves the list, and background changes never reveal. Inserting or closing rows keeps the first visible row where it is (none at the top). The overlay scroller stays hidden until a gesture turns out vertical, so a horizontal space swipe flashes no knob; the scroller is the system's. Reduce Motion drops the reveal and fade animations.
- SwiftUI inside `NSHostingView` for settings and onboarding.
- Motion and size values come from Arc, measured on the owner's machine (`docs/research/arc-ardia-observed.md` sections 4–6). Floating sidebar: shows with a spring of response about 0.15 s and damping about 0.84 (5 pt inset), hides in about 90 ms, easing out (components note 5 gives 0.185 s and 0.77, which fit the measurement worse). Docked sidebar (⌘S): hides with an ease-out cubic of about 90 ms and shows with one of about 100 ms. Arc starts showing it about 560 ms after the key, a delay that was measured but not explained and is not copied. Closing a tab moves the rows below up with an ease-out cubic of about 120 ms; a closed last row fades in about 110 ms; opening a tab inserts it at the top of Today and moves the rows below down, which starts as fast as closing (the end of that motion was not tracked, so it uses the closing curve). Where these match Dia's published values (components note 5), that is noted in the research document; Dia's values are not used on their own.
- Sidebar layout uses Arc's measured dimensions (`docs/research/arc-sidebar-layout.md`): URL field 36 pt tall at 8 pt insets, favorite tiles 47 pt tall 8 pt apart, rows on a 41 pt pitch with a 36 pt selection fill, 16 pt favicons at x 18 with the title at x 44, nesting indent 16 pt; a nested row's selection and hover fill moves its left edge right by the same 16 pt per level and keeps its right edge. The sidebar has two forms, as in Arc: docked beside the page card, and floating over the page when hidden (the floating sidebar below), as a panel of the docked width inset 5 pt from the window's left and top edges with a 1 pt light border and continuous radius 11. The page card sits 10 pt inside the window's top, right and bottom edges, and 10 pt inside the left edge while the sidebar is hidden (measured in Arc). Its width is set by dragging its edge, following the pointer during the drag (not measured in Arc), per window, and a "reset width" command returns it to the default of 240 pt (owner's choice, 2026-10-31); as in Arc, the page card's left edge stays between 164 and 500 pt whatever the window's width, and dragging the pointer left of 81 pt from the window's left edge (about half the minimum; Arc kept 81 and hid at 80) hides the sidebar, which comes back at the minimum width (measured in Arc, `docs/research/arc-sidebar-layout.md`). Corners are continuous with radius 11 for the field, tiles and row fills; nested shapes take the concentric radius (container radius minus padding), as Apple's design guidance asks.
- Space switching by scrolling over the sidebar, Arc's behaviour as measured (`docs/research/arc-ardia-observed.md` section 5; the owner's choice, 2026-10-31). Events are classified by phase: an event with a scroll phase or a momentum phase belongs to a trackpad gesture; an event with neither (`phase == []` and `momentumPhase == []`) is wheel input. Trackpad: from `began` the sidebar follows the gesture by `scrollingDeltaX × 0.5`, with the neighbouring space one page away; a page is the sidebar's width (Arc measured about 180 pt with a sidebar about 178 pt wide; other widths were not measured, so tying the page to the width is our inference). Each page's contents are clipped to the sidebar's content area, so neighbouring contents sit 16 pt apart (the sidebar's horizontal padding). On `ended` the velocity over the last 100 ms decides: any motion picks the nearest page boundary in its direction (so a flick reversed back toward the current space returns to it; Arc was measured only with same-direction flicks); with none, the nearest page (more than half a page away switches). Momentum events of that gesture are ignored. Settling to the chosen page is a spring of response about 0.25 s and damping about 0.88; springing back without a switch, about 0.19 s and 0.98. Past the last space the offset is `255·(1 − 1/(0.15·x/255 + 1))` of the followed offset `x`, and releasing there past the threshold opens space creation; before the first space sits the Library page. The Library replaces the sidebar and widens it by 70 pt while open (Arc: 347 to 417 pt), so it may pass the 500 pt drag limit; it opens from the bottom bar's Library button, a trackpad release past the first space or a wheel switch past it, closes with the button, Escape or scrolling back, remembers its last page, and for now has only the Archive page, laid out as Arc's (measured): a search field filtering title and URL as you type, day headings from the close time, rows of title over URL on a 56 pt pitch, and delete and restore buttons on the hovered row; restored entries reopen at the top of Today, and a back arrow closes the Library. Space creation (Arc's "Create a Space", measured): the bottom bar's + menu offers New Space (Arc's other items need features we do not have yet and are left out, not shown disabled), and a trackpad release past the last space opens it too. Pulling past the last space shows Arc's indicator (measured, `docs/research/arc-sidebar-layout.md`): a circle 30 pt across in the accent colour holding a white +, entering from under the sidebar's right edge and stopping 12 pt inside it (it moves in 0.4 pt per followed point, so it stops at 105), centred on the sidebar's vertical middle (the window's in both forms); a white ring around it that grows counterclockwise from 12 o'clock between followed offsets of 75 and 162; at 165, the threshold, the circle turns white with the + in the accent colour. Releasing past the threshold shows space creation at once while the circle slides out to the right in about 70 ms; releasing before it springs back. It fills the sidebar at its docked width with the page card empty: a heading with our subtitle "Keep related tabs together.", a name field 36 pt tall, a read-only Profile card 59 pt tall, 14 pt side insets and 6 pt gaps, and at the bottom a Create Space button, disabled until the name is non-empty, and Cancel. Return creates and shows the new space; Escape or Cancel returns. Arc's illustration, theme picker and name icon are left out until themes and icons exist. The Library's open and close motion is not measured in Arc: the scroll path uses the space switch spring and the button path the ⌘S curves (ours). Wheel: sum `scrollingDeltaX`, with its sign reversed when `isDirectionInvertedFromDevice` is set, over 49 ms; above 1 it switches one space and ignores wheel input for 250 ms from that switch, without extending the pause (measured: 40–50 ms and 230–260 ms; the values are Dia's, which fall inside). A wheel switch slides to the neighbouring space with the trackpad's switch spring, showing the neighbour as a trackpad switch does, and a later switch continues from the current offset (as the owner saw in Arc, 2026-11-01; Arc's curve for it was not measured). A trackpad gesture that begins during a wheel slide takes over from the current offset; a wheel switch before the first space opens the Library like any other page (owner's choice, 2026-11-02: a mouse must reach it too; Arc's wheel there is not measured), and a wheel switch past the last space plays a full pull: the page stretches to the threshold with the indicator on the switch spring, then space creation opens as after a release there (owner's choice, 2026-11-02: a mouse must create spaces too; Arc creates none from the wheel). From the Library, horizontal input over its left rail (trackpad or wheel) returns to the first space, while input over the archive list only scrolls the list vertically and never switches spaces (as the owner saw in Arc, 2026-11-02); from space creation, a wheel switch toward the spaces returns to the last space with the switch spring (owner's choice). Only horizontal input switches spaces: an event is horizontal when `|scrollingDeltaX| > |scrollingDeltaY|`, decided at the first nonzero event of a trackpad gesture for the whole gesture and per event for the wheel; other input scrolls the row list (our rule; Arc's was not measured). In both, a negative value goes to the next space. Trackpad events keep their sign, so under natural scrolling a trackball and a trackpad move the other way for the same hand motion, as in Arc. Not measured: whether Arc's page and half-page threshold scale with the sidebar's width.
- Floating sidebar, Arc's behaviour as measured (`docs/research/arc-ardia-observed.md`; the owner's choice, 2026-10-31): it appears after the pointer stays about 150 ms within 5 pt of the window's left edge or left of the window, reaching full width about 110 ms after it starts with about 1% overshoot (the floating sidebar spring of the motion values above). It stays while the pointer is left of the window up to about 250 pt from the window's left edge; this limit did not change with window width. It hides, in about 90 ms easing out, when the pointer moves more than about 250 pt left of the window, more than about 72 pt right of the sidebar's edge (inside the window or beyond its right edge), or above the window. Inside the window this uses tracking areas. Outside the window tracking areas report nothing, so while the app is active the pointer is followed there too: while the sidebar is hidden, local and global mouse-moved `NSEvent` monitors (as Yab's `LightsRow` does) drive the edge zone and the dwell timer, and a move out of the zone cancels the dwell; while it is shown, the pointer position (`NSEvent.mouseLocation`) is sampled at display rate. Only the key window's sidebar takes part. As in Arc, the sidebar hides when the app deactivates, and both stop then. As in Arc, while no tab is selected the sidebar stays shown and none of the hiding rules apply: ⌘S still switches docked and hidden, and hidden shows the floating panel (owner's choice, 2026-10-31; seen in Arc during the measurements, not checked in Ardia, Cra or Yab). Yab's different values are in `docs/research/yab-observed.md`.
- Themes: Arc's `blendedGradient` (two base colours, overlay colours, noise and intensity, analogous or complementary wheel, light or dark translucency) mapped onto `NSVisualEffectView` plus gradient layers. Private `CABackdropLayer` is avoided unless a measured gap justifies it (Cra ledger 34).
- Settings window: an `NSSplitViewController` with a unified toolbar, panes in SwiftUI. One window holds the settings of every space (as Yab's Spaces pane does), and opening settings from a space opens that space's settings in it (the owner's choice, 2026-10-31). How per-space settings change as you slide between spaces is still to be mocked (14).
- Extensions are added and managed from an Extensions pane in the settings window, per profile, with an "add from Arc" path that lists the Arc extensions not yet installed (as Yab does; the owner's choice, 2026-10-31). The pane uses the import rules of §9.

## 8. Sync

### 8.1 Model

- No account. A sync group is created on one device and backed by a 256-bit group secret, shown as a 24-word BIP-39 recovery phrase.
- The server never sees plaintext, names or secrets. It stores opaque blobs and serves them back.

### 8.2 Protocol requirements

A versioned protocol specification (`docs/sync-protocol.md`) is written and reviewed before any sync code. It must provide:

- Key schedule: HKDF from the current epoch secret (the group secret for the first epoch, a fresh random secret for each later one) into a content key, a name key and a relay key, with distinct labels (domain separation).
- Encryption: XChaCha20-Poly1305 with random 192-bit nonces, so independent devices never need to coordinate nonces. AAD binds group, epoch, device id, sequence number and object name.
- Device identity: each device has its own signing key pair; every blob is signed; devices are listed in a signed membership record.
- Pairing: a new device joins by entering the recovery phrase, or with a short code from an existing device run through a PAKE (for example CPace) so a guessed or intercepted code does not reveal the secret.
- Relay authorisation: the relay accepts writes only from registered device keys of a group and reads only with a relay credential derived from the relay key; it never holds the content key.
- Replay: each device keeps per-device sequence checkpoints and rejects blobs at or below them.
- Removal: removing a device starts a new epoch from a fresh random epoch secret, which the removing device sends sealed to each remaining device's key, never derived from the group secret alone, so the removed device cannot derive the new keys. The relay credential for the old epoch is revoked, the membership record drops the device, and remaining devices re-seal the snapshot under the new epoch. Removal also replaces the group secret: the owner is shown a new recovery phrase, and the old phrase no longer joins the group, because joining by phrase needs the current group secret. Each epoch secret is also stored on the relay sealed under a recovery key derived from the current group secret, so the current phrase alone recovers the current keys with no surviving device; the removed device cannot open it, because the group secret was replaced first. Recovery does not depend on the epoch secret it recovers: the group secret also derives, under their own labels, a recovery read credential, which the relay accepts for that sealed blob only, and a recovery signing key pair, whose public key the relay holds for the group. A device recovering by phrase reads the blob with the credential and registers its new device key with a signature from the recovery key. Replacing the group secret replaces both at the relay, so the old phrase can neither read the blob nor register a device.
- Restore safety from the first release: a device restored from backup gets a new incarnation and never reuses an incarnation or sequence number.

### 8.3 Data path

- Each device only appends: per-device logs with sequence numbers, plus periodic snapshots with version vectors. No device rewrites another device's blob.
- Merge is per-record last-writer-wins on a hybrid logical clock, with the tree rules of 6.1 applied after merge.
- Blobs are padded to 1 KiB and not compressed.
- A local journal is written before upload in the same transaction as the workspace change (5.2).
- Tombstones are kept indefinitely until device retirement, epochs and mandatory snapshot rejoin for long-absent devices exist; only then is collection allowed (Ardia ledger 3 lists the requirements its reverted attempt revealed).
- New record kinds are added under keys old versions do not read and preserve, so an older client never writes them back damaged. The iPhone client preserves record kinds it cannot use (for example extensions).

### 8.4 What syncs

Workspace, Air Traffic Control rules, key bindings, settings, passwords and Web Store extensions. Passwords: the engine hands records to the core as zeroised buffers; the core seals them; plaintext never leaves the browser process or reaches the UI layer. Extensions are enabled on another device only when version and permissions match what was approved (Ardia ledger 1.5). History sync is later.

### 8.5 Server

A small Rust service: blob put/get/list per group, device-key verification, rate limits, size quotas. Storage on SQLite or an S3-compatible store. Hosting is an owner decision (14).

### 8.6 Rejected

- Chrome Sync: requires Google.
- A self-hosted Chromium sync server (Brave's `go-sync`): covers only Chromium's data types, so the workspace would need a second system, and the iPhone app has no Chromium sync engine.
- A user-chosen folder (Ardia): no folder reaches iPhone and Windows the same way; the owner chose a server.

## 9. Extensions, content blocking, DRM, Safe Browsing

- Extensions run on real `Browser` and `TabStripModel` objects, so `chrome.tabs`, `chrome.windows`, action popups and side panels use Chrome's implementation.
- Import: Web Store extensions are reinstalled from the Web Store (verified packages), with toolbar order taken from the source browser's pinned list (Cra ledger 8b). Unpacked extensions are imported only after an explicit per-extension approval. Chromium's permission, blocklist and incognito checks apply unchanged.
- Native messaging: host manifests registered for other browsers are linked into our profile only after validating the manifest and the executable's code signature, never for hosts that drive Chrome itself (Cra ledger 29).
- Web Store installs and updates go straight to Google, and Google's extension kill switch stays on (Ardia ledger 1.7).
- Content blocker, DRM and Safe Browsing: owner decisions (14). DRM is decided before the phase-6 API freeze, because a second page engine would change the page API.

## 10. Other platforms

- **Windows and Linux.** The same engine tree and layer. The UI is written in Chromium's Views (C++) and links the core through its C ABI; the coordinator, rules and sync are reused unchanged. On Wayland, clients cannot read the global pointer position, so the floating sidebar's outside-window rule is limited there.
- **iPhone.** App Store browsers use WebKit except in Japan (iOS 26.2+) and the EU (iOS 17.4+) under Apple's browser-engine entitlement, which requires meeting Apple's criteria including timely security updates. The iPhone app is planned on WKWebView with a SwiftUI/UIKit UI and the same Rust core and sync; Chrome extensions are not available there. A Blink build for iOS is not planned.

## 11. Testing and measurement

- Core: unit tests for anything that loses or leaks data when wrong (merge, tree invariants, crash reconciliation, import, ATC matching, archive rules) and for bugs that shipped (Ardia ledger 1.9).
- UI: the harness runs the components on fixture data; a command channel drives it without the pointer.
- Engine: hidden instances for broad coverage, plus visible checks for what hidden runs cannot show (focus, passkeys, fullscreen, accessibility, compositor timing).
- Crash and relaunch tests: kill the process at chosen points and check reconciliation.
- Sync: offline device returning after edits, device removal and rekey, restore from backup.
- Main-thread hitch monitor from the first build (Cra ledger 13).
- Performance gates: one benchmark controller alternates runs of isolated control (previous release) and candidate processes with the same fixtures, and caps counts (layout passes, store updates, engine round trips) rather than wall-clock alone (Ardia ledger 1.9).
- Speed changes ship behind kill switches with an owner and a removal date.

## 12. Distribution

- Developer ID signing and notarization; Sparkle 2 with EdDSA-signed appcasts, stable and nightly channels (macOS).
- Bundle id, team id, entitlements (keychain access group for passkeys, Bluetooth usage) and helper signing are settled in the phase-3 spike, because credential storage depends on them.
- The signing phase is isolated from the build phase in CI; actions are pinned by commit SHA.
- Every release carries its Corresponding Source (4.7).
- Windows and Linux updaters are decided in their phases.

## 13. Development process

Each unit of work: Opus 5.5 sets the scope → Codex `gpt-6.1-sol` implements (effort medium, labteam account) → Opus 5.5 reviews and decides fix or no fix per finding. Hard edge-case bugs run the other way round (Codex investigates, Opus gives a second opinion, Codex implements, Opus reviews). Measurement and design-stage work need no review unless the owner asks. Tasks run on orca-agent-team or herdr-agent-team seats (`AGENTS.md`). Reviews and judgements are kept in `docs/reviews/`.

## 14. Open decisions for the owner

| Item | Options | Current lean |
|---|---|---|
| Per-space settings that change when sliding between spaces | Owner's design; inputs: Arc's per-space theme/profile editing from the space header, Dia's settings window, Yab's settings (`docs/research/yab-observed.md`). Fixed so far: one window for all spaces, opened at the current space (7) | Mock first, then decide |
| Favorites shared per profile (Arc) or per space (Cra) | Profile / space | Profile, as Arc; revisit after the mock |
| Pre-authorise Chromium milestone bumps (full builds) for security | Yes / ask each time | Yes, within the patch-lag limits of 4.9 |
| DRM | Widevine with Google's VMP signing; a WebKit second engine for DRM sites (Ardia); none at first | Decide before phase 6 |
| Content blocker | uBlock Origin (MV2, Ardia) / uBlock Origin Lite (MV3) / Chromium subresource filter with permissively licensed lists | uBO Lite, to stay on Chromium's supported path |
| Safe Browsing | Google Safe Browsing with an API key / another reputation source | Required before daily use (4.9); source to decide |
| Sync server hosting | Own VPS / Cloudflare (Workers + R2) / other | Decide in phase 8 |

## 15. Roadmap

Each phase ends with a working build and a sandwich review.

| Phase | Content | Exit criteria |
|---|---|---|
| 0 | Repo, devshell, research imported, this document | Reviewed design |
| 1 | Core basics without the engine: model with the membership register, ATC, Arc import, SQLite with crash-safe writes, UniFFI bindings; `AraratUI` minimal sidebar on core data in the harness. In parallel: clone `morluto/rea`, analyse Yab statically (layout, class names, settings structure) within its terms, observe Yab's floating sidebar and settings, write the spec | Harness shows a real Arc import; core tests for tree invariants and crash-safe writes pass |
| 2 | Engine build base on the Mac Studio: Xcode, pinned Chromium, both base candidates inventoried, GN args, lock, measured first and incremental builds, `series check`, base decision | A stock build of the chosen base from our scripts; base decision recorded |
| 3 | Vertical slice spike: `//ararat/core` with the core's coordinator and the minimal sidebar, in a signed app (bundle id, team, entitlements, helper signing). Acceptance (hidden and visible): two profiles in one window with extension window semantics; popups through every creation path; autofill, passkey and permission prompts including rejection; external protocol confirmation; fullscreen exit; docked DevTools; an MV3 extension with its popup; Chromium owning the run loop with clean and cancelled quit; cross-window page transfer and a two-pane split; compositor measurements and decision; IME and paste after ⌘L; crash and relaunch reconciliation; one practice rebase. The duties matrix (4.6) is complete | All acceptance checks pass; compositor model chosen |
| 4 | UI build-out: full sidebar, favorites, folders, space paging, floating sidebar with Arc's rule, themes, command bar with Chromium autocomplete | Owner can browse with the Arc layout |
| 5 | Little window, Air Traffic Control as default handler, split view, archive, downloads, session restore | Arc workflow parity for daily use |
| 6 | Distribution and security gate: Developer ID, notarization, Sparkle, CI signing, Corresponding Source, the 4.9 maintenance jobs, reputation check; DRM decided and the page API frozen | Signed build that updates itself; owner starts daily use |
| 7 | Settings (with the owner's per-space design), import of passwords, cookies and extensions, key bindings | Owner moves off Arc |
| 8 | Sync: protocol spec reviewed, client, relay server | Two Macs in sync without an account; offline-return, removal and restore tests pass |
| 9 | Windows: Views UI over the same engine layer and core | Windows build with spaces and sync |
| 10 | Linux: Views UI, Wayland and X11 | Linux build with spaces and sync |
| 11 | iPhone: WKWebView app with the core and sync | Workspace synced to iPhone |

Cra is open source, so its behaviour is read from source; running REA on its binary adds nothing over the code. REA is used on Yab (phase 1), within Yab's terms of 2026-09-30, which allow any lawful use and contain no clause against analysis.
