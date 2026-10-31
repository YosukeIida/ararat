# Arc's sidebar layout, measured (as of 2026-10-31)

Japanese translation: `arc-sidebar-layout.ja.md`. Arc 1.171.0, dark appearance, window 1146×1410 pt with the sidebar docked, one display at 1× (one pixel per point). The sidebar was captured with `screencapture` and read pixel by pixel (scripts in `yab/`, README section 4); the capture is not kept, since it shows the owner's tabs. Positions are in points from the window's top-left corner. Cra's values come from its source (`VictorKildahl/cra`, MIT, commit 68108ce: `Sources/Cra/UI/Theme.swift:474-494`, `docs/arc-reverse-engineering.md`), which says they were measured on Arc 1.168–1.170. Ardia's sidebar is calibrated against Dia (`docs/dia-spec.md` in its repository), not Arc, and is not used.

| Item | Arc, measured | Cra |
|---|---|---|
| Traffic lights | 14 pt across, centres x 19.5 / 42.5 / 65.5, y 23.5 | Centres 19 / 43 / 67 in its notes, 20 / 44 / 68 in code; y 24 |
| URL field | x 9 to 169 (8 pt from the sidebar's right edge), y 46–81, 36 pt tall | x 8, y 46, 36 tall, radius 10, host text 13 pt |
| URL field to favorites | 8 pt | 8 |
| Favorites tiles | 2 columns at this width, each 76 pt wide and 47 pt tall, 8 pt apart, from x 8 | 47 tall, 8 apart; 4 columns while a tile stays at least 47 wide, else 2, never 3; radius 13 |
| Corner radius (URL field, tiles, selected row) | 11 pt, continuous, the same for all three (see below) | 10 (field, rows), 13 (tiles) |
| Space name | Text from x 16; its top 22 pt below the tiles | Header 31 tall, title 14 pt medium |
| Rows | 41 pt pitch, single- and two-line rows alike | 41 pitch |
| Selected row fill | 36 pt tall (5 pt between two filled rows), x 8–169; dark fill rgb(67, 63, 75) on a sidebar of rgb(22, 15, 31) | 36 tall, radius 10; dark white 13% |
| Favicon | 16 pt at x 18 | 16 at x 18 |
| Title | Starts at x 44–45; glyphs 13 pt tall, consistent with a 14 pt font | x 45, 14 pt regular; subtitle 11 pt |
| Nesting indent | 16 pt (one nested row measured) | 18 |
| Divider above New Tab | 1 pt line from x 18 to 159; "New Tab" label from x 20 | |
| Bottom bar | Icons 16 pt tall centred about 25 pt above the window's bottom edge; Library at x 17, + ending at x 160 | 36 tall, 6 pt from the bottom |
| Sidebar width | The page card starts at x 178 (the owner's width). Dragging the edge keeps the card's left edge between x 164 and x 500 | Default 328, range 220–520 |

**Nested rows.** With the pointer over a row (no selection changed), the hover fill of a row one level inside a folder starts 16 pt further right than a top-level row's and ends at the same x; measured on the floating sidebar, where both fills end 8 pt inside the sidebar's edge. Deeper levels were not available and are assumed to add 16 pt each, as the icons do. The selection fill was not measured separately; it has the hover fill's shape at the top level.

**Floating panel.** Shown while no tab was selected (the sidebar hidden), the floating sidebar is a panel inset 5 pt from the window's left and top edges, with a 1 pt light border (luminance about 90 of 255 on the dark appearance) and the docked width (border at x 5, the page visible from x 183 with the docked card at x 178). The border's corner curve leaves the straight edges about 11–12 pt from the corner on both sides; it was not fitted against rendered corners, and radius 11 continuous, as for the other surfaces, is consistent with it. The shadow was not measured.

**Dragging the width.** The sidebar's edge (the page card's left edge) was dragged with synthetic mouse events in a test tab on `example.com`, closed afterwards; the owner's width was restored. The card's left edge stops at x 164 when dragged left and at x 500 when dragged right. The maximum stayed at 500 with the window narrowed from 1146 to 800 pt, so it is a fixed width, not a share of the window. Dragging further left than the minimum leaves the width at 164 until the pointer passes about x 81 from the window's left edge (x 81 and 82 kept it, x 80 hid it), about half the minimum; there the sidebar hides as with ⌘S, and showing it again brings back width 164. Only the width after release was captured; whether the width follows the pointer during the drag was not recorded.

**Corner radius.** Apple's design guidance gives no number for these; it asks for continuous corners and for inner shapes concentric with their container (radius = the container's minus the padding; WWDC25 session 356). Each corner's edge profile, read with sub-pixel coverage over its first 14 rows, was compared with rounded rectangles drawn by Core Animation at 1× (`cornerCurve` `.continuous` and `.circular`, radius 8–15 in 0.5 steps). All six corners (top and bottom of the URL field, a tile and the selected row) fit radius 11–11.5; continuous 11 is among the best three for every corner and best for four, with 0.14–0.17 pt rms. Circular and continuous differ by less than the fit's noise at this size, so the curve itself is Apple's default (continuous) rather than measured. Cra's 13 for tiles does not fit.

Not measured: the light appearance, hover fill, fonts by name, the space-name row's height, and the empty state. The nesting indent rests on one row and disagrees with Cra's 18 pt; the owner chose Arc's 16 pt (2026-10-31), which also keeps to a 4 pt grid.
