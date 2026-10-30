# Static analysis of Yab (as of 2026-10-31)

Japanese translation: `yab-static.ja.md`.

Subject: Yab 0.42.1 (`/Applications/yab.app`, bundle id `dev.serafim.fast`), closed source. Yab's terms (2026-09-30) allow any lawful use and contain no clause against analysis. This note records names, structure and behaviour only; it quotes no decompiled code, page scripts or assets.

How it was analysed, and how to repeat it: `yab/README.md`.

## 1. Build and engine

- Universal binary (x86_64 + arm64). The arm64 slice is 69 MB; `__text` alone is 57 MB.
- Engine: WebKit (`WKWebView`, links `WebKit.framework` and `JavaScriptCore.framework`). No Chromium or CEF.
- UI: AppKit views for the window and sidebar; SwiftUI is linked and used alongside them (where exactly was not mapped).
- Swift module of the app: `Fast`. Two internal modules are visible by name: `YabStore` (a `SQLiteConnection` over the system `libsqlite3`) and `SyncKit` (has a `Journal` type backed by a database handle). The pairing of a SQLite store and a journal resembles Ararat's §5.2/§6.2 design; what Yab's journal records was not established.
- Other frameworks used include `FoundationModels` (weakly linked), `Translation`, `ScreenCaptureKit`, `AuthenticationServices`, `EventKit`, `Contacts` and `MapKit`.

## 2. Workspace model, from Yab's AppleScript dictionary (`Yab.sdef`)

The dictionary is a published interface, so it is the most reliable evidence of Yab's model.

| Class | Properties |
|---|---|
| window | id, name, index, minimized, visible, active tab, active tab index, **active space**, mode (`incognito` or `normal`; private tabs are never listed), incognito |
| tab | id, title, URL, loading, **location**, space |
| space | id, title, icon (an emoji), color (hex, for the light look) |

- A tab's `location` is described "as Arc says": `topApp` for a pin (a favorite), `pinned` for a kept tab, `unpinned` for today's tab. Yab therefore keeps Arc's three-container vocabulary, which matches Ararat's model and Arc importer (`pinned` / `unpinned` containers, `topAppsContainerIDs`).
- A space carries one colour for the light look; the dictionary exposes no profile per space.
- Commands: `select` (bring a tab to the front, switching to its space), `focus` (a space or a tab), `go back`, `go forward`, `reload`, `stop`, `open small window` (Yab's Little Arc equivalent), `ask` (the ⌘J assistant), `show mail`.

## 3. Class inventory by area

Only Objective-C-visible Swift classes keep their names; 358 such classes were found. Grouped by area:

| Area | Classes |
|---|---|
| Sidebar ("column") | `ColumnView`, `ColumnPage`, `ColumnPages` (probably one page per space), `ColumnOverlay`, `ColumnHand` |
| Spaces | `SpaceTray` (with a `Panel`), `SpacePager`, `SpaceSwipe`, `SpaceAnchor`, `SpaceDrop`, `SpaceForm`, `SpaceWash` |
| Window chrome | `BrowserWindow`, `Browser` (the `WKNavigationDelegate` / `WKUIDelegate`), `LightsRow` (the traffic-light buttons), `WindowBackdropView`, `BarsLayer`, `LoadBar` |
| Edge UI | `EdgeTray`, `FloatEdgeTab`, `EdgeHandle`, `EdgeBlurView` |
| Picture in picture and floating video | `Floater` (with `Controls`, `Scrubber`, `Clock`), `FloatHand`, `FloatLip`, `FloatGlass`, `FloatButton`, `Glider` |
| Peek (link preview) | `PeekView`, `PeekCardView`, `PeekSurfaceView`, `SidePeek`, `StripPeek`, `HeadPeek` |
| Extensions | `ExtensionTab`, `ExtensionWindow`, `ExtensionPanel`, `ExtensionSidePanelPage` |
| Other windows | `LinkWindow` (probably the small window), `PopoutWindow`, `SettingsWindow`, `DevDetachedWindow`, `DocumentPiPPanel` |

- The `Float*` classes belong to floating video, not to the sidebar: `FloatHand` logs a "controls-hover" event, and `FloatLip` tracks `sliding` and `carried` state.
- The floating sidebar's show/hide logic was not located. It lives in Swift closures whose names are stripped.

## 4. Pointer tracking outside the window: `LightsRow`

While the traffic-light row is hovered, `LightsRow` starts an `NSTimer` with a 1/30 s interval on the run loop and installs both a local and a global `NSEvent` monitor. Its handlers read `NSEvent.mouseLocation` and test it against the buttons' rectangles. The diagnostic reasons it records include "no window", "button window" and "window inactive/nonkey".

This is the only class besides floating video (`FloatHand`) that installs a global monitor. It is precedent for the pointer sampling in architecture §7, at 30 Hz rather than display rate. It is not evidence of how the sidebar itself behaves.

## 5. Settings-like strings

- `sidebar.density`, `sidebar.left`, `sidebar.left.round`, `sidebar.right`, `sidebar.right.round`: the sidebar can sit on either side, with a rounded variant, and has a density setting.
- `settings.set.color`, `settings.set.glass`, `settings.set.grain`, `settings.set.sidebar`, `settings.set.transparency`: the appearance settings (colour, glass, grain, transparency, sidebar).
- `tabs.*`: `awake`, `sleep`, `close`, `pin`, `rename`, `reorder`, `tidy`, `group`, `glyph`, `folderEmoji`, `linkFolders`, `meetingFolders`, `researchFolders`, `optShiftFolders`, `todayEveryWindow`.
- Names that look like toggles: `snapToEdges`, `showSidebar`, `hideSidebar`, `turnedSidebar`, `sidebarTabs`, `sidebarPin`.

None of these was confirmed as a `UserDefaults` key; they may be menu or command identifiers. The many `yab.*` dotted strings are icon names.

## 6. Bundled resources

- `skills/`: 42 per-site skills for Yab's assistant (Gmail, Google Docs, Slack, Notion, Linear, GitHub, Jira, password managers and others), plus a `skill-creator`.
- `PageScripts/`, `DevTools/`, `DarkReader/`, `Charm/`, `Google/`, `Metadata.appintents` (App Intents).
- Chrome extensions run through a shim script on WebKit (`yab-shim.js` in the installed extension's folder); its behaviour was not analysed.

## 7. Limits

- Swift function names are stripped except for `@objc` methods, so most logic appears as unnamed functions.
- The Objective-C message analyzer was disabled (section 2 of `yab/README.md`), so calls through `objc_msgSend` are not resolved to their selectors in the decompiled output. Selector stubs can still be followed by hand.
- Static analysis cannot give timing values such as delays and slack widths. Those come from observing Yab (HANDOVER Next 2).
