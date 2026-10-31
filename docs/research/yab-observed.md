# Yab observed: floating sidebar and settings (as of 2026-10-31)

Japanese translation: `yab-observed.ja.md`. Static analysis: `yab-static.md`. Tools and method: `yab/README.md` section 4.

Subject: Yab 0.42.1 on macOS 27.0.1, one 3440×1440 display at 1× scale and 165 Hz, the main browser window at 1146×1410 pt with the sidebar on the left in its shut (hidden) state. A script moved the pointer with synthetic mouse events and recorded, per captured frame, how far the sidebar reached along one blank pixel row. Frames arrived about every 6 ms; capture latency is about 15–20 ms, judged from the hide reaction, and is included in the times below.

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
| Motion | Starts within capture latency of the pointer crossing, then runs almost linearly and finishes in about 85 ms |

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

## 3. Points for Ararat

- The owner chose Arc's values and rules over Yab's for §7's floating sidebar (`arc-ardia-observed.md`). Yab's values here stay as the comparison.
- Yab shares pins per sign-in, which supports architecture §14's current lean (favorites per profile).
- Today shared across windows of a space is a setting in Yab (`tabs.todayEveryWindow`). Ararat's model has one Today per space, so each window's own selected tab must live in per-window view state.
