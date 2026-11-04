# Arc and Ardia observed: floating sidebar (as of 2026-10-31)

Japanese translation: `arc-ardia-observed.ja.md`. Yab's values and the method: `yab-observed.md`, `yab/README.md` section 4. The same probe and the same display were used (one 3440×1440 display at 1× and 165 Hz, macOS 27.0.1). Times run from posting the mouse event to the frame callback and include the capture delay, which was not measured separately. The sidebar was hidden, and a test tab with a white page was opened so the sidebar's edge stood out; both were put back afterwards.

Subjects: Arc 1.171.0 with the sidebar hidden (View › Show Sidebar), window 1146×1410 pt. Ardia 0.2.42 with View › Auto-Hide Tabs on, window 1360×860 pt.

## 1. Showing

| What | Arc | Ardia | Yab, for comparison |
|---|---|---|---|
| Edge zone inside the window | Within 5 pt (6 pt does not trigger) | Within 5 pt (8 pt does not trigger) | Within 12 pt |
| Left of the window | Shows (tested 5 and 47 pt outside) | Does not show (40 pt outside) | Shows |
| Dwell | About 150 ms: 100 ms never shows it, 150 ms starts it as the pointer leaves | None found: a 50 ms touch shows it | About 330 ms |
| First frame of movement | 160–175 ms after arrival (5 runs) | 80–96 ms after arrival | About 353 ms |
| Motion | Full width about 110 ms after it starts; overshoot about 1% | Full width about 115 ms after it starts; overshoot about 2% | About 105 ms; overshoot about 2% |
| Reach from the window's left edge | 187 pt; the sidebar floats with a small inset | 180 pt | 245 pt |

## 2. Hiding

| Pointer moves | Arc | Ardia | Yab |
|---|---|---|---|
| Right inside the window | Hides past about 72 pt right of the sidebar's edge (70 stays, 75 hides) | Hides past about 22 pt (20 stays, 25 hides) | Hides past about 38 pt |
| Out of the window to the left | Stays within about 250 pt of the window's left edge (240 stays for 10 s, 260 hides); hides beyond, whether the pointer jumps or glides there | Hides | Stays (tested up to 147 pt) |
| Above the window | Hides, at any horizontal position | Hides | Stays |
| Out of the window to the right | Hides | Hides | Hides |
| Below the window | Not tested (the window reached the screen bottom) | Hides | Not tested |
| Another app activated, pointer still on the edge | Hides at once | Not tested | Stays (at least 2.5 s) |
| Delay before hiding | First changed frame about 35 ms after the move | About 170 ms; coming back within 100 ms keeps it | First changed frame about 20 ms after the move |
| Hide motion | About 90 ms, easing out | About 90 ms | About 85 ms, nearly linear |

## 3. What this means for Ararat

- The owner's recollection holds for Arc: when the pointer leaves the window to the left, Arc keeps the sidebar shown until the pointer is about 250 pt left of the window, then hides it. Yab also keeps it on the left; its far limit was not measured. The owner chose Arc's rule for Ararat (2026-10-31). Not separated: whether the 250 pt depends on the sidebar's width (window width does not matter, section 4), and whether it matters that the area left of the measured window was another Arc window. Ardia does not: it hides on leaving the window in any direction and cannot be revealed from outside the window.
- Arc and Yab differ above the window and on deactivation: Arc hides in both cases, Yab stays. The owner chose Arc's values and both of its rules (architecture §7).
- Arc reacts sooner than Yab (about 150 ms dwell, 5 pt zone, against 330 ms and 12 pt) and allows more slack to the right (about 72 pt against 38 pt).
- Ardia's floating sidebar is a hover with a hide delay inside the window only. Its code is no reference for the outside-window rule.

## 4. Follow-up measurements on Arc

- **Spring.** A damped spring fitted to every frame of six show runs gives response 154 ms (sd 10) and damping 0.84 (sd 0.02), with 1–4 px rms error. The values in architecture §7's source (components note 5: 0.185 s, 0.77) fit every run worse. The overshoot alone (2 px of 177) is too small to estimate damping; the fit uses the whole curve.
- **Hiding distance.** Measured from the window's left edge, the sidebar hides at about 250 pt to the left (250 stays, 252 hides) and about 257 pt to the right (256 stays, 258 hides). The left limit was the same with the window 800, 1146 and 1600 pt wide. Both limits may be one distance from the window's left edge; the sidebar's width was not varied, so whether it scales with the sidebar is not known.
- **Window at the screen's left edge.** With the window at x = 0, a pointer at 0–4 pt shows the sidebar, and holding it at 0 pt keeps it shown (3 s tested).

## 5. Switching spaces by scrolling over the sidebar

Measured 2026-10-31 on Arc, Yab 0.42.1 and Ardia, with natural scrolling on. Devices: a Magic Trackpad and a trackball with a scroll mode. The owner swiped and rolled each device over the sidebars of Arc and Yab and reported what moved; `scrollrec` recorded the same events system-wide; `scrollplay` replayed each of the 14 recorded gestures (5 wheel, 9 trackpad) to each app from a middle space; `scroll` and `lineprobe` posted synthetic events. Spaces were read and put back with AppleScript. The tools are in `yab/` (README section 4). Directions below are given as the sign of the horizontal delta (`scrollingDeltaX`), not as a hand motion: the owner's "moves right" can mean either the space to the right or the content moving right, so which hand motion gives which sign was not established.

**What the devices send.** Both set the inverted-direction flag (CGEvent field 137, `NSEvent.isDirectionInvertedFromDevice`), and the same hand motion gives the same sign on both: Yab, which follows the sign alone, moved the same way for both devices in the owner's test. The trackball sends wheel events without phases (`isContinuous` 0): 7–12 events over 90–180 ms per flick, the OS acceleration growing the delta to 15–20 lines per event. The trackpad sends phased events (may-begin, began, changed, ended) followed by 0.8–1.6 s of momentum events.

| Same hand motion | Arc | Yab | Ardia (replay only) |
|---|---|---|---|
| Trackball and trackpad | Opposite directions | Same direction | Same direction |
| Strong trackball flick | 1 space | 2 spaces (each of 5 recorded flicks) | 1 space |
| Strong trackpad flick | 1 space | 1 space | 1 space |

The replays agree with the owner's reports. In Arc every recorded gesture moved one space except one slow trackpad drag, which moved none; in Ardia every gesture moved one; in Yab every wheel flick moved two and every trackpad gesture one (the slow drag none).

**Direction.** Arc goes to the next space on a negative delta from the trackpad, and on a negative delta from the wheel only after reversing the sign when the inverted flag is set; with synthetic events, setting the flag flipped Arc's wheel direction and left the trackpad's alone. Under natural scrolling the two devices therefore move Arc's spaces in opposite directions for the same hand motion. Yab ignores the flag. Ardia also reverses wheel events on the flag, but its unflagged wheel direction is the opposite of Arc's, so with natural scrolling both devices go the same way.

**Arc's wheel rule** (synthetic single events and pairs from `scrollplay`). Arc sums the fixed-point delta (the `scrollingDeltaX` of a line-based event) over a short window: one event of 1.0 does not switch and one of 1.2 does; two events of 1.0 switch when 40 ms apart and not when 50 ms or more apart. After a switch it ignores wheel input: a second strong event 230 ms after the switch was ignored and one 260 ms after switched again. The pause counts from the switch, not from the first event: with the switch made by a second event at 40 ms, an event at 270 ms (230 ms after the switch) was ignored and one at 310 ms switched. Further events do not extend the pause: a stream of 1-line events 30 ms apart moved one space with 10 events (last at about 270 ms), two with 12 (about 330 ms) and two with 16 (about 450 ms). A real flick ends within 180 ms, so it moves one space. Ardia gave the same counts for those streams. Yab moved one space with 2–4 events, three with 6 or 8 and five with 12: it switches again well within 250 ms; its rule was not measured further.

**Arc's trackpad rule** (`lineprobe` capturing one pixel row of the sidebar at up to 240 frames per second while posting phased events). The sidebar follows the gesture: each event moves it by half its delta (−4 moves it 2 pt left), with the next or previous space beside it about 180 pt away. On release Arc looks at the motion in about the last 100 ms: any motion picks the space in its direction (−1 three times 16 ms apart, then release, switched; −2 three times, a 60 ms pause and release switched; after a 120 ms pause it did not). With no recent motion it picks the nearest space: held at 90 pt (180 delta) it stayed, at 92 pt it switched, half the 180 pt spacing. Momentum events after the release do not move it further. Settling after a switch fits a spring of response about 250 ms and damping 0.88 (1.5 pt rms); springing back without a switch fits about 190 ms and 0.98 (1.1 pt rms).

**Ends of the list.** Past the last space the sidebar moves with a rubber band: 600 delta moved it about 38 pt, and the intermediate points fall within a few points of `255·(1 − 1/(0.15·x/255 + 1))` with `x` half the delta. Releasing there opened Arc's "Create a Space" page (no space was created; the test returned to the last space). Before the first space sits the Library: the same drag there slid the Library page in, and Arc stayed on it after release.

These values coincide with Dia's published ones (`arc-dia-components.md` section 5.3, profile paging): half the delta, the same rubber band, a 49 ms wheel window above 1, a 0.25 s pause, a 100 ms velocity history. Dia's settle spring is critically damped at 0.25 s; Arc's fitted damping is 0.88.

Not measured: vertical wheel input (a diagonal trackball roll was replayed and behaved like its horizontal part), and whether the 90 pt threshold scales with the sidebar's width.

## 6. Arc's other motion

Measured the same way on the docked sidebar (window 1146×1410 pt, sidebar about 180 pt wide).

| Action | Measured |
|---|---|
| Hide the docked sidebar (⌘S) | The page's left edge starts about 50 ms after the key and covers 168 pt in about 90 ms, easing out. Fits an ease-out cubic of 91 ms (2.2 pt rms) or a spring of response 103 ms and damping 0.89 (2.1 pt rms). 3 runs |
| Show it (⌘S) | Starts 555–585 ms after the key in all 3 runs, then covers 168 pt in about 100 ms, easing out: an ease-out cubic of 99 ms (1.8 pt rms) or a spring of 122 ms and 0.83 (1.2 pt rms). The delay was not explained |
| Open a tab | The new row is inserted at the top of Today; the rows below move down one row. Their first 28 pt took about 40 ms; the end of the motion could not be tracked |
| Close a tab | The rows below move up one row (about 41 pt): an ease-out cubic of 117 ms (0.3 pt rms over 3 runs). A closed row at the end of the list fades over about 110 ms |

The View menu's Show/Hide Sidebar item did not always match the sidebar's state when read through the Accessibility API; the sidebar's state was checked on screen.

## 7. Which tab is selected after a close (2026-11-01)

Measured on Arc 1.171.0 with tabs this measurement created (example.com) and closed again; Arc archived them. First with Arc's AppleScript `close tab` while another app was in front, then with ⌘W with Arc in front; both gave the same results.

- Selecting Y4 then Y2 and closing Y2 selected Y4, not Y2's neighbours Y1 or Y3.
- Selecting Y1, Y3, Y4 and closing them in turn selected Y3, then Y1, then the tab selected before Y1: the selection history.
- In another space, opening a tab there and closing it (the space had pinned tabs only, nothing selected before) left nothing selected and stayed in that space: the history does not cross spaces, and no pinned neighbour was picked.

## 8. Dragging and organizing in the sidebar (2026-11-03)

Measured on Arc 1.171.0 at 1× with tabs and a folder this measurement created and removed again, by synthetic mouse events (press, drag in 8 ms steps, release) and window captures.

- A press on a tab row selects it; the drag then carries the selected tab.
- While dragging, the row stays in place with its fill, and a copy of the row (fill, favicon, title, ✕) follows the pointer. Other rows do not move apart. The drop position shows as a 2 pt line, nearly white, from x 16 to x 166 in a sidebar about 178 pt wide, with a hollow ring about 7 pt across at its left end. The line sits on the boundary between two rows (row centre + 20.5 pt on the 41 pt pitch).
- After release the copy settles into place in about 100 ms (pixel changes on a vertical line stop about 120 ms after the release).
- Dragging a Today tab above the divider pins it at that position; the pinned row then shows "Double-click to rename" under its title while selected. Dragging a pinned tab below the divider unpins it.
- Over a folder row no line shows; dropping there puts the tab inside the folder (indented one level) and opens the folder.
- Over favorites the tiles reflow while dragging (two tiles became three columns, with an empty tile at the drop place); the drop makes the tab a favorite. Remove Favorite in a favorite's menu closed the tab: it did not return to Today.
- Folders are created from the + menu (New Space, New Folder, New Easel, New Boost, New Split, New Tab) or from the menu of the sidebar's empty area (space items, New Folder, Live Folders). The new folder, "Untitled", is added at the end of pinned with its title in rename mode. An empty folder's Delete removed it without asking.
- Menus: a Today tab's menu has Copy Link, Share, Change Icon…, Rename…, Mute, Customize Page…, Open in Split View, Duplicate, Move to (the spaces, New Space…), Archive Tab, Archive Tabs Below. A pinned tab's menu replaces Open in Split View with Add Split View, adds Edit Pinned Page, and ends with Remove Pin instead of the archive items. A favorite's menu ends with Close Tab (⌘W) and Remove Favorite. A folder's menu has Share Folder…, New Nested Folder…, Turn into Space, Change Icon…, Rename…, Duplicate, Move to, Delete. No tab menu offers a new folder, so Arc offers no way to make a folder in Today.
- Synthetic drags of a folder row did not start a drag (each press toggled the folder open or closed). The owner checked by hand (2026-11-03): a folder cannot be dragged into Today or into favorites; folders live in pinned only. Deleting a folder with tabs asks first: "Delete your “<name>” folder?" with "Deleting this folder will archive the tabs inside it.", Cancel (Esc) and a red Delete Folder (Return); confirming archives the tabs inside.
- The owner checked by eye (2026-11-04): "Double-click to rename" shows under a tab's title only for a few seconds right after the tab is moved from Today into pinned, not whenever a pinned tab is selected. The rename field shows the selected text with no focus ring, and the Create a Space name field is a dark rounded card with no focus ring. The duration was not measured.
- The owner's check on screen, measured again for Ararat (2026-11-05, Arc 1.171.0, 1×): while a pinned row is renamed, the field takes the title's place in the row; the title label is not visible; the whole text is selected; the trailing control stays; and no tooltip opens over the renamed row, even after 1.5 s of hover.
- The colour field of Edit Theme Color in the Look popover (2026-11-05, Arc 1.171.0, dark, 1×): the field's background is neutral grey RGB 42, 42, 42 (#2A2A2A); the lower part of the field is a translucent material. Light was not measured.
- Still to measure (the owner wants it measured): how long a dragged tab must rest on a collapsed folder before the folder opens. Dragging onto another space's dock dot was not tried.
