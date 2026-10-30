# Arc and Dia component inventory (a consolidation of public reverse engineering)

Translated from `arc-dia-components.ja.md` (2026-10-30). The English file is the source of truth from now on.

Created: 2026-10-30. The purpose is to gather material for deciding the component structure of a macOS browser built with a Swift/AppKit UI, an ArcCore-style Chromium fork, and a Rust core. This document does not analyse any binary anew. It uses only the public documents below and, from the local `/Applications/Arc.app`, its `Info.plist`, the file names under `Contents/Frameworks`, and the output of `otool -L`.

- Cra: `docs/arc-reverse-engineering.md` in `VictorKildahl/cra` (hereafter "the Cra document")
- Ardia: `docs/dia-spec.md`, `docs/dia-feature-parity.md`, `docs/omnibox-ux.md`, `docs/research/*.md`, and `docs/architecture-review.md@2713787d` in `mantrakp04/ardia` (hereafter "the Ardia documents"). To reinforce Section 4, `docs/ardiacore-spike.md` and the @2713787d versions of `docs/research/chromium-ui-layer.md` and `chrome-hosted-window.md` were also consulted

## Terms and markers

| Term | Meaning |
|---|---|
| space | The unit of switching in Arc's sidebar. It has two containers, pinned and Today |
| pinned | The per-space section of pinned tabs |
| Today | The per-space section of unpinned tabs (`unpinned` in the data) |
| favorites | The tile row at the top, one per profile and shared by all spaces (`topApps` in the data) |
| folder | Nesting of sidebar items (`list` in the data) |
| archive | Where closed and automatically cleaned-up tabs are stored (`StorableArchiveItems.json`) |
| ARC_* | Prefix of Arc's bundle names and Swift module names |
| ArcCore | The Chromium framework bundled with Arc and Dia (`ArcCore.framework`) |
| seam | A function or class declared in Chrome's `chrome/browser/ui` whose implementation an embedder can replace |

Evidence markers are kept as in the source documents. **[O]** observed (confirmed in shipped artefacts, data files, or screen recordings of the real app), **[I]** inferred, **[U]** unknown, **[?]** unconfirmed (the Cra document's notation). For statements in the Ardia documents, which carry no markers, the kind of source (binary disassembly, recording, Ardia's implementation) is stated in prose. Statements beginning with "Cra:", "Ours", or "Ardia" are decisions on the reimplementation side and are not treated as facts about Arc or Dia.

---

## 1. Overall structure of Arc

### 1.1 Facts observed in the local Arc.app (primary observations of this study)

- **[O]** `CFBundleShortVersionString` 1.170.0, `CFBundleVersion` 89123, `BCNYBuildDate` 21 Oct 2026, `BCNYCommitInfo` Release-89123-9f5625b…, bundle id `company.thebrowser.Browser`, `NSPrincipalClass` `Arc.BrowserApp`, `LSMinimumSystemVersion` 13.0.0, SDK macOS 26.4 (Xcode 26.4.1).
- **[O]** URL schemes are `http`, `https`, `mailto`, and `arcBrowser`. Document types are PDF, HTML, and XHTML (Viewer).
- **[O]** Sparkle settings: `SUFeedURL` https://releases.arc.net/updates.xml, `SUEnableAutomaticChecks` true, `SUAutomaticallyUpdate` true, `SUScheduledCheckInterval` 28800 (8 hours).
- **[O]** `Contents/Frameworks` contains the following 10 items.
  - `ArcCore.framework` (executable 478.6 MB, with `Helpers/`, `Libraries/`, and `Resources/`)
  - `Sparkle.framework` (current version 2.9.4), `Lottie.framework`, `Sentry.framework`
  - `FirebaseFirestoreInternal.framework`, `grpc.framework`, `grpcpp.framework`, `openssl_grpc.framework`, `absl.framework`
  - `libswiftCompatibilitySpan.dylib`
- **[O]** `otool -L Contents/MacOS/Arc` (universal x86_64 and arm64): directly links `@executable_path/../Frameworks/ArcCore.framework/Versions/A/ArcCore` (compatibility/current version **8078.0.48**), Lottie, and Sparkle. On the system side: AppKit, **SwiftUI**, Combine, CoreData, CloudKit, Metal/MetalKit, QuartzCore, WebKit, PDFKit, ScreenCaptureKit, AVKit, NaturalLanguage, GameplayKit, CryptoKit, UserNotifications, MetricKit (weak), and others. The linked UI frameworks are AppKit and SwiftUI; no React Native framework is linked (whether anything is statically linked cannot be determined from `otool -L`).
- **[I]** ArcCore version 8078.0.48 corresponds to Chromium branch 8078. In Dia's ArcCore, compatibility version 8037.0.58 corresponds to Chromium 154.0.8037.58 (Arch › B, chrome-hosted-window.md), so by the same rule this is Chromium ?.0.8078.48; that it is the 156 line is an inference. The Cra document mentions Chromium 156.0.8078.48, but the context is Cra's own CEF validation, and it does not state that Arc's ArcCore is this version.
- **[I]** The bundling of FirebaseFirestore and grpc and the linking of CloudKit are consistent with the Cra document's "sync via CloudKit + Firebase" (Other observed features).

### 1.2 The app itself (the Swift shell)

- **[O]** A native Swift app whose UI is AppKit. It has `SidebarViewController`, `SidebarDockViewController`, NSCollectionView layouts, `CommandBarTextField`, and `SuggestionsView` (Cra document › Architecture).
- **[O]** State management is TCA (ComposableArchitecture): `Store<WindowState, WindowAction>` and view stores (Cra document › Split View › Where it lives). `Arc.AppReducer` and `Arc.WindowsReducer` hold a `LinkRoutingClient` (Air Traffic Control).
- **[O]** Screen components are mainly AppKit view controllers based on `XiblessViewController<NSView>`, and SwiftUI is also linked (`otool -L`). The source documents do not say which screens are SwiftUI **[U]**.
- **[O]** Web content is embedded Chromium, and `User Data/Default` is a Chrome profile (History, Cookies, Extensions, Preferences) (Cra document › Architecture).

### 1.3 The "ARC" framework and feature modules

The Cra document says "Framework "ARC" with feature modules" (Architecture). However, the local `Contents/Frameworks` has no `ARC.framework`. What the Cra document cites as evidence are resource bundles such as `ARC_CommandBar.bundle`, `ARC_PictureInPicture.bundle`, `ARC_SiteControlCenter`, and `ARC_WindowThemeUI`, and Swift module names. It is therefore reasonable to read ARC as the namespace of a set of modules statically linked into the executable **[I]**.

The module and type names that appear in the source documents are grouped by function below (all from [O] statements in the Cra document; Dia names come from the Ardia documents).

| Area | Modules and types (Arc) | Source heading |
|---|---|---|
| General UI | `ARCUI` (`SplitViewController`, `PageSwipeController`, `VelocityTracker`, `GradientView`) | Split View › Where it lives / Dia space paging |
| Window | `WindowContents` (`SplitViewState` etc.), `SharedWindowFeature` (`WindowAction`, `SidebarCellCloseButtonConfiguration`, `WindowData+ContentReparenting`) | Split View / Closing vs removing pinned tabs / A tab open in two windows |
| Data model | `BaseModels` (`SidebarSplitViewData` etc.), `SidebarDataStore`, `StorableSidebar` | Architecture / Split View › Data model |
| Sidebar | `SidebarUI` (`SplitViewCellState`), `SidebarDock`, `SidebarBanner`, `HomeButton` (Library) | Space dock / Library / Software updates |
| Command bar | `CommandBar` (`ARC_CommandBar.bundle`), `TypeTravel` | Command bar |
| Space appearance | `SpaceStyleEditor`, `ARC_WindowThemeUI` | Spaces / Ardia feature parity §21 |
| Small windows | `LittleBrowser` (Little Arc), `ModalItemSwitcher` (tab switching) | Little Arc / Tab switcher |
| Tooltips | `ArcTooltip` | Closing vs removing pinned tabs |
| Downloads | `DownloadsUI`, `ADKClient/DownloadManager.swift` | Downloads |
| Popups | `ADKClientLive.BrowserExtensionsPopUpManager`, `Arc.BrowserExtensionWindow` | Extension popups |
| PiP | `PictureInPicture` (`ARC_PictureInPicture.bundle`) | Picture in Picture |
| Updates | `SoftwareUpdaterClient` (own implementation of Sparkle's `SPUUserDriver`) | Software updates |
| Other | `HoverCards`, `Archive`, `ARC_SiteControlCenter`, Boosts, Easels | Architecture / Site Control Center |

`ADK` appears as the name of the layer that calls ArcCore from the Swift side (`ADK.ContextDownloadDelegate`, `ADKClientLive`) **[I]**.

### 1.4 ArcCore (the Chromium side)

About Arc's ArcCore, the source documents show only the following.

- **[O]** ArcCore's browser delegate hands extension popups to Swift as web contents: `browser:didOpenExtensionPopup:webContents:`, `browser:didResizeExtensionPopup:size:`, `browser:didCloseExtensionPopup:`. `createPopupBrowser:withDelegate:` and `didCreateNewBrowser:`, `ChromiumBrowser.browserType: {normal, popup, pictureInPicture}` (Cra document › Extension popups).
- **[O]** `arc::VideoPiPCoordinatorImpl(content::VideoPictureInPictureWindowController*)` wraps Chromium's video PiP (Picture in Picture).
- **[O]** The strings of Chrome's standard DevTools embedder (`&can_dock=true`, `setInspectedPageBounds`) are present, and Arc uses Chrome's `DevToolsWindow` as is (DevTools docking, Arc's way).
- **[O]** Split view does not exist on the Chromium side. ArcCore contains the string for Chrome's standard `tabs.createSplit`, but Arc's UI does not reference it (Split View › Where it lives).
- **[O]** Downloads reach Arc's view via ADK, and Chrome's download bubble does not appear (Downloads).

The Ardia documents examine Dia's ArcCore in more detail (Section 4). Whether Arc's ArcCore has the same ObjC API that Dia's ArcCore has (146 classes, generated from mojom, `Headers/arc/browser/objcpp`) is not confirmed in the source documents **[I]**.

### 1.5 Role of the bundled frameworks

| Framework | Role | Evidence |
|---|---|---|
| ArcCore | Chromium (including `//chrome`) and Arc's own C++ layer | Local otool [O], Cra document |
| Sparkle 2.9.4 | Automatic updates. The UI is Arc's own, via `CustomUserDriver` | Info.plist [O], Cra document › Software updates |
| Lottie | Animations (such as the heart when an update completes) | Cra document › Software updates [O] |
| Sentry | Crash reporting | File name only [O], purpose is [I] |
| FirebaseFirestore + grpc family | Sync | File names [O], purpose is [I] from the Cra document's statements |

---

## 2. Component inventory

Source abbreviations: **Cra** = `VictorKildahl/cra` › `docs/arc-reverse-engineering.md`, **Spec** = `mantrakp04/ardia` › `docs/dia-spec.md`, **Parity** = `docs/dia-feature-parity.md` in the same repo, **Omni** = `docs/omnibox-ux.md` in the same repo, **Arch** = `docs/architecture-review.md@2713787d` in the same repo. Line numbers refer to the retrieved versions.

### 2.1 Arc

| Component | Role | Observed evidence | Source |
|---|---|---|---|
| Sidebar (main) | Stacks favorites, the space header, the tab list, and the dock vertically | [O] Width 328 pt (`sidebarWidth` in `StorableWindows.json`), `sidebarMode` is `anchored` (the binary also has `floating`, `hidden`, and `collapsed`). [O] Rows have a 40–41 pt pitch, 14 pt titles, 16 pt favicons, and about 18 pt indentation for nesting. [O] The list is a single outline (`sidebarAllTabList`); pinned, the divider, and Today scroll together, while favorites and the space header stay fixed. [O] The top and bottom border lines are 1 pt, about 5% black, and fade in and out over 0.2–0.3 s depending on the scroll position. [?] Whether the scroll position is kept when switching spaces | Cra › Window state (L43), Visual reference (L96), Sidebar scrolling (L724) |
| Sidebar header (toolbar hidden) | Places the URL and navigation at the top of the sidebar when the toolbar is hidden | [O] The setting is `topBarURLEnabled` (View ▸ Show Toolbar). [O] The first row has the traffic lights, sidebar toggle, and back/forward/reload; the second row has a 36 pt URL pill showing only the host. [I] The extensions, copy, and Site Control Center buttons appear on header hover (`isHeaderViewHovered`) | Cra › Sidebar header with the toolbar hidden (L1189) |
| space | The unit of switching in the sidebar. Has a profile and a theme | [O] `SpaceModel`: id, title, profile, `containerIDs`, `customInfo.iconType` (`emoji_v2`/`emoji`), `customInfo.windowTheme`. [O] UI: `SidebarDock` (switcher at the bottom), `SidebarPagingContainer` (horizontal paging), `SpaceCreation`, `SpaceStyleEditor` (color pad, dial, color picker), `SpaceIconPicker`, `SpaceManagement` (reordering). [O] Actions: `focusNextSpace`/previous, ⌥⌘→/⌥⌘←, ⌃N | Cra › Sidebar data model (L17), Spaces (L47), Key bindings (L73) |
| Space dock | Space switching at the bottom of the sidebar | [O static] `SidebarDock.SidebarDockView` is an NSCollectionView, and reordering uses the collection view's drag and drop. [O AX] Each space is a 36×34 AXButton, laid out at a 34 pt pitch with no gaps. A 32×32 Library button on the left and a 32×32 "+" on the right. [O] The pressed fill is about 7.8% white, with corners of about 6 pt. [U] The hover fill. [O] "Drag to Reorder Space" belongs to `Arc.SpaceControlsView`, not the dock | Cra › Space dock (L1490) |
| pinned | Per-space pinned tabs. Each holds a saved URL as its "home" | [O] Each space has one pinned container, ordered by `childrenIds`. [O] A pinned tab keeps `savedURL`/`savedTitle` as its home. Strings: `resetTab`, `replacePinnedTab`, `PinnedTabNavigationProfile`, `renamePinnedTabsEnabled=1`. [O live] The hover button on the current tab is "—" ("Close and Keep Pinned ⌘W", unloads it and keeps it pinned); on others it is "✕" ("Archive this tab"). [I] Loaded background pinned tabs also show ✕. [O] 1.170 adds collapsing of the pinned section (`collapsePinnedSection`, per-window `spacesWithCollapsedPinnedSections`). [I] Clicking the space name toggles it. [O] A pinned tab that has navigated away from its home shows the host on an 11 pt second line. [?] The wording of the pinned tab context menu | Cra › Sidebar data model (L31–41), Closing vs removing pinned tabs (L748), Sidebar icons (L664) |
| Today | Per-space unpinned tabs | [O] Each space has one unpinned container. [O] The divider is `UnpinnedSectionDividerCellView` (containing `SidebarClearButton`). State `clearTabAction` (`clearAll`, `clearOthers`, `tidyAndClear`), `buttons` (`clear`, `moveToMainWindow`, `custom`). It has no hover state; the button is always shown together with the section. The menu item is "Clear Unpinned Tabs" (⇧⌘K), with Undo offered in a toast. According to Arc's 2022 release notes, the selected tab and tabs playing media are kept | Cra › Sidebar data model (L33), Spec › Arc note: Clear above the unpinned tabs (L279) |
| favorites | Per-profile tile row, shared by all spaces | [O] One `topApps` container per profile (`topAppsContainerIDs`). [O] Tiles are 47 pt high with 8 pt gaps and 13 pt corners. Unselected is the sidebar color ×0.955; selected is about 38% white with a 2 pt inner border. [O] The yellow-and-black dashed ring appears only on keyboard selection | Cra › Sidebar data model (L29), Chrome metrics re-measured (L444) |
| folder | Nesting of sidebar items | [O] `SidebarItem.data.list {}`, optional `customInfo.iconType`, and `automaticLiveFolderData` for GitHub live folders. [O] Nesting via `parentID`; open/closed state in per-window `expandedItems`. [O] The icon is a `folder` outline (toolbar color) over `folder.fill` (the theme color moved 80% toward white) | Cra › Sidebar data model (L26), Window state (L44), Live re-fit (L522) |
| archive | Storage and restoration of closed and automatically cleaned-up tabs | [O] `StorableArchiveItems.json`: `archivedAt`, `reason` (`manual`/`auto`), `source` (`space{id}`/`littleArc`/`standaloneSidebar`/`unknown`), `sidebarItem` (a copy of the item). [O] Auto-archive thresholds: `twelveHours`, `twentyFourHours`, `sevenDays`, `thirtyDays` (per profile). [O] Actions: `viewArchive`, `clearArchive`, `reopenClosedTab`, `resetSpace`, `archiveTab` | Cra › Archive (L52) |
| Library | Lists of archive, downloads, media, and so on | [O static] Not a separate window but window state (`WindowState+Library.swift`), with pages under `HomeButton/Pages/{Archive,Downloads,Media,…}`. It does not close on an outside click. [O] When opened it replaces the whole sidebar and widens it from 347 to 417 pt (a 113 pt rail + the list). [O] It remembers the last opened page. [O] Hovering the button shows the downloads list (after 0.2 s, rows appear from below at 25 ms intervals). [U] Whether the list column width is fixed, and the open/close curve | Cra › Library (L1518), Arc's downloads list (L1450) |
| Command bar | Unified entry point for URL input, search, tab switching, and running commands | [O] Entry points: `keyboardShortcutT`, `keyboardShortcutL`, `sidebarDoubleClick`, `sidebarNewTabButton`, `littleArcPlaceholderClick`, `topbar`, and others. [O] Result kinds (archetypes): `tab` (Switch to Tab, with `customTitle`), `chromiumHistory`, `chromiumSearchWhatYouTyped`, `chromiumSearchSuggestion`, `chromiumNavigateWhatYouTyped`, `chromiumSearchHistory`, `chromiumNavigateSuggestion`, `chromiumBookmark`, `chromiumSearchOtherEngine`, `chromiumSearchCalculatorAnswer`, `topDomain` (the bundled `popularDomains.json`), `typeTravel` (`menuItem:`, `focusSpace:`, `moveToFolder:`, `openFolder`, `webContentExtension:`), `askGPTWhatYouTyped`, `siteSearch`, `staticQuerySuggestions`. [O] Ranking signals: `recentlySwitchedToTabs` (last 10 per tab), `queriesToSelectedArchetype` (learns input prefix → selected kind), `typeTravelUsage` (frequency and last 15), `siteEngagementScore`, `fuzzySearchConfidence`, hotWords match rate, title/URL match rate and position, recency, importance, a `customTitlePrefix` bonus, `veryRecentTabOrDocumentBoost`, `derankCurrentItemURL`, `dedupByTitleAndHostList`. [U] The weights (CoreML `CommandBarRankingTensor`). [O] Appearance: about 766 pt wide, 60 pt input row, 50 pt result rows, ordered completion row → input as typed → matches, selected row in the space's color. ⌘L edits inline when the toolbar is shown | Cra › Command bar (L57), Visual reference (L105) |
| Type travel | Runs menu items, spaces, and folders from the command bar | [O] Example triggers "Go to Sidebar Item 3", "3. tab". `toggleBetweenTypeTravelAndCommandBar`. Split view candidates (AddLeft/Right/Top/BottomSplit etc.) | Cra › Command bar (L64, L70), Split View › Commands (L366) |
| Little Arc | A small window without a sidebar. Receives links from external apps | [O] `StorableWindows.json` has `little { profile, session { entryPoint { externalLink } }, preferredFrame }`. Closing it sends it to the archive with `source: littleArc`. `LittleBrowserWindow_size` keeps the last size. [O] A single 46 pt bar, 10 pt corners. The bar uses the dark color scheme of the default profile (not the focused space). [O] An "Open in <space> ⌘O \| ⌄" button; ⌄ opens `LittleBrowserMoveMenu` (search and select a space). [O] ⌥⌘N opens an empty Little Arc. [O] On opening it expands from a small rectangle under the pointer to full size in about 120 ms, with no fade. [O] ⌘L/⌘T show a 500 pt wide command bar inside the window | Cra › Little Arc (L464) |
| Air Traffic Control (LinkRouting) | Routes URLs arriving from outside to a space or Little Arc by rules | [O] "Air Traffic Control…" under Settings ▸ Links opens a 508×500 sheet. A rule has two rows ("🔗 URL" + match style + text, "↳ Open in" + destination). [O] Saved in `StorableLinkRouting.json` (Section 3). [O] Types: `LinkMatchingRule`, `LinkSourceComponent.ComponentType = urlMatch(style, String)`, `LinkDestination = space(ProfileDestination) \| littleArc(ProfileDestination)`, `ProfileDestination = mostRecent \| space(UUID) \| profile(…)`. [O] "Links from other apps open in Little Arc" is the default destination itself. [O runtime] Before comparison, case, the scheme, and a leading `www.` are stripped from both the URL and the rule. "Contains" also looks at the query and fragment. "Is equal to" compares only host and path, ignoring a trailing `/`. Rules are evaluated top to bottom, and the first match decides. A space destination creates a foreground tab at the top of Today and switches the window to that space. [O] A meet.google.com → Most Recent Space rule is seeded once. [U] The semantics when one rule has multiple conditions (any or all) | Cra › Air Traffic Control (L1276) |
| Split view | Places up to 4 panes in one window | [O] Lives entirely in the Swift shell, not on the Chromium side. `ARCUI.SplitViewController` is its own layout engine that does not use NSSplitView (`SplitViewControllerLayout` is a pure function that produces frames from a context). [O] In the sidebar it is an item called `splitView`, like a folder, whose children are the pane tabs (Section 3). [O] Pane size is `widthFactor`; during resize the web content width is fixed and aligned to an edge (`lockContentWidth`, `ContentResizeMode {intrinsic, throttle, locked}`). [O] Drag and drop: `DropTarget = replaceContent(index) \| insertContent(index)`; one can also be created by dropping a sidebar tab onto the left or right half. [O] Entry point recorded in `SplitViewEnteredSource` (plusButton, dragAndDrop, menu, alternateClick (⌥-click), typeTravel, etc.). [O] Error `splitViewMaximumPanesExceeded`. [I] Limit of 4 panes. [O live] 10 pt between panes, with a ← → ✕ toolbar on each pane. [U] The feel of resizing by dragging the boundary (on the real app it entered pane move mode) | Cra › Split View (L221–391), Split View, observed live (L595) |
| Peek (links) | Temporarily opens a link in a card over the window | [O strings] The Cra document gives only the feature name "Peek" and the key binding identifier `peekEmail`. The description of behaviour (opens on ⇧-click) is the "as in Arc" statement in Ardia's Parity table and is not based on recordings or analysis of Arc. [U] Dimensions and motion of Arc's Peek | Cra › Other observed features (L117), Key bindings (L81), Parity §1 Peek row (L219) |
| Peek (sidebar) | When the sidebar is hidden, placing the pointer at the window's left edge overlays the sidebar | [O recording] A floating panel inset 5 pt from the window's left, top, and bottom, the same width as the pinned sidebar (227.5 pt), dark, with a 0.5 pt light border. It enters from the edge with a spring (response 0.185 s, damping 0.77) and no fade, and leaves with an ease-in-out of about 150 ms. The sidebar button on the panel switches immediately to the pinned sidebar | Spec › Arc note: hiding the sidebar with the address bar in it (L258) |
| Profiles | Mapping between Chromium profiles (which separate cookies etc.) and spaces | [O] Only the mapping in the data is known: `SpaceModel.profile`, `topApps{profile}` (favorites are per profile), `ProfileDestination`, `PinnedTabNavigationProfile`, Little Arc's `profile: {default: true}`, and per-profile auto-archive thresholds. [O] Library downloads can be filtered by profile. [O] The space header has an "Edit Space profile" tooltip. [U] Arc's profile management screen | Cra › Sidebar data model, Archive, Little Arc, Downloads (L1408), Closing vs removing pinned tabs (L786) |
| Key bindings | The list of actions, default keys, and user overrides | [O] Data format in Section 3. [O] Action identifiers (72 of them, such as `newTab`, `archiveTab`, `pinTab`, `toggleSidebar`, `focusNextSpace`, `addSplitView`, `showLittleArc`, `peekEmail`, `moveToSpace`, `replacePinnedTab`). [O] Default keys read from the menus via Accessibility (⌘T, ⌘L, ⌘S = Hide Sidebar, ⇧⌘D = Hide Toolbar, ⌘D = Pin/Unpin, ⌃⇧= = Add Split View, ⌥⌘N = Little Arc, ⇧⌘K = Clear Today, ⌃Tab = most recent tab, etc.) | Cra › Key bindings (L73), Developer Mode, shortcuts (L203) |
| Settings screen | Arc's Settings | [O] Only part of it can be confirmed in the source documents: the Air Traffic Control card and sheet under Settings ▸ Links, "Automatically update my Arc" (`automaticallyUpdateArc`), "Enable Picture in Picture when you leave a video tab", and `topBarURLEnabled` (View menu). [O] Per-space settings open from the space header ("Edit Space theme", "Edit Space profile", the space options tooltip, `spaceHeaderContextMenu`). [O] Developer Mode is per site and switches the toolbar configuration (exit with ⌃D). [U] The structure and pane list of Arc's Settings window | Cra › Air Traffic Control, Software updates (L1263), Picture in Picture (L539), Closing vs removing pinned tabs (L786), Developer Mode (L203) |
| Theme (blendedGradient) | Per-space window color, gradient, noise, and translucency | [O] `customInfo.windowTheme = blendedGradient { baseColors[2], overlayColors, modifiers { noiseFactor, intensityFactor, overlay: "grain" }, wheel: analogous \| complimentary, translucencyStyle: light \| dark }`, light/dark `appearanceBased` variants, and `semanticColorPalette` (`foregroundPrimary`/`Secondary`/`Tertiary`, `backgroundExtra`, `maxContrastColor`, `hover`, etc.). According to Ardia's Parity table, the Swift type information in Arc 1.167 additionally has a third overlay color, textures (grain, sand, denim, tweed), `windowAppearance`, and an opaque `basicColor`. [O] The toolbar color is the page's `theme-color`, or, if absent, the body/html background color. [O] When inactive, the background stops being translucent and becomes a flat color | Cra › Sidebar data model (L19–22), Hover, toolbar colour (L587), Picture in Picture hover controls (L876), Parity §20 Arc theme import, §21 Custom profile theme |
| Site Control Center | Per-site controls opened from the slider button at the right end of the toolbar | [O] A 262-wide AXPopover. Buttons for share, New Boost, region capture, and full capture; a grid of extensions (with pin badges); toggles for Developer Mode, ad blocking, and auto PiP; a "Secure" pill and a More menu (Clear Cache, Clear Cookies, All Site Settings, etc.) | Cra › Site Control Center (L1368) |
| Tab switcher | Cycles through recent tabs with ⌃Tab | [O] `ModalItemSwitcher`. Five tabs of the focused space, newest first by `timeLastActiveAt`. Releasing ⌃ switches, Esc cancels, and a short press switches without showing the panel. No animation | Cra › Tab switcher (L1463) |
| Tab across windows | Handling of the same tab opened in two windows | [O static] Moves the page between windows (`reparentWindowContent`). The side it was moved from shows a blurred snapshot placeholder (`BlurredSnapshotView`). [U] The blur radius and when it fires | Cra › A tab open in two windows (L1551) |
| Extension popups | Shows extension popups in a separate window | [O] ArcCore → Swift delegate (Section 1.4), `Arc.BrowserExtensionWindow`, autosaves the frame after moving. [I] A separate window the user can drag. [O] Bundles a list of password manager extension IDs | Cra › Extension popups (L1326) |
| Downloads | Display of downloads and storage in the Library | [O] Does not use Chrome's download UI; shows them in its own view via ADK. An animation flying along a parabola to the Library button (about 1.10 s); the bin disappears after 30 s | Cra › Downloads (L1404), Arc's download animation (L1424) |
| PiP | Wraps Chromium's video PiP in an Arc window | [O] `NSFloatingWindowLevel`, 6 pt corners, closes when the source tab's window becomes key. [U] Layout of the hover control buttons | Cra › Picture in Picture (L527), Picture in Picture hover controls (L857) |
| Updates | Sparkle with its own update UI and a sidebar banner | [O] The settings in Section 1.1, `CustomUserDriver`, `SidebarBanner` ("An update is ready!"). [U] The value of the remote flag for automatic relaunch | Cra › Software updates (L1227) |
| Tooltips | Custom tooltips | [O] `ArcTooltipConfiguration { content, keyboardShortcut, preferredAnchor, presentationBehavior, maxWidth, colorPalette }`. [O live] Appear 1.60 s after the pointer comes to rest | Cra › Closing vs removing pinned tabs (L767) |

### 2.2 Dia (for comparison)

| Component | Role | Observed evidence | Source |
|---|---|---|---|
| Sidebar | Lists tabs vertically | Dia 1.50.1 binary: `TabListCollectionViewLayout`, default width 190 pt, rows 37 pt (background 34 pt); the pinned dock is fixed as `TabDockView`, with a 1 pt line and a scroll area below it (Section 5) | Spec › Sidebar rows (1.50.1) |
| pinned (dock) | Tiles at the top. The selected color is derived from the icon | 1.50.1 binary: `TabDockItemView`, `TabIconProcessorImpl._generateTheme` (chooses blur type or template type from the color variance of the icon) | Spec › Sidebar |
| Tab groups | Corresponds to Arc's folder | 1.50.1 recordings and color tokens. A frame is shown only while hovering. According to the Parity table, Dia's groups cannot be nested (Arc's folders can) | Spec › Sidebar, Parity §3 |
| Profiles and paging | Pages horizontally between per-profile sidebars | 1.50.1 binary: `ARCUI.PageSwipeController`, `TabSidebar.PagingContainerViewController`, `SidebarProfileIndicatorButton` (profile name in the header; icon only below 52 pt) | Spec › Profile paging, Research › dia-profile-swipe-binary.md |
| space | Switching below the profile level | The two descriptions disagree. Spec says `spaces-ui-enabled` is on by default in 1.50.1 and there is a dot switcher in the footer (`SpaceSwitcherView`). Parity §5 says "flag-gated; changelog says Dia has no Spaces". This document does not decide between them | Spec › Profile paging, Parity §5 |
| Command bar | Entry point for URL, search, and Chat | Dia uses Chromium's `AutocompleteController` under its own Swift UI (`ArcAutocompleteMatch`, `autocomplete:cursorPosition:preventInlineAutocomplete:`, `deleteAutocompleteMatch:`, `SwitchToTabProvider`). Clicking the URL opens a panel overlapping the toolbar (about 890 wide) | Omni opening section, Spec › URL click → command panel |
| Split view | Places panes side by side | Parity §6 says up to 3 panes (Arc is inferred to be 4). `DragDrop.SplitTargetView` ("Add left split"/"Add right split") | Parity §6, Spec › Dragging tabs and split targets |
| Settings screen | Dia's Settings | Cra's observation of Dia 1.54.2: 778×509, `NSSplitViewController` with a unified toolbar; panes are Account, Tabs, Privacy, Profiles, Skills, Apps, Shortcuts, Advanced. Shortcuts has a search field, filters (Customized/Conflicting), and a detail area | Cra › Dia Settings window (L1121) |
| Window background | Translucency and theme | 1.50.1 binary: `NSVisualEffectView` in `WindowTreatment` (material 29/13) + base tint + profile gradient. The Metal `WindowThemeUI` is Arc code and is not called in 1.50.1 | Spec › Window translucency |
| Import | Import from other browsers | Cra's observation of Dia 1.54.2: `ImportFlow`, importers for Chromium, Firefox, and Safari, selection of Arc spaces (`ArcPreviewContentView`) | Cra › Dia import onboarding (L881), Dia onboarding steps (L952) |

---

## 3. Data formats (the granularity needed to import from Arc)

All are JSON under `~/Library/Application Support/Arc/`, described by the Cra document from reading the user's own data (this study did not read them).

### 3.1 Common encoding

- **[O]** Flat arrays are used instead of dictionaries: `[id, object, id, object, …]`. `containers`, `items`, and `itemWidthFactors` have the same shape.
- **[O]** Swift enums are written in the form `{ "<case>": { "_0": <value>, "_1": <value> } }` (e.g. `{space: {_0: {mostRecent: {}}}}`).

### 3.2 StorableSidebar.json

- **[O]** `sidebar.containers` = `[ {global}, { spaces, topAppsContainerIDs, items } ]`.
- **[O] space** (an element of `spaces`): `id`, `title`, `profile`, `containerIDs = ["pinned", <id>, "unpinned", <id>]`, `customInfo.iconType` (`emoji_v2`/`emoji`), `customInfo.windowTheme` (the theme row in Section 2).
- **[O] item** (an element of `items`): `id`, `parentID`, `title` (non-null only when the user has renamed it, and takes priority over the page title), `childrenIds[]` (order), `isUnread`, `createdAt`, `originatingDevice`, and `data`, which is exactly one of the following.
  - `tab { savedURL, savedTitle, savedMuteStatus, timeLastActiveAt, activeTabBeforeCreationID, referrerID?, liveItemID? }`
  - `list {}` (folder. Optional `customInfo.iconType`, `automaticLiveFolderData`)
  - `itemContainer { containerType: topApps{profile} | spaceItems{spaceID} }`
  - `splitView { itemWidthFactors: [<id>, <factor>, …], layoutOrientation: horizontal|vertical, focusItemID, timeLastActiveAt, customInfo: {iconType}? }`. Children are in pane order via `childrenIds`. An untouched split has only one entry, `[firstChild, 0.5]`; after a drag it has all entries, summing to 1.0. [I] Missing factors split the remainder equally. A split with zero children can remain, and Arc repairs it on sync
  - [O strings only] `easel`, `arcDocument`, and `tabGroup` also exist
- **[O]** Favorites are the `topApps` container (one per profile); each space has one pinned container and one unpinned (Today) container. Folder nesting is via `parentID`.
- **[O]** Sidebar favicons are stored in `SidebarItemsFaviconCache` as 32×32 PNGs named `md5(item id)`.

### 3.3 StorableWindows.json

- **[O]** Each element of `windows[]`: `sidebarWidth`, `sidebarMode`, `focusedSpaceID`, `lastFocusedSpaceID`, `expandedItems` (folder open/closed state, per window), `itemLastActiveDates`, `itemCreatedDates`, `splitViewState` (only `windowContentIDs` and `focusedContentID`; orientation and widths are rebuilt from the sidebar items), `windowContents`, `spacesWithCollapsedPinnedSections`.
- **[O]** Little Arc is `little { profile: {default: true}, session: { entryPoint: { externalLink } }, preferredFrame }`.

### 3.4 StorableArchiveItems.json

- **[O]** Element: `{ archivedAt, reason: manual|auto, source: space{id}|littleArc|standaloneSidebar|unknown, sidebarItem: <copy of an item from 3.2> }`.
- **[O]** Auto-archive thresholds: `twelveHours`, `twentyFourHours`, `sevenDays`, `thirtyDays` (per profile).

### 3.5 StorableKeyBindings.json

- **[O]** Action = `{ identifier, name }`, binding = `{ keyEquivalent, deviceIndependentModifierFlags }`, `priority`, `typeTravelTriggers`. Stores the user's overrides.
- **[O]** `item1`–`item9` = "Go to Sidebar Item N", modifier `1048576` (= `NSEventModifierFlagCommand`).
- The modifier flags can be read as values of AppKit's `NSEvent.ModifierFlags` **[I]**.

### 3.6 StorableLinkRouting.json (Air Traffic Control)

- **[O]** `{ rules: [ { id, sourceComponents: [ { id, componentType: { urlMatch: { _0: {contains: {}} | {matches: {}}, _1: "meet.google.com" } } } ], destination } ], defaultDestination, version: 1 }`.
- **[O]** Destinations: `{space: {_0: {mostRecent: {}}}}`; a specific space is `{space: {_0: {space: {_0: "<space id>"}}}}`; Little Arc is `{littleArc: {_0: …}}` (the inner value only selects a profile). `matches` corresponds to "Is equal to" in the UI **[I]** (the names do not line up: storage uses `matches`, the analytics type uses `equals`, and the UI says "Is equal to").

### 3.7 StorableCommandBarAdditionalRanking.json

- **[O]** Named as the location of the command bar's ranking training data. Its internal structure is not described in the source documents **[U]**. The signal names are in the command bar row of Section 2.

### 3.8 Other

- **[O]** Chromium profiles are under `User Data/<profile>/`. Extensions are in `extensions.settings` in `Secure Preferences`; manifests of Web Store extensions have a `key`, so copying and loading them yields the same ID. Pins are in `extensions.pinned_extensions`.
- **[O]** The PiP position is `LastPiPPosition` (JSON) in defaults.
- Dia: **[O]** `StorableProfileContainers.json` (per-profile containers, `window`/`favorites`, `tabs[].contents[].variant = webContent{_0:{title,url}} | newTabPage`), `StorableAutoArchive.json` (Cra › Dia 1.54).
- Ardia has a parser and fixtures for Arc themes (`state/import/arcTheme.ts`, `packages/import/fixtures/arc-themes`). This study did not read the code.

---

## 4. Insertion points on the Chromium side (Dia's ArcCore)

### 4.1 Structure (read from Dia 1.49.1–1.50.1)

- ArcCore contains not only content but also `//chrome`. It exports `ChromeMain` and bundles Chrome's helper apps (Browser Helper, Renderer, GPU, Alerts). All helpers are child processes of Dia (Research@2713787d › chromium-ui-layer.md › How Dia embeds Chromium).
- It compiles `chrome/browser/ui/browser.cc` and `tabs/tab_strip_model.cc` but does not include `views/frame/browser_view.cc`. In other words, it uses Chrome's `Browser` and `TabStripModel` but not the Views window frame (Arch › B › What Dia does).
- Its own `BrowserWindow` implementation is `arc/browser/ui/window.cc`, a plain object without a Views frame. Ardia's design proposal reads from this that "multiple `Browser`s (one per profile) are attached to the same `NSWindow`, and each tab's `WebContentsViewCocoa` is placed directly into Dia's own view tree" (Arch › 5). However, the text does not make clear whether attaching multiple `Browser`s to one window was confirmed in Dia's implementation or is Ardia's design **[I]**.
- The mechanism for placing web content into Dia's own views: `createPaneHostView`, `nativeView`, `attachToPaneHostView:`, and `detachFromPaneHostView:` in `ArcWebContents (Extensions)`. On the ArcCore side, `PaneHostBridge`, `WebContentsPaneHostView`, and `PaneHostCompositorOverlayView`; on the Dia side, `PaneHostSlotCoordinator` and `adoptExistingNativeView(nativeView:)`. Rendering uses Chromium's standard `CALayerHost` path (chromium-ui-layer.md).
- The blur at the top of the window is a `CABackdropLayer` (`LayerEffects.BackdropEffectView`) placed over the web view's `CALayerHost`. The renderer is passed `--enable-blink-features=TopBandColorSampling` (`arc/blink/core/top_band_color_tracker.cc`, for tab coloring) (chromium-ui-layer.md).
- API used from Swift: 146 `Arc*` ObjC classes and 205 public headers (`Headers/arc/browser/objcpp/`). Generated from mojom (`ArcWebContents.h` from `web_contents.mojom`). Services are `ArcBrowserContextHistory`, `ArcBrowserContextAutocomplete` (`-[ArcBrowser autocomplete:…]`), `ArcBrowserContextDownloads`, `ArcBrowserContextExtensions`, `ArcBrowserContextPreferences`, `ArcSessionTab`/`ArcSessionWindow`, and `restoreForeignTab:`. Tab groups created by extensions return to Swift via `ArcBrowserDelegate createTabGroupWithSessionIds:` (Arch › 1, B).
- There are 108 source files under `arc/`, of which 45 are `arc/browser/ui/*.cc` (Arch › B, chromium-ui-layer.md).
- Dia's app side is Swift, SwiftUI, and AppKit, using GRDB (SQLite) for its own model, plus Lottie and Sparkle (Arch › B).

### 4.2 Replaced seams (those whose names are known)

The source documents name the following 10, including `window.cc`. Whether `window.cc` is counted among the 45 cannot be determined from the text, so the remainder is 35–36 and is **[U]**.

| File in `arc/browser/ui/` | Chrome UI it replaces ([I], mapped from the name) | Source |
|---|---|---|
| `window.cc` | `BrowserWindow` (in place of `BrowserView`) | Arch › 5, B |
| `browser_dialogs.cc` | The various dialogs in `chrome/browser/ui/browser_dialogs.h` | Arch › 5, B, chromium-ui-layer.md |
| `permission_prompt_impl.cc` | Permission prompts (bubble, chip) | Arch › 5, B |
| `extension_install_prompt.cc` | Extension install confirmation | Arch › 5, B, chromium-ui-layer.md |
| `password_dialog_prompts.cc` | Password save/update bubbles | Arch › 5 |
| `extensions_container.cc` | The extensions area in the toolbar (`ExtensionsContainer`) | Arch › 5 |
| `location_bar.cc` | `LocationBar` (the embedder side of the omnibox) | Arch › 5, B, chromium-ui-layer.md |
| `autofill_popup_view.cc` | Autofill suggestion popup | Arch › B, chromium-ui-layer.md |
| `side_panel_ui.cc` | side panel | Arch › B |
| `views/overlay/video_pip_coordinator_impl.cc` | The video PiP window | Arch › B (`arc::VideoPiPCoordinatorImpl` is also confirmed in Arc. Cra › Picture in Picture) |

Other files under `arc/` whose names are known are `arc/browser/browser_impl.cc` and `arc/blink/core/top_band_color_tracker.cc`.

### 4.3 What lives outside Chromium (on the Swift side)

From the source documents, the following features are known to be owned by the Swift shell without using Chromium's UI.

- Sidebar, spaces, favorites, folders, archive (the `Storable*.json` side)
- Split view (Arc: does not use Chromium's split feature. Cra › Split View)
- The command bar's UI and ranking (candidate generation is Chromium's `AutocompleteController`. For Arc this is [I] from the archetype names `chromium*`; for Dia it is confirmed in Omni and Arch)
- The downloads UI (via the ADK delegate. Cra › Downloads)
- Extension popup windows (receive web contents from ArcCore's delegate. Cra › Extension popups)

Conversely, the Chrome components used as is are DevTools (the frontend uses `can_dock=true`, and the dock state is in Chrome's prefs) and the Task Manager (according to Parity §23, Dia's Window menu opens Chrome's Task Manager).

### 4.4 Ardia's own insertion points (for reference; not facts about Dia)

Ardia builds an ArcCore-style `ArdiaCore` modelled on Dia and adds small hooks to Chrome files (H1–H6, the window factory in `browser.cc`, `sad_tab_controller.cc`, `external_protocol_handler.cc`). The UI it surfaces to the host is permission prompts (`SetCreatePermissionPromptFunction`), popup blocking, links to external apps, extension install confirmation, extension actions and side panel, device chooser, Cast, and context menus (`docs/ardiacore-spike.md` › Stage 1, Stage 2). This is Ardia's implementation and was not used to estimate the breakdown of Dia's 45 files.

---

## 5. Dia's UI dimensions and motion (the feel of the sidebar and window)

All from Spec (the Dia 1.50.1 binary and the owner's recordings). Values labelled "Ardia" or "Ours" are excluded.

### 5.1 Window and card

| Item | Value | Source |
|---|---|---|
| Default sidebar width | 190 pt (or the saved value, if any) | Spec › Sidebar rows |
| Traffic light centers | x 24.75 / 47.75 / 70.75, y 26.75 (4 pt left and 6 pt up in the top tab layout) | Spec › Sidebar rows, Top tab strip |
| content card | x = sidebar width, top 6, right 7, bottom 7, corner 10 | Spec › Content card |
| Toolbar | Height 41, button centers at 21 / 55 / 92 / 126 from the card's left edge, glyphs are SF Symbols 13 pt | Spec › Toolbar |
| Window background | `NSVisualEffectView` (behindWindow, material dark 29 / light 13) → base tint (black 0.4 / white 0.8) → profile gradient (alpha dark 0.5 / light 0.75, `gradientAlpha` 0.36, neutral 0.12, bottom edge HSL lightness +0.25) → card (#121212 0.5 / white 0.7) | Spec › Window translucency |
| When inactive | AppKit replaces the blur with an opaque fill. Dia does not check Reduce Transparency itself | Same as above |

### 5.2 Sidebar dimensions

| Item | Value | Source |
|---|---|---|
| Header | 46 pt (traffic lights, 6 pt, profile indicator, 2 pt, Downloads) | Spec › Sidebar, Sidebar rows |
| pinned tiles | Height 41, spacing 6, left/right inset 6, top 54, corners about 10 | Spec › Sidebar |
| Tab rows | 37 pt pitch, background 34 pt (1.5 inset top and bottom), left/right inset 6, corner `min(h/3, 10)` | Spec › Sidebar rows |
| Favicon and title | 16 pt favicon at row x 9, title 7 pt to the right of the favicon, 13–14 pt, overflow fades rather than using an ellipsis | Spec › Sidebar, Sidebar rows |
| Scroll boundary | A 1 pt line 4 pt below the dock, appearing on scroll over 0.1 s (cubic-bezier(0.25, 0.46, 0.45, 0.94)) | Spec › Sidebar rows (1.53.0) |
| Footer | 41 pt, Library on the left, a 28 pt band of space dots (12 pt per dot, up to 7 dots) | Spec › Profile paging |
| Hover and selection fills | hover white 16% (dark) / 55% (light), pressed 31% / 70%, selected #121212 0.5 (dark) / white 0.7 (light) | Spec › Sidebar, 1.50 delta 6 |

### 5.3 Motion

| Action | Value | Source |
|---|---|---|
| Opening and closing the sidebar (⌘S) | A single spring, response 0.215 s, damping ratio 0.79. 90% at 100 ms, 1–2 pt overshoot at about 0.15 s, at rest at about 0.27 s. The sidebar, traffic lights, and the card's left edge move together; the right edge does not move. The page is laid out during the motion | Spec › Hiding and showing the sidebar |
| (Reference) Hiding Arc's sidebar | ease-out cubic 100 ms. Cra's measurement also shows 66% → 87% → 96% → 99% over about 5 frames | Spec › Arc note, Cra › Backdrop-layer blur (L841) |
| Opening a tab | The new row appears immediately at its final position, already selected. Rows below slide down by one pitch: cubic-bezier(0.25, 0.1, 0.25, 1), 0.14 s | Spec › Opening and closing tabs |
| Closing a tab | The closed row fades in place (cubic-bezier(0, 0, 0.58, 1), 0.10 s), and rows below simultaneously slide up over 0.14 s. Hover follows the final layout immediately | Same as above |
| Row background change | 0.3 s easeOut | Spec › 1.50 delta 9 |
| hover card | Show: opacity 0.10 s (cubic-bezier(0.25, 0.46, 0.45, 0.94)) + scale 0.92→1 spring (ζ 0.75, response 0.25 s), scaling from the top-left corner. Hide: 0.10 s + spring to scale 0.92 (ζ 0.6, 0.2 s). Show delay is 0.5 s or 0.1 s (the condition for which is not identified), or 0 if another card is already shown. Moving from row to row only moves the window and replaces its contents | Spec › Tab hover card motion |
| Profile paging | Displacement is `scrollingDeltaX × −0.5`. Rubber band at the edges `255·(1 − 1/(0.15·x/255 + 1))`. If the release velocity is 5 pt/s or more, go to the next page in the direction of the velocity; otherwise the nearest page. Velocity is computed from a 100 ms position history. Settling is a `CAKeyframeAnimation` (`space_swipe_settling`) sampling a critically damped spring (response 0.25 s, formerly 0.4 s) every 1/240 s. Page selection is notified before settling begins. The wheel sums input within 0.049 s; above 1 pt it advances one page and ignores input for 0.25 s | Spec › Profile paging, Research › dia-profile-swipe-binary.md |
| Dragging to split (measured in the top tab layout) | Lifting a tab attaches a 209×109.5 window image to the pointer. Releasing over a split target brings the new pane in from the side it was dropped on. Releasing outside the targets expands a new window in about 0.2 s | Spec › Dragging tabs and split targets |
| Reordering tabs (measured in the top tab layout) | Neighbouring tabs make room with a critically damped spring (ω ≈ 90 rad/s, about 0.07 s) | Same as above |

---

## 6. Source versions, parts not read, and inferred parts

### 6.1 Version of each source

| Source | Retrieved version | Target version |
|---|---|---|
| Cra `docs/arc-reverse-engineering.md` | commit `ef345193` (2026-10-28) | The opening covers Arc 1.168.0 (build 88413). After that, sections on 1.168.0 and 1.170.0 (89123) are mixed, and each heading indicates the version (e.g. the Little Arc section is dated 10-24 but is a 1.168 observation). The version of the Section 2 table differs by row. The Dia sections cover 1.54 and 1.54.2. Methods are REA CLI 6.4.0, `strings`, Swift reflection metadata, `otool -oV`, the user's JSON, and Accessibility and screen recordings. No decompiler was used |
| Ardia `docs/dia-spec.md` | `efcbaba7` (2026-10-28) | Based on Dia 1.49.1, with the 1.50.1 (87750) binary, 1.52 recordings, and the 1.53.0 binary |
| Ardia `docs/dia-feature-parity.md` | `d8e1098b` (2026-10-29) | Dia 1.49.1 (87398) and the changelog (up to 1.50.0). Some rows updated up to 1.53 |
| Ardia `docs/omnibox-ux.md` | `5686af30` (2026-10-26) | Audit of 2026-10-08, Chrome 154 tree |
| Ardia `docs/research/dia-profile-swipe-binary.md` | `8dcfe369` (2026-10-12) | Dia 1.50.1, arm64 UUID C3CA2D1A… |
| Ardia `docs/research/profile-swipe-native-controller.md` | `a5157342` (2026-10-26) | Implementation record of Ardia 0.2.18 (quotes Dia's values) |
| Ardia `docs/architecture-review.md` | Retrieved with `?ref=2713787d`. The body opens with "Reviewed at `b885f89c` (2026-10-01)" | Dia 1.50.1, ArcCore compat 8037.0.58 (Chromium 154) |
| Ardia `docs/research/chromium-ui-layer.md` | `?ref=2713787d` | Dia 1.49.1, ArcCore 153.0.8010.53 |
| Ardia `docs/research/chrome-hosted-window.md` | `?ref=2713787d` | Dia 1.50.1, ArcCore 154.0.8037.58 |
| Ardia `docs/ardiacore-spike.md` | main (the tree at HEAD `12ad9cd8` as of 2026-10-29) | Ardia's implementation (used only in Section 4.4) |
| Local Arc.app | — | Arc 1.170.0 (89123), build 21 Oct 2026, ArcCore 8078.0.48 |

The Arc information spans 1.168.0 and 1.170.0, and the Dia information spans 1.49.1–1.54.2. Even types with the same name may differ in content between versions.

### 6.2 Parts not read and parts not incorporated

- The overall structure of Arc's Settings window, the profile management screen, the dimensions and motion of Peek (links), the command bar's ranking weights (CoreML), and the structure of `StorableCommandBarAdditionalRanking.json` are not described in the parts of the source documents that were read.
- Of Dia's 45 `arc/browser/ui/*.cc` files, 10 have known names, including `window.cc`.
- The current Ardia `docs/research/` has only 2 files. `chromium-ui-layer.md` and `chrome-hosted-window.md` (which touch on Dia and ArcCore), present at @2713787d, were read from the older version. The images (`chrome-hosted-window/*.jpg`) were not read.
- Of `docs/dia-feature-parity.md`, only the tables in §1–§8 and §20–§23 and the rows that mention Arc were read. §9–§19 and §24–§25 (AI, bookmarks, history, passwords, etc.) were not read.
- The New Tab page, color token, PiP, and menu sections of `docs/dia-spec.md` are not included in the summary because they do not relate to the feel of the sidebar and window.
- This study did not look at the contents of Arc's `Resources/`, `strings`, disassembly, or user data.

### 6.3 Inferred parts (the main ones marked [I] in this document)

- That ArcCore 8078.0.48 is the Chromium 156 line (Section 1.1).
- That "ARC" is a namespace of modules inside the executable rather than a framework (Section 1.3).
- The purposes of Sentry, Firebase, and grpc (Section 1.5).
- That Arc's ArcCore has the same ObjC API as Dia's (Section 1.4).
- That Arc's command bar uses results from Chromium's `AutocompleteController` (inferred from the archetype names. Section 4.3).
- The mapping of each `arc/browser/ui/*.cc` file to the Chrome UI it replaces (inferred from the file names. Section 4.2).
- That Dia attaches multiple `Browser`s to one `NSWindow` (cannot be distinguished from Ardia's design proposal. Section 4.1).
- The split view limit of 4 panes and the handling of missing `widthFactor`s (the Cra document's [I] kept as is).

### 6.4 Discrepancies between the source documents and observation

- The Cra document says "Framework "ARC"", but there is no `ARC.framework` in Arc 1.170.0's `Contents/Frameworks` (Section 1.3).
- On whether Dia has spaces, `dia-spec.md` (`spaces-ui-enabled` on by default, with a dot switcher) and `dia-feature-parity.md` (according to the changelog, Dia has no Spaces) disagree.
- The split view pane limit is an inferred 4 for Arc (Cra) and 3 for Dia (Parity). These are values for different products, so this is not a contradiction, but care is needed not to lump them together as the same "ArcCore family".
- `architecture-review.md` was retrieved at @2713787d, but its body presents itself as a review as of `b885f89c`.
