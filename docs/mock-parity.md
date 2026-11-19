# U20 mock parity

The source is the owner's U20 project under `~/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project`. Read `mock-decisions.md` and `ui-inventory.md` in `reports/design-u20` alongside the board. An owner decision takes precedence over a drawing. The project contains 76 readable boards. The seven Batch A serve links have the same filenames in the canonical project.

## Token and structure checks

The [reviewed token table](research/mock-values.json) has 89 entries. The Swift suite compares 77 entries and all match. The other 12 carry reasons in the table, including owner spacing decisions and the selected-row shadow pending in selshadow. Two table entries can refer to the same declaration when the two appearances resolve a CSS variable differently.

The CSS census found 27,782 candidate declarations across the 76 pages. Of these, 88 have a reviewed disposition and 27,694 still need triage. Candidates include stylesheet rules shared by many boards, board annotations, inline variants, and unbuilt surfaces. The count gives an upper bound on the remaining declarations, and the number that needs a Swift mapping is still unknown. The census checks that each reviewed CSS selector, property and value is still present at the recorded line.

```sh
MOCK_PROJECT="$HOME/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project"
direnv exec . env -u DEVELOPER_DIR -u SDKROOT swift test --package-path macos --no-parallel --filter MockParityTests
uv run --no-project python macos/scripts/mock-values/census.py "$MOCK_PROJECT"
```

On the VM, run `split-focus`, `split-commands`, `dock`, `urlfield`, `folder-empty` and `today` as `--ararat-screen=<name>`. Use the bundled app with a fresh scratch profile and workspace, as in [the screen check commands](architecture.md). Copy each reported PNG with its same-stem JSON file. View frames in the JSON use window coordinates in points. For a region capture, the sidecar names the window used by the check. The checker covers split segments, shared sidebar chrome, the Library dock position, URL-field buttons, the empty-folder line, and the Today divider. Native AppKit menus and rendered web DOM need separate inspection.

```sh
uv run --no-project python macos/scripts/mock-values/check_structure.py /path/to/copied/sidecars/*.json
# To check one run, provide --screen split-focus and that run's JSON files.
```

## Comparison PNGs

On the host, pass a copied VM PNG to the mock renderer. It reads the PNG's pixel dimensions and runs headless Chrome with a fresh temporary profile. The renderer fits the board into those dimensions at its original aspect ratio. For a board containing several specimens, pass `--selector` with the CSS selector of the matching specimen. Both commands print their output paths under `$TMPDIR`. The sheet labels the mock on the left and the VM capture on the right.

```sh
VM_PNG=/path/to/copied/captures/split-focus-a.png
MOCK_PNG="$(uv run --no-project python -B macos/scripts/mock-values/render_mock.py "$MOCK_PROJECT/A-TabRows.dc.html" --capture "$VM_PNG")"
uv run --no-project python -B macos/scripts/mock-values/pair_pngs.py "$MOCK_PNG" "$VM_PNG"
```

## Source discrepancies

- `B-Split.dc.html:20` describes segments in its caption and depicts the selected split with a single row-level fill. The component drawing `A-TabRows.dc.html:79–82` defines the per-segment fill, and the Swift implementation follows that drawing. The inactive segment explicitly references the row hover CSS variable in both appearances.
- [Architecture §7](architecture.md) describes onboarding as SwiftUI. [OnboardingWindow.swift](../macos/Sources/AraratUI/OnboardingWindow.swift) implements the screens in AppKit.
- [Architecture §7](architecture.md) and the Little Window code call the board's 46 pt height unmeasured. [Cra's Arc observations](research/arc-dia-components.md) and [the Yab comparison](research/yab-values.md#little-window) list 46 pt as the Arc value. The token table records the product's 48 pt structural bar height with the owner spacing rule pending a decision on the conflicting provenance.
- The `commandbar` screen check asserts behavior and emits JSON. The existing check has no PNG capture for its regular command panel or tab switcher.

## Review ledger

The capture column lists the VM check name and any relevant phase names. `Matches` and `differs` report the named element and evidence in the note. Design records the visual result after checking the VM comparison.

| Mock page | Element | VM check | Status | Evidence or follow-up |
| --- | --- | --- | --- | --- |
| `A-BottomDock` | Library, add menu and space cells | `dock (cells)` | not captured | The VM fixture exercises the cells and the refusal state. |
| `A-BottomDock` | Current space cell and other space dots | `dock (cells, mid)` | not captured | The selected fill cross-fades when the visible space changes (decision 69). |
| `A-FavouriteTiles` | Favicon tiles, loading, audio and unread marks | `organize (first-favorite)` | not captured | This frame covers the first tile. The remaining states need separate frames. |
| `A-FavouriteTiles` | Empty favourites area | — | not captured | The area collapses without a placeholder (decision 13). |
| `A-Folders` | Expanded folder, empty line and row retention | `folder-empty (line, drop)` | not captured | The token suite verifies the 24 pt empty line and 12 pt type. |
| `A-Header` | Width-dependent navigation and tooltips | `header (widths, tooltip, loading, stopped)` | not captured | The width thresholds are 200 pt for Reload and 232 pt for the sidebar toggle (decisions 7–10). |
| `A-Header` | Shortcut held and overflow at narrow width | `header (command-r, command-r-narrow, command-w)` | not captured | These phases compare the pressed states of the control and keycaps (decisions 9–10). |
| `A-Header` | Header overflow menu | — | not captured | Menu contents are checked by the header mode. Native menu appearance needs its own frame. |
| `A-Layout` | Sidebar geometry | `header (240)` | not captured | The token test covers the default 240 pt width and selected row dimensions. |
| `A-SpaceName` | Name, chevron, overflow and collapsed pin group | `space-name (hover, collapsed, renamed)` | not captured | The chevron control box keeps its 16 pt size under the owner's size rule. |
| `A-TabRows` | Pinned and Today rows, spinner, unread, crash and audio | `sidebar-rows (rows, loading, unread, crashed, muted)` | not captured | The token suite covers the dot's size and the two row fill states in both appearances. |
| `A-TabRows` | Split segment geometry and unfocused fill | `split-focus (a), split-commands (vertical, split)` | matches | The token suite and the offscreen row test verify the mapped geometry and both unfocused fills. |
| `A-TabRows` | Multi-selection | — | not built | Multi-selection is deferred past Phase 5 (§7). |
| `A-TabRows` | Selected row and segment shadows | `sidebar-rows (rows), split-focus (a)` | not captured | The selected-row shadow work is tracked in selshadow. |
| `A-TabRows` | Loading and crashed glyphs | `sidebar-rows (loading, crashed)` | not captured | Decision 15 puts the loading spinner in the favicon's place. |
| `A-TabRows` | Unread and muted rows | `sidebar-rows (unread, muted)` | not captured | The dot follows title changes on hidden loaded tabs (decisions 19 and 24). |
| `A-TabRows` | Row archive and close controls | `header (command-w), sidebar-rows (rows)` | not captured | The action depends on the kind and loading state of the row (decisions 29 and 32). |
| `A-TodayNewTab` | Today divider, Clear and New Tab | `today (today, cleared, new-tab-row)` | not captured | The divider and Clear depend on Today contents (decision 39). |
| `A-TodayNewTab` | Divider after Clear | `today (cleared)` | not captured | The checker requires the divider to be absent once Today is empty. |
| `A-TodayNewTab` | New Tab hidden by Appearance | — | not captured | The setting is exercised by the Today check. Its new-tab-row PNG shows the row after it is enabled again. |
| `B-CreateSpace` | Create a Space form | `space-name (create-page)` | not captured | The form appears as a sidebar page. |
| `B-CreateSpaceStates` | Creation success and failure | `create-space (created, failure)` | not captured | The existing check captures the success and failure fixtures. |
| `B-Drag` | Sidebar drop line, folder hover and refusal | `organize (drop, hover-open), dock (refused)` | not captured | The app check exercises row drag and cross-profile refusal. |
| `B-Drag` | Cross-profile refusal | `dock (refused)` | not captured | Decision 68 specifies the dimmed cell and refused pointer badge. |
| `B-DragPage` | Page drop target for creating a split | `split-commands` | not captured | The check asserts the indicator. Its saved frames cover menu and established splits. |
| `B-Floating` | Floating sidebar geometry and content | — | not captured | Floating behavior is implemented in SidebarContainerView. |
| `B-FloatingDark` | Dark floating sidebar | — | not captured | A capture with the dark effective appearance is needed. |
| `B-FloatingMotion` | Edge reveal, dwell and hide | — | not captured | The sidebar timing is checked elsewhere. A static frame cannot verify timing. |
| `B-Fullscreen` | Page fullscreen, browser fullscreen and edge reveal | `fullscreen (page, browser, edge)` | not captured | Each condition has a separate capture. |
| `B-History` | History deletion banner and Retry | `toasts (banner)` | not captured | The decisions specify a per-profile banner on failure (decision 56). |
| `B-HistoryStates` | History-store failures and retry states | `toasts (banner)` | not captured | The error banner has a frame. Successful retry removes it. |
| `B-Library` | Library rail and archived tabs | — | not captured | The Downloads capture covers a different Library page. |
| `B-LibraryStates` | Archive list states | — | not captured | Archive search, restore and removal exist in LibraryView. |
| `B-Menus` | Native row, space and split menus | `split-commands (menu)` | not captured | The VM check asserts split menu items and icons. Sidebar menu appearance still needs review. |
| `B-NoTab` | Empty page card and keyboard hints | — | not captured | Use an empty workspace capture with the sidebar visible. |
| `B-SpacePaging` | Paging and dock cross-fade | `dock (mid)` | not captured | The wheel-motion check records timing separately. |
| `B-Split` | Two panes, focus ring and shared chrome | `split-focus (a, b)` | not captured | Decision 65 puts navigation in the sidebar. The mock's sidebar drawing still uses one combined row fill. |
| `B-SplitStates` | Multiple panes, divider, drag and transfer | `split-commands (vertical, split), split-focus (frozen, release), dialogs (transfer)` | not captured | The caption describes a continuous separator line in Swift. SplitDividerView only paints the grip on hover or drag. |
| `B-SplitStates` | Three panes in a single sidebar row | `split-commands (vertical)` | not captured | The checker expects three side-by-side segments even when the pages stack vertically. |
| `B-Tooltips` | Button and row tooltips with keycaps | `header (tooltip, command-w)` | not captured | Native drawing can differ from the board's CSS even with the same keys and placement. |
| `B-WindowStates` | Window chrome, minimum width and inactivity | `window-drag (sidebar)` | not captured | The drag image covers the sidebar. The inactive tint needs its own frame. |
| `C-DialogHost` | Dialogs over the page card | `prompts, dialogs` | not captured | Use the separate dialog PNGs alongside the host screenshot. |
| `C-Downloads` | Library progress, popover and full list | `downloads (flight, ring, popover, library, popover-complete)` | not captured | The popover row height passes at 48 pt. Spacing exceptions are listed in the token table. |
| `C-Downloads` | Progress ring and file flight | `downloads (ring, flight)` | not captured | The fly-to-Library effect is suppressed under Reduce Motion (§7). |
| `C-Downloads` | In-progress and completed popover | `downloads (popover, popover-complete)` | not captured | Compare the row status and available actions at each phase. |
| `C-Downloads` | Library Downloads history | `downloads (library)` | not captured | This frame shows full history rather than the transient popover. |
| `C-Extensions` | Pinned actions in the URL field and overflow row | `ext-actions (action, overflow, three-actions)` | not captured | Decision 47 specifies the 64 pt minimum host label. |
| `C-Extensions` | Action overflow | `ext-actions (overflow, three-actions)` | not captured | Tokens and captures should distinguish icon size, row height and how multiple rows wrap. |
| `C-Permissions` | Permission prompt and blocked-site indicator | `prompts, site-controls (popover)` | not captured | The sheet and the site-controls state come from different checks. |
| `C-SiteControls` | Capture tiles and security footer | `site-controls (popover, certificate)` | differs | The board draws four actions. The product has the two action implementations specified in §7. |
| `C-SiteControls` | Portrait capture, translate, extension grid and planned controls | — | not built | These controls are deferred in §7 and §14. |
| `C-SiteControlsStates` | Popover state geometry | `site-controls (popover, overlay, toast)` | not captured | The suite verifies width, padding, gap and the button dimension tokens. |
| `C-SiteControlsStates` | Certificate sheet | `site-controls (certificate)` | not captured | The security footer opens the sheet (decision 5). |
| `C-UrlField` | Host text, placeholder and trailing buttons | `urlfield (host, placeholder, internal, long-host)` | not captured | The checker asserts both buttons are children of the URL field when a page is selected. |
| `C-UrlField` | Long and narrow host label | `urlfield (long-host, long-host-narrow)` | not captured | Use both widths to compare clipping and button retention. |
| `CommandBar` | Overview command panel | — | not captured | The commandbar mode reports conditions and currently emits no PNG. |
| `D-CommandBar` | Search-first entry and history | `little-window (command-bar)` | not captured | Little Window exercises Edit URL. The regular typed-search panel needs a separate capture. |
| `D-CommandBarPanels` | Command panel variants | — | not captured | The commandbar check asserts results in multiple modes. |
| `D-CommandBarRows` | Result row sizing, inset and gap | — | matches | The mapped row and field dimensions match in the token suite. Row appearance is pending. |
| `D-ErrorPages` | Offline and DNS errors | `errorpages (offline, dns)` | not captured | The native page fixtures capture each failure. |
| `D-FindBar` | Find bar and result counter | — | not captured | FindBarView implements the bar. A capture needs a filled query and results. |
| `D-FindBarPage` | Find bar over a page | — | not captured | A full-window capture should include the page and active find bar. |
| `D-LittleWindow` | Bar, Open in menu, profile menu and command bar | `little-window (bar, profile-menu, space-menu, command-bar)` | not captured | The token table records the 48 pt bar height and compares the mapped colours and controls. |
| `D-PrivateWindow` | Private window and URL-field mask | `private-window` | not captured | The screen mode captures a private browser window. |
| `D-PrivateWindowEmpty` | Empty private window | — | not captured | The recorded private-window frame covers its navigated case. |
| `D-SadTab` | Crashed Today tab and pin | `errorpages (today-crash, pin-crash)` | not captured | The two captures exercise Archive Tab and Close Tab respectively. |
| `D-TabSwitcher` | Control-Tab switcher | — | not captured | The commandbar check verifies switching and cancellation without a PNG. |
| `D-Toasts` | Link copied, Clear with Undo and failure banner | `toasts (toast, banner)` | not captured | The history failure uses a per-profile banner (decision 56). |
| `D-Toasts` | Update ready with Restart | — | not built | The updater is planned for a later phase (§15). |
| `Dark` | Dark browser overview | — | not captured | A dark workspace capture is needed to compare the full window. |
| `E-About` | About and update states | — | not built | The settings implementation has no About pane. |
| `E-AirTraffic` | Routing rules and destination editor | `settings-air-traffic` | not captured | The VM check covers the default destination and rule editing. |
| `E-Appearance` | Appearance controls | `settings-appearance (appearance, theme-light, theme-dark, theme-system)` | not captured | Theme, Look, the New Tab row, tooltips and zoom are implemented. |
| `E-Controls` | Settings controls and their interaction states | `settings-frame, settings-appearance` | not captured | Rows include native AppKit and SwiftUI controls. |
| `E-Extensions` | Installed list, profile menu and review | `settings-extensions (extensions, extensions-profile2, extensions-review)` | not captured | The installed list is implemented through Chromium. |
| `E-Extensions` | Add from Arc | — | not built | Extension import awaits source inventory and permission rules (§14). |
| `E-Frame` | Settings toolbar, rail and content card | `settings-frame (frame), settings-toolbar (toolbar-top, toolbar-scrolled)` | not captured | Grouped card radius and spacing match the mapped tokens. |
| `E-General` | Default browser, startup and downloads | `settings-general (general)` | not captured | Phase 5 implements these rows (§7). |
| `E-General` | Remaining general preferences | — | not built | Warn before quitting, suggestions, search-engine and spelling rows are deferred in §7. |
| `E-LittleWindow` | Shortcut, destination, closing and frame memory | `settings-little-window (little-window)` | not captured | The settings check drives the Little Window preference rows. |
| `E-Passwords` | Saved passwords and Touch ID | — | not built | The U20 password settings are planned. |
| `E-Privacy` | Clear data, retention, cookie and privacy controls | `settings-privacy (privacy, privacy-sheet)` | not captured | The user-facing protection placeholders do not ship in this phase (§7). |
| `E-Privacy` | Blocker and dangerous-site warnings | — | not built | Design and sources are open (§14). |
| `E-Search` | Search in Settings and highlighted result | `settings-search (search, search-cleared)` | not captured | The token suite verifies the result highlight's corner radius, inset and row height. |
| `E-Shortcuts` | Shortcut list, recorder and conflicts | `settings-shortcuts (shortcuts)` | not captured | Use the shortcut fixture after its recorder steps. |
| `E-SpacePage` | Settings for one space | `settings-tabs (space-page)` | not captured | The tabs check navigates to a space page. |
| `E-Spaces` | Space list and scroll direction | `settings-spaces (spaces)` | not captured | The direction is a workspace-wide setting. |
| `E-Sync` | Sync setup and devices | — | not built | Sync is scheduled for Phase 8 (decision 100). |
| `E-Tabs` | Tab settings and space navigation | `settings-tabs` | not captured | The tabs check covers the pane and per-space navigation. |
| `E-Websites` | Defaults and per-site permissions | `settings-websites (websites, site-row, site-page)` | not captured | The check creates a site override before opening its page. |
| `Extensions` | Overview of pinned extension actions | `ext-actions (action, overflow)` | not captured | Placement follows the newer URL-field decision (42). |
| `F-Import` | Import selection, progress and completion | `onboarding (what-to-import, progress, done)` | differs | The fixture-backed flow leaves out the sign-in, passwords, history and archive rows (§7). |
| `F-Import` | Sign-in data and Keychain permission | — | not built | The Keychain flow requires import research (decisions 105–106). |
| `F-LookControls` | Transparency, Glass detent, Grain and menu | `look (55, detent, glass)` | not captured | The look check captures the slider positions and the detent. |
| `F-LookGallery` | Presets and colour picker | `look (popover)` | not captured | Confirm that the captured picker is on the same preset page as the board. |
| `F-LookPopover` | Look popover and colour field | `look (55-popover, glass-popover)` | not captured | Pair the popover frame with the matching mock specimen. |
| `F-LookSidebar` | Space tint and sidebar at different settings | `look (55-sidebar, detent-sidebar, glass-sidebar)` | not captured | The check records paired sidebar and popover images. |
| `F-LookStates` | Picker, preset and Grain states | `look` | not captured | The Look check samples the Grain settings as well as Glass. |
| `F-Onboarding` | Welcome, source, choices, default browser, progress, done and two errors | `onboarding (eight fixture states)` | not captured | The token table records the owner size and spacing exceptions for the buttons. |
| `F-Onboarding` | Welcome and source discovery | `onboarding (welcome, source)` | not captured | The source check uses the Arc detector fixture. |
| `F-Onboarding` | Import choices and default-browser request | `onboarding (what-to-import, default-browser)` | not captured | Verify the import rows and the default-browser action separately. |
| `F-Onboarding` | Keychain access request | — | not built | Screen 3a awaits verification of sign-in state import (decision 106). |
| `F-Onboarding` | Progress and completion report | `onboarding (progress, done)` | not captured | The report rows come from the import fixture. |
| `F-Onboarding` | Import error and sibling-file warning | `onboarding (error, sibling-file)` | not captured | Both failure variants have separate captures. |
| `Floating` | Overview floating sidebar | — | not captured | Capture the floated panel above a loaded page. |
| `Main` | Main-window overview | `header (240)` | not captured | The 240 pt header frame provides a candidate whole window. |
| `Themes` | Look overview, colour layer and slider | `look (popover and sidebar)` | not captured | The owner chose the transparency slider and detent in decisions 113–115. |
