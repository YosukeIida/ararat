# U20 mock parity

The source is the owner's U20 project under `~/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project`. Read `mock-decisions.md` and `ui-inventory.md` in `reports/design-u20` alongside the board. An owner decision takes precedence over a drawing. The project contains 76 readable boards. The seven Batch A serve links have the same filenames in the canonical project.

## Token and structure checks

The [reviewed token table](research/mock-values.json) has 90 entries. The Swift suite compares 77 entries and all match. The other 13 carry reasons in the table, including owner spacing decisions, the Library Downloads row pitch and the selected-row shadow pending in selshadow. Two table entries can refer to the same declaration when the two appearances resolve a CSS variable differently.

The CSS census found 27,782 candidate declarations across the 76 pages. Of these, 88 have a reviewed disposition and 27,694 still need triage. Candidates include stylesheet rules shared by many boards, board annotations, inline variants, and unbuilt surfaces. The count gives an upper bound on the remaining declarations, and the number that needs a Swift mapping is still unknown. The census checks that each reviewed CSS selector, property and value is still present at the recorded line.

```sh
MOCK_PROJECT="$HOME/.config/herdr-agent-team/ararat/reports/design-u20/u20mock/project"
direnv exec . env -u DEVELOPER_DIR -u SDKROOT swift test --package-path macos --no-parallel --filter MockParityTests
uv run --no-project python macos/scripts/mock-values/census.py "$MOCK_PROJECT"
```

Run the checks below as `--ararat-screen=<name>` on the VM. Use the bundled app with a fresh scratch profile and workspace, as in the [screen check commands](architecture.md).

- Sidebar and window: `organize`, `header`, `space-name`, `sidebar-rows`, `today`, `folder-empty`, `create-space`, `dock`, `split-commands`, `split-focus`, `fullscreen`, `window-drag` and `urlfield`.
- Page and panels: `keyboard`, `prompts`, `dialogs`, `downloads`, `ext-actions`, `site-controls`, `commandbar`, `errorpages`, `little-window`, `private-window` and `toasts`.
- Settings and onboarding: `settings-air-traffic`, `settings-appearance`, `settings-extensions`, `settings-frame`, `settings-toolbar`, `settings-general`, `settings-little-window`, `settings-privacy`, `settings-search`, `settings-shortcuts`, `settings-spaces`, `settings-tabs`, `settings-websites`, `look` and `onboarding`.

Run the Keyboard main check with `--ararat-keyboard-main-scope` for the Find and Archive captures.

Copy each PNG with its same-stem JSON file. View frames in the JSON use window coordinates in points. A region capture's sidecar describes the host window. The checker covers the sidebar, split segments, command bar and switcher, Little Window, Downloads and settings structures listed in [structure.json](../macos/scripts/mock-values/structure.json). Inspect native menus and rendered web DOM in the PNGs.

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
- [Architecture §7](architecture.md) and the Little Window code call the board's 46 pt height unmeasured. [Cra's Arc observations](research/arc-dia-components.md) and [the Yab comparison](research/yab-values.md#little-window) list 46 pt as the Arc value. The token table records the product's 48 pt structural bar height with the owner spacing rule pending a decision on the conflicting provenance.

## Review ledger

The capture column lists the check and phase for reviewed entries and the exact sidecar names for pending reviews. Each pending name omits the file prefix, UUID and extension. `Not reviewed` means the check provides at least one capture for the row and Design has a visual comparison pending. The note identifies states that still need a capture. `Matches` and `differs` apply to the named element and evidence.

| Mock page | Element | VM check | Status | Evidence or follow-up |
| --- | --- | --- | --- | --- |
| `A-BottomDock` | Library, add menu and space cells | `dock (cells)` | matches | Library and + sit in the dock; structure check library-dock PASS. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `A-BottomDock` | Current space cell and other space dots | `dock (cells, mid)` | matches | Open space keeps its letter cell and the others become dots, as drawn. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `A-FavouriteTiles` | Favicon tiles, loading, audio and unread marks | `organize-first-favorite` | not reviewed | This frame covers the first tile. The remaining states need separate frames. |
| `A-FavouriteTiles` | Empty favourites area | `organize-empty-favorites` | not reviewed | The area collapses without a placeholder (decision 13). |
| `A-Folders` | Expanded folder, empty line and row retention | `folder-empty (line, drop)` | matches | Empty folder shows the No tabs line; structure check PASS. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `A-Header` | Width-dependent navigation and tooltips | `header-240`, `header-232`, `header-231`, `header-200`, `header-199`, `header-164`, `header-tooltip-toggle_sidebar`, `header-tooltip-back`, `header-tooltip-forward`, `header-tooltip-reload`, `header-loading`, `header-stopped` | not reviewed | The width thresholds are 200 pt for Reload and 232 pt for the sidebar toggle (decisions 7–10). |
| `A-Header` | Shortcut held and overflow at narrow width | `header-command`, `header-command-r`, `header-command-r-narrow`, `header-command-w` | not reviewed | These phases compare the pressed states of the control and keycaps (decisions 9–10). |
| `A-Header` | Header overflow menu | `header-overflow-menu` | not reviewed | The PNG shows the tracked AppKit menu within the browser window's screen region. The sidecar describes the host window. |
| `A-Layout` | Sidebar geometry | `header-240` | not reviewed | The token test covers the default 240 pt width and selected row dimensions. |
| `A-SpaceName` | Name, chevron, overflow and collapsed pin group | `space-name-hover`, `space-name-collapsed`, `space-name-menu`, `space-name-renamed` | not reviewed | The Space Name check captures hover, collapse, the native menu and rename. |
| `A-TabRows` | Pinned and Today rows, spinner, unread, crash and audio | `sidebar-rows-selected`, `sidebar-rows-hover`, `sidebar-rows-pressed`, `sidebar-rows-rows`, `sidebar-rows-loading`, `sidebar-rows-unread`, `sidebar-rows-crashed`, `sidebar-rows-muted` | not reviewed | The hover and pressed PNGs show an unselected loaded pin. The selected PNG shows the adjacent Today row. |
| `A-TabRows` | Split segment geometry and unfocused fill | `split-focus (a), split-commands (vertical, split)` | matches | The token suite and the offscreen row test verify the mapped geometry and both unfocused fills. |
| `A-TabRows` | Multi-selection | — | not built | Multi-selection is deferred past Phase 5 (§7). |
| `A-TabRows` | Selected row and segment shadows | `sidebar-rows-selected`, `split-focus-a` | not reviewed | The selected-row shadow is tracked in selshadow. Compare the Today row and the selected split segment. |
| `A-TabRows` | Loading and crashed glyphs | `sidebar-rows-loading`, `sidebar-rows-crashed` | not reviewed | Decision 15 puts the loading spinner in the favicon's place. |
| `A-TabRows` | Unread and muted rows | `sidebar-rows-unread`, `sidebar-rows-muted` | not reviewed | The dot follows title changes on hidden loaded tabs (decisions 19 and 24). |
| `A-TabRows` | Row archive and close controls | `header-command-w`, `sidebar-rows-hover`, `sidebar-rows-pressed` | not reviewed | The action depends on the kind and loading state of the row (decisions 29 and 32). |
| `A-TodayNewTab` | Today divider, Clear and New Tab | `today (today, cleared, new-tab-row)` | matches | Divider with Clear above Today and New Tab first; structure check PASS. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `A-TodayNewTab` | Divider after Clear | `today (cleared)` | matches | Divider absent once Today is empty; structure check PASS. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `A-TodayNewTab` | New Tab hidden by Appearance | `today-new-tab-hidden` | not reviewed | The capture shows the sidebar with the row hidden by the workspace setting. |
| `B-CreateSpace` | Create a Space form | `space-name-create-page` | not reviewed | The form appears as a sidebar page. |
| `B-CreateSpaceStates` | Creation success and failure | `create-space-created`, `create-space-failure` | not reviewed | The existing check captures the success and failure fixtures. |
| `B-Drag` | Sidebar drop line, folder hover and refusal | `organize-drop`, `organize-hover-open`, `dock-refused` | not reviewed | The app check exercises row drag and cross-profile refusal. |
| `B-Drag` | Cross-profile refusal | `dock-refused` | not reviewed | Decision 68 specifies the dimmed cell and refused pointer badge. |
| `B-DragPage` | Page drop target for creating a split | `split-commands-drop-target` | not reviewed | The capture shows the split indicator before the simulated drag is released. |
| `B-Floating` | Floating sidebar geometry and content | `fullscreen-edge` | not reviewed | The edge-reveal capture shows the floating panel during browser fullscreen. |
| `B-FloatingDark` | Dark floating sidebar | `fullscreen-dark-floating` | not reviewed | After the fullscreen assertions, the check captures the dark floating panel in a regular window. |
| `B-FloatingMotion` | Edge reveal, dwell and hide | `fullscreen-floating-before-reveal`, `fullscreen-dark-floating`, `fullscreen-floating-after-hide` | not reviewed | The check moves the pointer to the reveal edge and then away from the panel. The three images document the settled states. Dwell and motion durations need timing evidence. |
| `B-Fullscreen` | Page fullscreen, browser fullscreen and edge reveal | `fullscreen-page`, `fullscreen-browser`, `fullscreen-edge` | not reviewed | Each condition has a separate capture. |
| `B-History` | History deletion banner and Retry | `toasts-banner` | not reviewed | The decisions specify a per-profile banner on failure (decision 56). |
| `B-HistoryStates` | History-store failures and retry states | `toasts-banner` | not reviewed | The error banner has a frame. Successful retry removes it. |
| `B-Library` | Library rail and archived tabs | `keyboard-archive-list` | not reviewed | The Keyboard check opens Archive with two fixture entries before deleting or restoring either one. |
| `B-LibraryStates` | Archive list states | `keyboard-archive-list`, `keyboard-archive-search`, `keyboard-archive-no-matches`, `keyboard-archive-empty` | not reviewed | The check captures the list, URL filtering, no search matches and an empty archive after Clear Archive. Row-action focus and hover, dark variants and rail interaction states still need frames. |
| `B-Menus` | Native row, space and split menus | `sidebar-rows-tab-menu`, `space-name-menu`, `split-commands-menu-open` | not reviewed | The checks open native menus for a Today tab, the space name and the left pane. Other row kinds and menu variants still need frames. |
| `B-NoTab` | Empty page card and keyboard hints | `keyboard-no-tab` | not reviewed | The capture shows an empty space with the page card exposed. The mock's two keyboard hints need product UI. |
| `B-SpacePaging` | Paging and dock cross-fade | `dock-mid` | not reviewed | The wheel-motion check records timing separately. |
| `B-Split` | Two panes, focus ring and shared chrome | `split-focus (a, b)` | matches | Two panes, accent ring on the focused pane, no per-pane bar, one sidebar row with a segment per pane (per A-TabRows, not this page's single fill). VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `B-SplitStates` | Multiple panes, divider, drag and transfer | `split-commands-vertical`, `split-commands-split`, `split-focus-frozen`, `split-focus-release`, `dialogs-transfer` | not reviewed | The caption describes a continuous separator line in Swift. SplitDividerView only paints the grip on hover or drag. |
| `B-SplitStates` | Three panes in a single sidebar row | `split-commands (vertical)` | matches | Three segments side by side for a vertical split; structure check PASS. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `B-Tooltips` | Button and row tooltips with keycaps | `header-tooltip-toggle_sidebar`, `header-tooltip-back`, `header-tooltip-forward`, `header-tooltip-reload`, `header-command`, `header-command-r`, `header-command-w` | not reviewed | Header tooltips have their own frames. The Command-W frame shows the row's pressed close button. A row tooltip still needs a frame. |
| `B-WindowStates` | Window chrome, minimum width and inactivity | `window-drag-sidebar` | not reviewed | The drag image covers the sidebar. The inactive tint needs its own frame. |
| `C-DialogHost` | Dialogs over the page card | `permission`, `permission-dialog`, `javascript`, `javascript-dialog`, `dialogs-permission`, `dialogs-permission-dialog`, `dialogs-long-origin`, `dialogs-long-origin-dialog`, `dialogs-javascript`, `dialogs-javascript-dialog`, `dialogs-queued-permission`, `dialogs-queued-permission-dialog`, `dialogs-split`, `dialogs-split-dialog` | not reviewed | Run prompts for the unprefixed names and dialogs for the dialogs-prefixed names. Each dialog capture is paired with a host capture. |
| `C-Downloads` | Library progress, popover and full list | `downloads-flight`, `downloads-ring`, `downloads-popover`, `downloads-library`, `downloads-popover-complete` | not reviewed | The popover row height passes at 48 pt. Spacing exceptions are listed in the token table. |
| `C-Downloads` | Progress ring and file flight | `downloads-ring`, `downloads-flight` | not reviewed | The fly-to-Library effect is suppressed under Reduce Motion (§7). |
| `C-Downloads` | In-progress and completed popover | `downloads-popover`, `downloads-popover-complete` | not reviewed | Compare the row status and available actions at each phase. |
| `C-Downloads` | Library Downloads history | `downloads-library` | not reviewed | This frame shows full history rather than the transient popover. |
| `C-Extensions` | Pinned actions in the URL field and overflow row | `ext-actions-action`, `ext-actions-overflow`, `ext-actions-three-actions` | not reviewed | Decision 47 specifies the 64 pt minimum host label. |
| `C-Extensions` | Action overflow | `ext-actions-overflow`, `ext-actions-three-actions` | not reviewed | Tokens and captures should distinguish icon size, row height and how multiple rows wrap. |
| `C-Permissions` | Permission prompt and blocked-site indicator | `permission-dialog`, `site-controls-popover` | not reviewed | Run prompts for permission-dialog and site-controls for the blocked-site popover. |
| `C-SiteControls` | Capture tiles and security footer | `site-controls (popover, certificate)` | differs | The board draws four actions. The product has the two action implementations specified in §7. |
| `C-SiteControls` | Portrait capture, translate, extension grid and planned controls | — | not built | These controls are deferred in §7 and §14. |
| `C-SiteControlsStates` | Popover state geometry | `site-controls-popover`, `site-controls-overlay`, `site-controls-toast` | not reviewed | The suite verifies width, padding, gap and the button dimension tokens. |
| `C-SiteControlsStates` | Certificate sheet | `site-controls-certificate` | not reviewed | The security footer opens the sheet (decision 5). |
| `C-UrlField` | Host text, placeholder and trailing buttons | `urlfield (host, placeholder, internal, long-host)` | differs | An IP host shows as "127.0...." with room to spare; follow-up unit urlip. Buttons always shown, as drawn. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `C-UrlField` | Long and narrow host label | `urlfield (long-host, long-host-narrow)` | differs | The start fades but the end is also cut ("…example.inva..."), so the registrable domain does not stay; follow-up unit urlip. VM run mp2 (646da87, 2026-11-19), sheets in design reports/design-mockparity-1/sheets. |
| `CommandBar` | Overview command panel | `commandbar-search`, `commandbar-recent` | not reviewed | The regular command panel shows the search and the empty-query recent-tabs states. |
| `D-CommandBar` | Search-first entry and history | `commandbar-search` | not reviewed | The search frame includes the first-row search and a loopback history suggestion. |
| `D-CommandBarPanels` | Command panel variants | `commandbar-search`, `commandbar-settings`, `commandbar-open-url`, `commandbar-recent`, `commandbar-edit-url` | not reviewed | The check captures the regular panel in five states. The Little Window panel has a separate capture. |
| `D-CommandBarRows` | Result row sizing, inset and gap | — | matches | The mapped row and field dimensions match in the token suite. Row appearance is pending. |
| `D-ErrorPages` | Offline and DNS errors | `errorpages-offline`, `errorpages-dns` | not reviewed | The native page fixtures capture each failure. |
| `D-FindBar` | Find bar and result counter | `header-find-bar`, `keyboard-find-count` | not reviewed | Header captures the open field. Keyboard captures the final match count and active match over the search fixture. |
| `D-FindBarPage` | Find bar over a page | `header-find-bar`, `keyboard-find-count` | not reviewed | The Keyboard capture shows the find bar and its result count over the fixture page. |
| `D-LittleWindow` | Bar, Open in menu, profile menu and command bar | `little-window-bar`, `little-window-profile-menu`, `little-window-space-menu`, `little-window-command-bar` | not reviewed | The token table records the 48 pt bar height and compares the mapped colours and controls. |
| `D-PrivateWindow` | Private window and URL-field mask | `private-window` | not reviewed | The screen mode captures a private browser window. |
| `D-PrivateWindowEmpty` | Empty private window | — | differs | The product closes the private window with its last tab. The mock draws an empty private window. Owner decision pending. |
| `D-SadTab` | Crashed Today tab and pin | `errorpages-today-crash`, `errorpages-pin-crash` | not reviewed | The two captures exercise Archive Tab and Close Tab respectively. |
| `D-TabSwitcher` | Control-Tab switcher | `commandbar-tab-switcher` | not reviewed | The commandbar check verifies switching and cancellation without a PNG. |
| `D-Toasts` | Link copied, Clear with Undo and failure banner | `toasts-toast`, `toasts-banner` | not reviewed | The history failure uses a per-profile banner (decision 56). |
| `D-Toasts` | Update ready with Restart | — | not built | The updater is planned for a later phase (§15). |
| `Dark` | Dark browser overview | `fullscreen-dark-docked` | not reviewed | The fullscreen check captures the dark docked window after it has returned to normal size. |
| `E-About` | About and update states | — | not built | The settings implementation has no About pane. |
| `E-AirTraffic` | Routing rules and destination editor | `settings-air-traffic-settings-air-traffic`, `settings-air-traffic-settings-air-traffic-default-before-press` | not reviewed | The second frame shows the saved route before opening the Default destination menu. |
| `E-Appearance` | Appearance controls | `settings-appearance-appearance`, `settings-appearance-theme-light`, `settings-appearance-theme-dark`, `settings-appearance-theme-system` | not reviewed | The pane implements Theme, Look, the New Tab row and Tooltips. Page zoom is pending. |
| `E-Controls` | Settings controls and their interaction states | `settings-frame-frame`, `settings-appearance-appearance`, `settings-shortcuts-shortcuts-recorder` | not reviewed | Rows include native AppKit and SwiftUI controls. |
| `E-Extensions` | Installed list, profile menu and review | `settings-extensions-extensions`, `settings-extensions-extensions-profile2`, `settings-extensions-extensions-review` | not reviewed | The installed list is implemented through Chromium. |
| `E-Extensions` | Add from Arc | — | not built | Extension import awaits source inventory and permission rules (§14). |
| `E-Frame` | Settings toolbar, rail and content card | `settings-frame-frame`, `settings-toolbar-toolbar-top`, `settings-toolbar-toolbar-scrolled` | not reviewed | Grouped card radius and spacing match the mapped tokens. |
| `E-General` | Default browser, startup and downloads | `settings-general-general` | not reviewed | Phase 5 implements these rows (§7). |
| `E-General` | Remaining general preferences | — | not built | Warn before quitting, suggestions, search-engine and spelling rows are deferred in §7. |
| `E-LittleWindow` | Shortcut, destination, closing and frame memory | `settings-little-window-little-window` | not reviewed | The settings check drives the Little Window preference rows. |
| `E-Passwords` | Saved passwords and Touch ID | — | not built | The U20 password settings are planned. |
| `E-Privacy` | Clear data, retention, cookie and privacy controls | `settings-privacy-privacy`, `settings-privacy-privacy-sheet` | not reviewed | The user-facing protection placeholders do not ship in this phase (§7). |
| `E-Privacy` | Blocker and dangerous-site warnings | — | not built | Design and sources are open (§14). |
| `E-Search` | Search in Settings and highlighted result | `settings-search-search`, `settings-search-search-cleared` | not reviewed | The token suite verifies the result highlight's corner radius, inset and row height. |
| `E-Shortcuts` | Shortcut list, recorder and conflicts | `settings-shortcuts-shortcuts`, `settings-shortcuts-shortcuts-recorder`, `settings-shortcuts-shortcuts-conflict`, `settings-shortcuts-shortcuts-refusal` | not reviewed | After restoring the test binding, the recorder shows the current holder for Command-T and the system refusal for Shift-Command-3. |
| `E-SpacePage` | Settings for one space | `settings-spaces-space-page`, `dock-space-settings`, `settings-appearance-look-space-page` | not reviewed | The Spaces and Dock checks open the space-settings page. The Appearance check opens it from the Look row. |
| `E-Spaces` | Space list and scroll direction | `settings-spaces-spaces` | not reviewed | The direction is a workspace-wide setting. |
| `E-Sync` | Sync setup and devices | — | not built | Sync is scheduled for Phase 8 (decision 100). |
| `E-Tabs` | Tab settings and space navigation | `settings-tabs-settings-tabs`, `settings-spaces-space-page` | not reviewed | The Tabs check shows the pane. The Spaces check opens the separate per-space page. |
| `E-Websites` | Defaults and per-site permissions | `settings-websites-websites`, `settings-websites-site-row`, `settings-websites-site-page` | not reviewed | The check creates a site override before opening its page. |
| `Extensions` | Overview of pinned extension actions | `ext-actions-action`, `ext-actions-overflow` | not reviewed | Placement follows the newer URL-field decision (42). |
| `F-Import` | Import selection, progress and completion | `onboarding (what-to-import, progress, done)` | differs | The fixture-backed flow leaves out the sign-in, passwords, history and archive rows (§7). |
| `F-Import` | Sign-in data and Keychain permission | — | not built | The Keychain flow requires import research (decisions 105–106). |
| `F-LookControls` | Transparency, Glass detent, Grain and menu | `look-55-popover`, `look-detent-popover`, `look-glass-popover` | not reviewed | The popover frames show the slider and detent states. The Look menu still needs a frame. |
| `F-LookGallery` | Presets and colour picker | `look-55-popover` | not reviewed | Confirm that the captured picker is on the same preset page as the board. |
| `F-LookPopover` | Look popover and colour field | `look-55-popover`, `look-glass-popover` | not reviewed | Pair the popover frame with the matching mock specimen. |
| `F-LookSidebar` | Space tint and sidebar at different settings | `look-55-sidebar`, `look-detent-sidebar`, `look-glass-sidebar` | not reviewed | The check records paired sidebar and popover images. |
| `F-LookStates` | Picker, preset and Grain states | `look-55-popover`, `look-grain0-sidebar`, `look-grain5-sidebar`, `look-grain50-sidebar`, `look-grain100-sidebar` | not reviewed | The popover shows the picker and presets. The sidebar captures sample Grain at 0, 5, 50 and 100%. |
| `F-Onboarding` | Welcome, source, choices, default browser, progress, done and two errors | `onboarding-welcome`, `onboarding-source`, `onboarding-what-to-import`, `onboarding-default-browser`, `onboarding-progress`, `onboarding-done`, `onboarding-error`, `onboarding-sibling-file` | not reviewed | The token table records the owner size and spacing exceptions for the buttons. |
| `F-Onboarding` | Welcome and source discovery | `onboarding-welcome`, `onboarding-source` | not reviewed | The source check uses the Arc detector fixture. |
| `F-Onboarding` | Import choices and default-browser request | `onboarding-what-to-import`, `onboarding-default-browser` | not reviewed | Verify the import rows and the default-browser action separately. |
| `F-Onboarding` | Keychain access request | — | not built | Screen 3a awaits verification of sign-in state import (decision 106). |
| `F-Onboarding` | Progress and completion report | `onboarding-progress`, `onboarding-done` | not reviewed | The report rows come from the import fixture. |
| `F-Onboarding` | Import error and sibling-file warning | `onboarding-error`, `onboarding-sibling-file` | not reviewed | Both failure variants have separate captures. |
| `Floating` | Overview floating sidebar | `fullscreen-edge` | not reviewed | Browser fullscreen provides an edge-reveal frame. The non-fullscreen overview still needs its own frame. |
| `Main` | Main-window overview | `header-240` | not reviewed | The 240 pt header capture shows the whole window. |
| `Themes` | Look overview, colour layer and slider | `look-55-popover`, `look-55-sidebar`, `look-detent-popover`, `look-detent-sidebar`, `look-glass-popover`, `look-glass-sidebar` | not reviewed | The owner chose the transparency slider and detent in decisions 113–115. |
