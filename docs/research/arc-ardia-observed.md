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

Measured 2026-10-31 on Arc, Yab 0.42.1 and Ardia, with natural scrolling on. Devices: a Magic Trackpad and a trackball with a scroll mode. The owner swiped and rolled each device over the sidebars of Arc and Yab and reported what moved; `scrollrec` recorded the same events system-wide; `scrollplay` replayed each of the 14 recorded gestures (5 wheel, 9 trackpad) to each app from a middle space; `scroll` posted synthetic streams. Spaces were read and put back with AppleScript. The tools are in `yab/` (README section 4).

**What the devices send.** Both set the inverted-direction flag (CGEvent field 137, `NSEvent.isDirectionInvertedFromDevice`). A rightward motion gives a negative horizontal delta on both; this is the only assignment that fits the owner's reports for both Arc and Yab together with the replays. The trackball sends wheel events without phases (`isContinuous` 0): 7–12 events over 90–180 ms per flick, the OS acceleration growing the line delta to 15–20 per event, 600–1,600 pt in total. The trackpad sends phased events (may-begin, began, changed, ended) followed by 0.8–1.6 s of momentum events.

| Rightward motion | Arc | Yab | Ardia (replay only) |
|---|---|---|---|
| Trackball | Previous space (left) | Next space (right) | Next space |
| Trackpad | Next space | Next space | Next space |
| Strong trackball flick | 1 space | 2 spaces (each of 5 recorded flicks) | 1 space |
| Strong trackpad flick | 1 space | 1 space | 1 space |

The replays agree with the owner's reports. In Arc every recorded gesture moved one space except one slow trackpad drag, which moved none; in Ardia every gesture moved one; in Yab every wheel flick moved two and every trackpad gesture one (the slow drag none).

**Why the direction differs.** Arc reverses the direction of wheel events when the flag is set and leaves trackpad events as they are: with synthetic events, setting the flag flips Arc's wheel direction only. Under natural scrolling the two devices therefore move Arc's spaces in opposite directions for the same physical motion. Yab ignores the flag and follows the delta's sign for both. Ardia also reverses wheel events on the flag, but its unflagged wheel direction is the opposite of Arc's, so with natural scrolling both devices go the same way.

**Why Yab moves several spaces.** The trackpad is gated by its gesture: in all three apps one gesture moves one space, even with 10,000 pt of momentum. Wheel input has no phases. Arc and Ardia ignore further wheel events for about 300 ms after a switch: a stream of 1-line events 30 ms apart moved one space with 10 events (last at about 270 ms) and two with 12 or 16 (last at about 330 ms), the same in both apps. A real flick ends within 180 ms, so it moves one space. Yab has no such pause: the same streams moved one space with 2–4 events, three with 6 or 8 and five with 12.

Not measured: how many lines or points start Arc's first switch, whether Arc's pause counts from the switch or from the first event, and vertical wheel input (a diagonal trackball roll was replayed and behaved like its horizontal part).
