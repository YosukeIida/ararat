# Arc's sidebar layout, measured (as of 2026-10-31)

Japanese translation: `arc-sidebar-layout.ja.md`. Arc 1.171.0, dark appearance, window 1146×1410 pt with the sidebar docked, one display at 1× (one pixel per point). The sidebar was captured with `screencapture` and read pixel by pixel (scripts in `yab/`, README section 4); the capture is not kept, since it shows the owner's tabs. Positions are in points from the window's top-left corner. Cra's values come from its source (`VictorKildahl/cra`, MIT, commit 68108ce: `Sources/Cra/UI/Theme.swift:474-494`, `docs/arc-reverse-engineering.md`), which says they were measured on Arc 1.168–1.170. Ardia's sidebar is calibrated against Dia (`docs/dia-spec.md` in its repository), not Arc, and is not used.

| Item | Arc, measured | Cra |
|---|---|---|
| Traffic lights | 14 pt across, centres x 19.5 / 42.5 / 65.5, y 23.5 | Centres 19 / 43 / 67 in its notes, 20 / 44 / 68 in code; y 24 |
| URL field | x 9 to 169 (8 pt from the sidebar's right edge), y 46–81, 36 pt tall | x 8, y 46, 36 tall, radius 10, host text 13 pt |
| URL field to favorites | 8 pt | 8 |
| Favorites tiles | 2 columns at this width, each 76 pt wide and 47 pt tall, 8 pt apart, from x 8 | 47 tall, 8 apart; 4 columns while a tile stays at least 47 wide, else 2, never 3; radius 13 |
| Corner radius (URL field, tiles, selected row) | About 12 pt when fitted as a circle; the corners may be continuous, which reads larger than their nominal radius | 10 (field, rows), 13 (tiles) |
| Space name | Text from x 16; its top 22 pt below the tiles | Header 31 tall, title 14 pt medium |
| Rows | 41 pt pitch, single- and two-line rows alike | 41 pitch |
| Selected row fill | 36 pt tall (5 pt between two filled rows), x 8–169; dark fill rgb(67, 63, 75) on a sidebar of rgb(22, 15, 31) | 36 tall, radius 10; dark white 13% |
| Favicon | 16 pt at x 18 | 16 at x 18 |
| Title | Starts at x 44–45; glyphs 13 pt tall, consistent with a 14 pt font | x 45, 14 pt regular; subtitle 11 pt |
| Nesting indent | 16 pt (one nested row measured) | 18 |
| Divider above New Tab | 1 pt line from x 18 to 159; "New Tab" label from x 20 | |
| Bottom bar | Icons 16 pt tall centred about 25 pt above the window's bottom edge; Library at x 17, + ending at x 160 | 36 tall, 6 pt from the bottom |
| Sidebar width | The page card starts at x 178 (the owner's width) | Default 328, range 220–520 |

Not measured: the light appearance, hover fill, fonts by name, the space-name row's height, and the empty state. The nesting indent rests on one row and disagrees with Cra's 18 pt; measure a second level before relying on it.
