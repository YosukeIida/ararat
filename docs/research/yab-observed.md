# Yab observed: floating sidebar and settings (as of 2026-10-31)

Japanese translation: `yab-observed.ja.md`. Static analysis: `yab-static.md`. Tools and method: `yab/README.md` section 4.

Subject: Yab 0.42.1 on macOS 27.0.1, one 3440×1440 display at 1× scale and 165 Hz, the main browser window at 1146×1410 pt with the sidebar on the left in its shut (hidden) state. A script moved the pointer with synthetic mouse events and recorded, per captured frame, how far the sidebar reached along one blank pixel row. Frames arrived about every 6 ms. Times below run from posting the mouse event to the frame callback, so they include the capture delay, which was not measured separately.

## 1. Floating sidebar

### Showing

| What | Observed |
|---|---|
| Where the pointer must be | Within 12 pt of the window's left edge inside the window (13 pt does not trigger), or anywhere to the left of the window (tested 1, 5 and 50 pt outside) |
| How long it must stay | About 330 ms. A 300 ms touch never shows the sidebar; at 330 ms the sidebar starts and then retracts as the pointer leaves |
| First frame of movement | 345–370 ms after the pointer arrives (median about 353 ms, 20 runs) |
| Motion | Reaches the full width about 105 ms after it starts, overshoots by 5 pt (about 2%) at about 135 ms, and settles about 250 ms after it starts. Fitting a spring to the overshoot and time to peak gives damping ≈ 0.78 and response ≈ 0.17 s (an estimate, not a value read from Yab) |
| Size | The sidebar's right edge sits 245 pt from the window's left edge, including the window's coloured frame of about 8 pt |
| Layout | It floats over the page; the page does not move or resize |

### Hiding

| What | Observed |
|---|---|
| Moving right inside the window | Hides once the pointer is more than 36–40 pt right of the sidebar's edge (35 pt stays, 40 pt hides) |
| Moving out of the window to the right | Hides, the same as moving right inside it |
| Moving out of the window to the left | Stays (4 s tested) |
| Moving above the window, into the menu bar | Stays at any horizontal position, even beyond the window's right edge (up to 10 s tested). Coming back into the window to the right of the slack hides it; coming back over the sidebar keeps it |
| Activating another app | Stayed shown for at least 2.5 s |
| Motion | The first changed frame arrives about 20 ms after the move; it then runs almost linearly and finishes in about 85 ms |

### Differences from architecture §7

Architecture draft 2 assumed that the sidebar leaves "after a short delay outside the window on the other sides" and hides when the app deactivates. Yab does neither within the times tested: above the window it stays, and deactivating the app does not hide it. What decides hiding is the pointer's horizontal position past the sidebar plus slack, either inside the window or beyond its right edge.

Not measured: other window sizes, the right-hand sidebar position, other density settings, a second display to the left, and the bottom edge (this window reached the bottom of the screen).

## 2. Settings window

The settings window has a list of panes on the left, a search field, back and forward buttons, and grouped rows on the right. Panes, in order: General, Field, Appearance, Websites, Tabs, Sync, Shortcuts, AI, Snippets, Spaces, Live Folders, Small Window, Passwords, Autofill, Privacy, Extensions, Boosts, Developers, Experimental, About, Invite Friends, Send Feedback, Community.

Panes relevant to Ararat's workspace and sidebar:

- **Appearance**: Theme (System, Light, Dark); Window (a colour style); Field; Look ("Customize each space in Spaces", which links to the Spaces pane); App icon. A **Sidebar** group holds Position (Left, Right, Off), Show sidebar button, Tab icons, Spaces (how spaces are shown, for example as emoji), Density and Address bar. The Bookmarks bar comes last.
- **Tabs**:
  - Close tabs you haven't opened in a chosen time; pinned and kept tabs stay.
  - Peek links with a chosen modifier.
  - Close agent tabs.
  - Today's tabs in every window: share Today across windows of one space, each window keeping its own selected tab.
  - Which spaces feed ⌃⇥.
  - A list of sites that unload last when memory is low.
  - Folder rules: ⌘-click makes a folder; add an emoji to new folders; ⌥⇧-click groups tabs; group meeting tabs.
  - Picture in Picture: automatically, and snap to edges.
  - Media player.
  - Next meeting.
- **Spaces**:
  - The list of spaces; each opens its own settings, which is where per-space look lives.
  - Match Arc: copy each space's colour and grain from Arc.
  - Pins: "Spaces with separate sign-ins have separate pins", so favorites are shared per sign-in, not per space.
  - Default Space with link rules: Yab's Air Traffic Control.
- **Small Window**: give links from other apps a small window; open one with ⌥⌘N from any app.
- **Field**: the command bar's search engine, fallback commands (search, ask, agent task), sources (open tabs, history and bookmarks, commands and settings), quick actions with aliases and hotkeys, and site search shortcuts.

The preference file stores only values that differ from the defaults. Its key names include `sidebar`, `sidebar.shut`, `space.current`, `pins.everySpace`, `tabs.todayEveryWindow`, `backdrop`, `backdrop.color`, `backdrop.grain`, `backdrop.grain.amount`, `reader.mode`, `reader.style`, `addressbar` and `live-folders.enabled`. Only key names and types were read, never values.

### Measured geometry (Yab 0.42.1, 2026-11-02, light, 1x display, window captures)

Window 760 × 540 pt, full-size content (traffic lights over the pane list).

- Pane list: 180 pt wide, no divider line against the detail; inactive tint 243/242/241.
- Search field: x 10–170, y 60–91 (161 × 32), pill (radius 16), fill 236/235/234.
- Pane rows: 160 × 26, x 10, pitch 28; selection fill 215, radius about 6; icon at x 18–34, label at x 44. Groups are separated by 14 extra points (Shortcuts → AI).
- Toolbar: 52 pt tall over the detail only, a 1 pt hairline (229) under it. Back/forward: one capsule x 187–262, y 8–43 (76 × 36), divided in two; back is enabled once a page was pushed.
- Detail: cards from x 199 to 739 (19 pt from the pane list, 20 from the right edge), first card 19 pt under the hairline, 10 pt between cards, radius 12, fill 247 on white. Rows inside a card: 54 pt for title + subtitle, 60 with an icon; hairline separators (235) inset 10 pt from the card edges.
- Pane pages open with a header: a 56 pt icon, a bold title and a one-line subtitle, centred. When the page scrolls, the header fades into the toolbar's title.
- Spaces pane: one card, a 44 pt row per space: drag handle, space icon, name, "N tabs · its own sign-ins", the switch shortcut as key caps (⌃N), a chevron. The row pushes the space's own page.
- Per-space page: header (icon, name, "N tabs · ⌃N"), then cards: Name (text field), Icon, Look (colour and texture), Search with, Sign-ins, Save downloads to, Delete Space ("Its tab closes; ⇧⌘T brings it back."). Every per-space setting carries a small "This space" caption under its subtitle.
- Search: typing replaces the pane list with results grouped under pane headers (pane icon + name, then result rows indented to the label column and truncated); the first result is selected. Clicking a result opens its pane, scrolls to the row and fills that row with the selection grey (215, inset 3 pt inside the card); the highlight appears at once and stays (still there after 4 s). The toolbar gets a search button and a Filters menu while results show.

Dark (Yab's Theme set to Dark for the capture, then back to Light; Window style "A color", so the greys carry the space's warm tint): geometry is identical. Colours (light → dark): pane list 243/242/241 → 46/41/39; detail 255 → 41/39/37; card 247 → 47/45/44; card separator 235 → 57/55/54; pane selection and search-hit highlight 215 → 61/61/61; search field 236/235/234 → 75/69/65; back/forward capsule 240 → 70/67/65. The toolbar hairline (229 in light) is not drawn in dark: the toolbar and the detail share one colour. Dark rows read as a lighter card on a darker page, the same order as light.

### Look popover (per-space page › Look, 2026-11-02; opened and read only, nothing changed)

A popover about 288 pt wide anchored on the Look row's colour ring, arrow pointing right at it. From the top:
- Colour field (about 266 × 197 pt, rounded): a grid of dots whose hue runs left to right and lightness top to bottom; the chosen colour is a 30 pt white-rimmed handle, dots near the handle grow (a lens). Over the field's top edge sit three mode buttons (sparkle = automatic, sun = light, moon = dark) and a "…" button whose menu has one item, "Use for All Spaces".
- − and + under the field (remove / add a colour handle; the owner's Arc screenshot shows the same pair with two handles).
- A row of 9 preset swatches with ‹ › paging.
- A wave slider (the line's waviness grows to the right) with a colour dot at its right end.
- A grain slider (scattered dots, sparse to dense).
- "Take the site's color" toggle: "Pages that have one tint a color of yours."
- Drawings: None, Browser, Life, Halloween (thumbnails of a pattern drawn over the colour).
The preference file's key names for the default look are `backdrop`, `backdrop.color`, `backdrop.grain`, `backdrop.grain.amount` (names and types only).
Owner's captures (2026-11-02): dragging the wave slider shows a value tag ("Transparency 90%"), so the wave slider is transparency in percent; the round bead at its right end is labelled "Glass" on hover (Yab's manual: past the end of the track the window becomes Liquid Glass).

## 3. Points for Ararat

- The owner chose Arc's values and rules over Yab's for §7's floating sidebar (`arc-ardia-observed.md`). Yab's values here stay as the comparison.
- Yab shares pins per sign-in, which supports architecture §14's current lean (favorites per profile).
- Today shared across windows of a space is a setting in Yab (`tabs.todayEveryWindow`). Ararat's model has one Today per space, so each window's own selected tab must live in per-window view state.
