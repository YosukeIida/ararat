import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func u25Row(_ id: String, parent: String = "", kind: RowKind = .tab, depth: UInt32 = 0,
                    unloaded: Bool = false, collapsed: Bool = false, hasTabs: Bool = false) -> Row {
    Row(folderHasTabs: hasTabs, parentId: parent, siblingIndex: 0, collapsed: collapsed, id: id, title: id,
        url: kind == .tab ? "https://\(id).example" : nil, depth: depth, kind: kind, unloaded: unloaded, lastSelectedAt: nil)
}

@MainActor
private func u25Space(id: String = "work", pinned: [Row] = [], today: [Row] = [], favorites: [Row] = []) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: UInt32(pinned.count), todayCount: UInt32(today.count), profileKey: "default",
                  pinnedId: "\(id)-pin", todayId: "\(id)-today", favoritesId: "\(id)-fav", archiveAfter: .hours12,
                  profileName: "Default", profile: .`default`, id: id, title: "Work", icon: nil, look: nil,
                  favorites: favorites, pinned: pinned, today: today)
}

@MainActor
private func u25Collapsed(_ space: SpaceSnapshot) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: space.pinnedCount, todayCount: space.todayCount, profileKey: space.profileKey,
                  pinnedId: space.pinnedId, todayId: space.todayId, favoritesId: space.favoritesId,
                  archiveAfter: space.archiveAfter, profileName: space.profileName, profile: space.profile,
                  id: space.id, title: space.title, icon: space.icon, look: space.look, pinnedCollapsed: true,
                  favorites: space.favorites, pinned: space.pinned, today: space.today)
}

@MainActor
private func u25Sidebar(_ space: SpaceSnapshot) -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 700)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
}

@MainActor
private func u25Descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(u25Descendants) }

@Test @MainActor
func crashedRowsDrawTheWarningGlyphAtFortyFivePercent() throws {
    let space = u25Space(today: [u25Row("a"), u25Row("b")])
    let (window, sidebar) = u25Sidebar(space)
    defer { window.contentView = nil }
    sidebar.crashedItems = ["a"]
    func row(_ id: String) throws -> SidebarRowView {
        try #require(u25Descendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == id })
    }
    let crashed = try u25Descendants(row("a")).compactMap { $0 as? NSImageView }.first
    let normal = try u25Descendants(row("b")).compactMap { $0 as? NSImageView }.first
    #expect(crashed?.image?.accessibilityDescription == "Crashed")
    #expect(normal?.image?.accessibilityDescription != "Crashed")
    #expect(abs((crashed?.alphaValue ?? 1) - SidebarMetrics.unloadedOpacity) < 0.001)
    #expect((normal?.alphaValue ?? 0) == 1)
    // The title dims with the glyph, as an unloaded row's does.
    let title = try #require(u25Descendants(row("a")).compactMap { $0 as? NSTextField }.first { $0.stringValue == "a" })
    #expect(abs(title.alphaValue - SidebarMetrics.unloadedOpacity) < 0.001)
}

@Test @MainActor
func unreadRowsShowTheDotUntilTheyAreShown() throws {
    let space = u25Space(today: [u25Row("a"), u25Row("b")])
    let (window, sidebar) = u25Sidebar(space)
    defer { window.contentView = nil }
    func row(_ id: String) throws -> SidebarRowView {
        try #require(u25Descendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == id })
    }
    #expect(!(try row("a")).unreadDotVisible)
    sidebar.unreadItems = ["a"]
    #expect((try row("a")).unreadDotVisible)
    #expect(!(try row("b")).unreadDotVisible)
    sidebar.unreadItems = []
    #expect(!(try row("a")).unreadDotVisible)
}

@Test @MainActor
func anOpenEmptyFoldersLineSitsAtTheChildIndent() throws {
    let marker = u25Row("folder/no-tabs", parent: "folder", kind: .noTabs, depth: 1)
    let space = u25Space(pinned: [u25Row("folder", kind: .folder, hasTabs: false), marker], today: [u25Row("a")])
    let (window, sidebar) = u25Sidebar(space)
    defer { window.contentView = nil }
    let line = try #require(u25Descendants(sidebar).compactMap { $0 as? SidebarNoTabsRow }.first)
    #expect(line.row.id == "folder/no-tabs")
    #expect(line.frame.height == SidebarMetrics.noTabsRowHeight)
    // F3: the "No tabs" text at the child indent (the icon column of depth 1), secondary size,
    // centred in the 24 pt row. Tolerances are a point: Auto Layout lands the label on a whole
    // point (12.5 midY against the row's 12) and the field's height is its cell's.
    let text = line.textFrameInRow
    #expect(abs(text.minX - (10 + 16)) <= 1)
    #expect(line.textFontSize == SidebarMetrics.secondaryFontSize)
    #expect(abs(text.height - line.textCellHeight) <= 1)
    #expect(abs(text.midY - line.bounds.midY) <= 1)
    #expect(line.isAccessibilityElement())
    #expect(line.accessibilityLabel() == "No tabs")
    #expect(line.hitTest(NSPoint(x: line.bounds.midX, y: line.bounds.midY)) == nil)
    // It is not a row: a click never selects it.
    #expect(sidebar.selectRow(id: "folder/no-tabs"))
    #expect(sidebar.selectedRowID != "folder/no-tabs")
}

@Test @MainActor
func clearTodayPressDiagnosticsDistinguishDisabledButtonsFromDispatchedActions() throws {
    _ = NSApplication.shared
    let space = u25Space(today: [u25Row("a")])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
    let button = try #require(u25Descendants(sidebar).compactMap { $0 as? SidebarClearButton }.first)
    var cleared = 0
    var traces: [String] = []
    sidebar.onClearToday = { cleared += 1 }
    for _ in 0..<2 { #expect(sidebar.pressClearToday { traces.append($0) }) }
    #expect(cleared == 2)
    #expect(traces.count == 4)
    #expect(traces[0].contains("stage=before"))
    #expect(traces[0].contains("presses=0"))
    #expect(traces[3].contains("stage=after"))
    #expect(traces[3].contains("presses=2"))
    button.isEnabled = false
    #expect(sidebar.pressClearToday { traces.append($0) })
    #expect(cleared == 2)
    #expect(traces.last?.contains("enabled=false") == true)
    #expect(traces.last?.contains("presses=2") == true)
}

@Test @MainActor
func todayDividerReturnsAfterClearTodayIsCancelled() throws {
    _ = NSApplication.shared
    let space = u25Space(today: [u25Row("a"), u25Row("b")])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
    var cleared = 0
    sidebar.onClearToday = { cleared += 1 }
    #expect(sidebar.pressClearToday { _ in })
    sidebar.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil,
                                             spaces: [u25Space()]))
    #expect(sidebar.todayDividerForCheck == nil)
    #expect(!sidebar.pressClearToday { _ in })
    sidebar.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: "b",
                                             spaces: [u25Space(today: [u25Row("b")])]))
    #expect(sidebar.todayDividerForCheck != nil)
    #expect(u25Descendants(sidebar).compactMap { $0 as? SidebarTodayDivider }.count == 1)
    #expect(sidebar.rowCheckIds == ["b"])
    #expect(sidebar.pressClearToday { _ in })
    #expect(cleared == 2)
}

@Test @MainActor
func todayDividerClearAndNewTabFollowTodayAndTheSetting() throws {
    let space = u25Space(today: [u25Row("a")])
    let (window, sidebar) = u25Sidebar(space)
    defer { window.contentView = nil }
    let divider = try #require(u25Descendants(sidebar).compactMap { $0 as? SidebarTodayDivider }.first)
    let frames = divider.checkFrames
    let line = sidebar.convert(try #require(frames["line"]), from: divider)
    // T1: the line runs from x 18 to 80 pt from the sidebar's edge, 8 pt down in a 16 pt block.
    #expect(abs(line.minX - 18) < 0.5)
    #expect(abs(line.maxX - (240 - 80)) < 0.5)
    #expect(divider.frame.height == SidebarMetrics.todayDividerHeight)
    let clear = sidebar.convert(try #require(frames["clear"]), from: divider)
    #expect(abs(clear.maxX - (240 - 16)) < 0.5)
    #expect(abs(clear.height - SidebarMetrics.todayClearSize) < 0.5)
    var cleared = 0
    sidebar.onClearToday = { cleared += 1 }
    (u25Descendants(divider).compactMap { $0 as? SidebarClearButton }.first)?.performClick(nil)
    #expect(cleared == 1)
    // T4: the New Tab row is 41 pt and sits between the divider and Today's rows.
    let newTab = try #require(u25Descendants(sidebar).compactMap { $0 as? SidebarNewTabRow }.first)
    #expect(newTab.frame.height == SidebarMetrics.newTabRowHeight)
    var opened = 0
    sidebar.onNewTab = { opened += 1 }
    let point = newTab.convert(NSPoint(x: 20, y: newTab.bounds.midY), to: nil)
    let downEvent = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let upEvent = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                  timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    newTab.mouseDown(with: downEvent)
    newTab.mouseUp(with: upEvent)
    #expect(opened == 1)
    // Hidden, the rows below close up by its height (T4).
    sidebar.newTabRowShown = false
    sidebar.layoutSubtreeIfNeeded()
    #expect(u25Descendants(sidebar).compactMap { $0 as? SidebarNewTabRow }.isEmpty)
    let withoutHeight = sidebar.dragGeometry()?.rows.first { $0.row.id == "a" }?.frame.minY ?? 0
    sidebar.newTabRowShown = true
    sidebar.layoutSubtreeIfNeeded()
    let withHeight = sidebar.dragGeometry()?.rows.first { $0.row.id == "a" }?.frame.minY ?? 0
    #expect(abs((withHeight - withoutHeight) - SidebarMetrics.newTabRowHeight) < 0.5)
    // T3/T1: with no Today tabs there is no divider, but the New Tab row stays.
    let empty = u25Space(id: "empty")
    let (emptyWindow, emptySidebar) = u25Sidebar(empty)
    defer { emptyWindow.contentView = nil }
    #expect(u25Descendants(emptySidebar).compactMap { $0 as? SidebarTodayDivider }.isEmpty)
    #expect(!u25Descendants(emptySidebar).compactMap { $0 as? SidebarNewTabRow }.isEmpty)
}

@Test @MainActor
func theSpaceNameRowChevronMenuAndRenameFollowTheMock() throws {
    let space = u25Space(pinned: [u25Row("pin")], today: [u25Row("a")])
    let (window, sidebar) = u25Sidebar(space)
    defer { window.contentView = nil }
    var edits: [SidebarItemEdit] = []
    sidebar.onItemEdit = { edit, done in
        edits.append(edit)
        if case .collapseSection = edit {
            done(WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [u25Collapsed(space)]))
        } else {
            done(WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
        }
    }
    let nameRow = sidebar.spaceNameRow
    let name = try #require(u25Descendants(nameRow).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Work" })
    let chevron = try #require(nameRow.subviews.compactMap { $0 as? NSButton }.first { $0 !== nameRow.moreButton })
    func nameX() -> CGFloat {
        nameRow.layoutSubtreeIfNeeded()
        let rect = name.alignmentRect(forFrame: name.frame)
        return sidebar.convert(rect, from: name.superview).minX
    }
    // D10: x 16 at rest; the chevron shows on hover with the name at x 40; both while collapsed.
    #expect(abs(nameX() - 16) < 0.5)
    nameRow.hovered = true
    sidebar.layoutSubtreeIfNeeded()
    #expect(abs(nameX() - 40) < 0.5)
    #expect(abs(chevron.frame.midY - (nameRow.bounds.maxY - name.font!.capHeight / 2)) < 0.5)
    nameRow.hovered = false
    // The flag rides in the space snapshot: a collapsed snapshot shows the chevron at rest.
    sidebar.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [u25Collapsed(space)]))
    sidebar.layoutSubtreeIfNeeded()
    #expect(abs(nameX() - 40) < 0.5)
    #expect(abs(chevron.frame.midY - (nameRow.bounds.maxY - name.font!.capHeight / 2)) < 0.5)
    // S2: a click on the row toggles the section through the core edit.
    sidebar.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
    sidebar.layoutSubtreeIfNeeded()
    #expect(abs(nameX() - 16) < 0.5)
    let point = nameRow.convert(NSPoint(x: nameRow.bounds.midX, y: nameRow.bounds.midY), to: nil)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                               timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let release = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    nameRow.mouseDown(with: click)
    nameRow.mouseUp(with: release)
    #expect(sidebar.isSectionCollapsed(space.id))
    #expect(edits.contains { if case let .collapseSection(spaceID, collapsed) = $0 { return spaceID == space.id && collapsed } ; return false })
    // S3: the right-click menu is the dock's five-item space menu.
    let menuEvent = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(nameRow.menu(for: menuEvent))
    #expect(menu.items.map { $0.isSeparatorItem ? nil : $0.title } == ["Rename Space…", "Edit Look…", "Space Settings…", nil, "New Folder", nil, "Delete Space…"])
    #expect(menu.items.map(\.isSeparatorItem) == sidebar.dockMenuItems(for: space.id).map(\.isSeparatorItem))
    // S4: a click never starts a rename; the menu item does, with the 24 pt field.
    #expect(nameRow.renameField == nil)
    let rename = try #require(menu.items.first { $0.title == "Rename Space…" })
    _ = NSApp.sendAction(rename.action!, to: rename.target, from: rename)
    sidebar.layoutSubtreeIfNeeded()
    let field = try #require(nameRow.renameField)
    #expect(field.frame.height == 24)
    #expect(name.isHidden)
}

@Test @MainActor
func aFavoriteWithoutAFaviconUsesTheEngineMonogramOrTitle() throws {
    // Chromium's components/favicon/core/fallback_url_util_unittest.cc pins
    // GetFallbackIconText's registrable domain, IDN, IP, and single-label host rules.
    let engineText = [
        "https://www.example.com/": "E",
        "https://xn--hq1bm8jm9l.com/": "도",
        "http://127.0.0.1/": "IP",
        "http://[2001:4860:4860::8888]/": "IP",
        "http://localhost/": "L",
    ]
    let cases = engineText.sorted { $0.key < $1.key }.map { (url: $0.key, title: "My reading", glyph: $0.value) } +
        [(url: "file:///tmp/report.pdf", title: "Report", glyph: "R"),
         (url: "about:blank", title: "My reading", glyph: "M"),
         (url: "about:blank", title: "", glyph: "")]
    let rows = cases.enumerated().map { index, fixture in
        var row = u25Row("favorite-\(index)")
        row.url = fixture.url
        row.title = fixture.title
        return row
    }
    let space = u25Space(favorites: rows)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]),
                              favoriteIconText: { engineText[$0] })
    let tiles = u25Descendants(sidebar).compactMap { $0 as? FavoriteTile }
    for (row, fixture) in zip(rows, cases) {
        let tile = try #require(tiles.first { $0.row.id == row.id })
        #expect(tile.glyphLabel.stringValue == fixture.glyph, "\(fixture.url)")
        #expect(tile.glyphBox.isHidden == fixture.glyph.isEmpty)
        if fixture.glyph.isEmpty {
            #expect(tile.image?.isValid == true)
            #expect(tile.image?.size == SidebarRowView.symbol(for: .tab).size)
        } else {
            #expect(tile.image == nil)
            #expect(tile.accessibilityLabel() == fixture.title)
        }
    }
}

@Test @MainActor
func favoriteTileUsesTheTitleOrHostForAccessibility() {
    var row = u25Row("favorite")
    row.url = "https://example.com/reading"
    row.title = "My reading"
    let tile = FavoriteTile(row: row, iconText: "E") { _ in }
    #expect(tile.accessibilityLabel() == "My reading")
    #expect(tile.accessibilityTitle() == "My reading")
    row.title = ""
    tile.update(row: row, iconText: "E")
    #expect(tile.accessibilityLabel() == "example.com")
    #expect(tile.accessibilityTitle() == "example.com")
    row.url = "about:blank"
    tile.update(row: row, iconText: nil)
    #expect(tile.accessibilityLabel() != "Button")
    #expect(tile.accessibilityTitle() != "Button")
    #expect(tile.title.isEmpty)
}

@Test @MainActor
func theCloseRuleFollowsTheRowAndASplitClosesThroughItsSplit() {
    let favourite = u25Row("f", parent: "work-fav")
    let loadedPin = u25Row("p", parent: "work-pin")
    let unloadedPin = u25Row("q", parent: "work-pin", unloaded: true)
    let today = u25Row("t", parent: "work-today")
    let member = u25Row("m", parent: "split", depth: 1)
    let split = u25Row("split", parent: "work-today", kind: .split, hasTabs: true)
    let space = u25Space(pinned: [loadedPin, unloadedPin], today: [today, split, member], favorites: [favourite])
    #expect(!rowCloseArchives(favourite, in: space))
    #expect(!rowCloseArchives(loadedPin, in: space))
    #expect(rowCloseArchives(unloadedPin, in: space))
    #expect(rowCloseArchives(today, in: space))
    // A split takes the close path: archive_item accepts tabs only (1c).
    #expect(!rowCloseArchives(split, in: space))
    #expect(!rowCloseArchives(u25Row("s", parent: "work-pin", kind: .split, unloaded: true), in: space))
    // A member is closed through its split only where the caller has no row (⌘W); the rows
    // themselves pass their own id.
    let rows = space.today + space.pinned + space.favorites
    #expect(splitOwner("m", rows: rows) == "split")
    #expect(splitOwner("t", rows: rows) == "t")
}

@Test @MainActor
func unreadTrackerSetsClearsAndPrunesFromTheStrip() {
    func tab(_ item: String, _ live: String, _ title: String) -> LiveTab {
        LiveTab(offTheRecord: false, profile: .default, liveId: live, item: item, opener: nil, navigated: false, url: nil, title: title)
    }
    func strip(_ tabs: [LiveTab], active: String?) -> LiveStrip {
        LiveStrip(window: "w", tabs: tabs, active: active)
    }
    var tracker = UnreadTracker()
    tracker.apply(strip: strip([tab("a", "la", "One"), tab("b", "lb", "Two")], active: "la"))
    #expect(tracker.unread.isEmpty)
    // A background title change marks the tab; the shown one never gets a dot.
    tracker.apply(strip: strip([tab("a", "la", "One changed"), tab("b", "lb", "Two")], active: "lb"))
    #expect(tracker.unread == ["a"])
    // Showing it clears the dot.
    tracker.apply(strip: strip([tab("a", "la", "One changed"), tab("b", "lb", "Two")], active: "la"))
    #expect(tracker.unread.isEmpty)
    // A row that leaves the strip is forgotten with its title: returning does not resurrect
    // the dot from a stale title.
    tracker.apply(strip: strip([tab("a", "la", "One changed again")], active: "la"))
    tracker.apply(strip: strip([tab("a", "la", "One changed again"), tab("b", "lb", "Two")], active: "la"))
    #expect(tracker.unread.isEmpty)
}

@Test @MainActor
func twoQuickCommandWPressesActOnTheCoreSuccessor() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("busy.sqlite").path
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: path, windowID: "busy", card: NSView(), session: session)
    var closedRows: [String] = []
    engine.onRowClose = { closedRows.append($0) }
    let store = try #require(session.store)
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work", {"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":["p"],"data":{"itemContainer":{}}},"p",{"id":"p","parentID":"pin","childrenIds":[],"data":{"tab":{"savedURL":"https://p.example"}}},"today",{"id":"today","parentID":null,"childrenIds":["a"],"data":{"itemContainer":{}}},"a",{"id":"a","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://a.example"}}}]}]}}"#
    _ = try store.importArcSidebar(windowId: "busy", json: json, windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
    try store.showSpace(windowId: "busy", spaceId: "work")
    // The history puts the pin after the Today tab, so unloading the pin makes the Today tab
    // the core's next selection.
    _ = try store.selectItem(windowId: "busy", id: "a")
    _ = try store.selectItem(windowId: "busy", id: "p")
    // A busy queue: both presses are enqueued behind this block, so a read in one block and
    // an act in another would let the second press act on the pin again — now unloaded, so
    // the rule would archive it and the pin would be lost.
    let gate = DispatchSemaphore(value: 0)
    session.queue.async { gate.wait() }
    engine.closeSelected()
    engine.closeSelected()
    gate.signal()
    try await waitUntil {
        let now = store.snapshot(windowId: "busy").spaces.first { $0.id == "work" }
        return now?.today.isEmpty == true && now?.pinned.contains { $0.id == "p" && !$0.unloaded } == false
    }
    let after = store.snapshot(windowId: "busy")
    let work = try #require(after.spaces.first { $0.id == "work" })
    #expect(after.archive.contains { $0.id == "a" })
    // The pin unloaded (kept), and it was never archived: the second press acted on the
    // core's successor, not on the stale pin id.
    let p = try #require(work.pinned.first { $0.id == "p" })
    #expect(p.unloaded)
    #expect(!after.archive.contains { $0.id == "p" })
    try await waitUntil { closedRows == ["a"] }
}

@Test @MainActor
func theRowCapsFollowTheCloseBindingWithoutAMenuItem() throws {
    let space = u25Space(today: [u25Row("a")])
    let (window, sidebar) = u25Sidebar(space)
    defer { window.contentView = nil }
    sidebar.updateSelection(id: "a")
    let row = try #require(u25Descendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "a" })
    #expect(row.closeShortcutCaps == ["⌘", "W"])
    // 1e: the caps follow the close_tab binding, not a hard-coded pair.
    sidebar.keyBindings = defaultKeyBindings().map { binding in
        guard binding.command == "close_tab" else { return binding }
        return KeyBinding(command: binding.command, title: binding.title, menu: binding.menu,
                          description: binding.description, defaultKey: binding.defaultKey,
                          key: KeyCombination(key: "q", command: true, control: true, option: false, shift: false),
                          customized: true, conflicting: binding.conflicting,
                          assignedKey: KeyCombination(key: "q", command: true, control: true, option: false, shift: false))
    }
    #expect(row.closeShortcutCaps == ["⌃", "⌘", "Q"])
    // The explicit caps reach the tooltip with no menu item to look them up in.
    row.pointerLocation = { [weak row] in row.map { $0.convert(NSPoint(x: 20, y: $0.bounds.midY), to: nil) } }
    row.refreshHover()
    #expect(!row.closeButton.isHidden)
    var now: CFTimeInterval = 100
    sidebar.tooltip.clock = { now }
    sidebar.tooltip.capture(in: row)
    sidebar.tooltip.update(target: row.closeButton, point: NSPoint(x: 25, y: 200))
    now += 1.6
    sidebar.tooltip.update(target: row.closeButton, point: NSPoint(x: 25, y: 200))
    #expect(sidebar.tooltip.keycaps.map(\.stringValue) == ["⌃", "⌘", "Q"])
}

@Test(arguments: [true, false]) @MainActor
func anUnloadedPinsCloseArchivesItThroughTheRowsAction(animate: Bool) async throws {
    // D2: an unloaded pin's ✕ archives it (the row showed Archive Tab). The check presses
    // the row's rule directly, which lands on actions.onArchive → adapter.close(archive: true).
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("pin-archive.sqlite").path
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: path, windowID: "archive", card: NSView(), session: session)
    var closedRows: [String] = []
    var delivered = false
    engine.onRowClose = { closedRows.append($0) }
    engine.onSnapshot = { _ in delivered = true }
    let store = try #require(session.store)
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work", {"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":["p"],"data":{"itemContainer":{}}},"p",{"id":"p","parentID":"pin","childrenIds":[],"data":{"tab":{"savedURL":"https://p.example"}}},"today",{"id":"today","parentID":null,"childrenIds":["a"],"data":{"itemContainer":{}}},"a",{"id":"a","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://a.example"}}}]}]}}"#
    _ = try store.importArcSidebar(windowId: "archive", json: json, windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
    try store.showSpace(windowId: "archive", spaceId: "work")
    let before = try #require(store.snapshot(windowId: "archive").spaces.first { $0.id == "work" })
    let pin = try #require(before.pinned.first { $0.id == "p" })
    #expect(!rowCloseArchives(pin, in: before))
    // Unload the pin the way the check's seed does (its loaded ✕ closes it).
    _ = try store.closeItem(windowId: "archive", id: "p")
    let unloaded = try #require(store.snapshot(windowId: "archive").spaces.first { $0.id == "work" })
    let unloadedPin = try #require(unloaded.pinned.first { $0.id == "p" })
    #expect(unloadedPin.unloaded)
    // The unloaded pin's ✕ is Archive Tab: the row's own rule.
    #expect(rowCloseArchives(unloadedPin, in: unloaded))
    engine.close(id: "p", archive: true, animate: animate)
    try await waitUntil {
        let now = store.snapshot(windowId: "archive")
        return now.archive.contains { $0.id == "p" }
    }
    let after = store.snapshot(windowId: "archive")
    let work = try #require(after.spaces.first { $0.id == "work" })
    #expect(after.archive.contains { $0.id == "p" })
    #expect(!work.pinned.contains { $0.id == "p" })
    #expect(work.today.contains { $0.id == "a" })
    try await waitUntil { delivered }
    #expect(closedRows == (animate ? ["p"] : []))
}

@Test @MainActor
func theCloseCapsSeamReadsTheCurrentRowNotAnArbitraryOne() throws {
    // R2: only the current row draws ⌘W's caps. The check compares the current row's caps
    // with the close_tab binding's; reading an arbitrary row made the plain run flaky.
    let (window, sidebar) = u25Sidebar(u25Space(today: [u25Row("a"), u25Row("b")]))
    defer { window.contentView = nil }
    sidebar.updateSelection(id: "a")
    #expect(sidebar.rowCheckInfo(id: "a")?.closeCaps == ["⌘", "W"])
    #expect(sidebar.rowCheckInfo(id: "b")?.closeCaps == nil)
    #expect(sidebar.closeCapsForCheck == ["⌘", "W"])
    #expect(sidebar.closeBindingCapsForCheck == ["⌘", "W"])
    sidebar.updateSelection(id: nil)
    #expect(sidebar.closeCapsForCheck == nil)
}

@Test(arguments: ["cancel", "silent", "close"]) @MainActor
func aRefusedCloseDoesNotAnimateALaterRemoval(removal: String) async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("cancel.sqlite").path,
                                   windowID: "cancel", card: NSView(), session: session)
    let store = try #require(session.store)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    _ = try store.importArcSidebar(windowId: "cancel", json: String(contentsOf: fixture, encoding: .utf8),
                                   windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
    let created = try store.createTab(windowId: "cancel", url: "https://cancel.example/")
    let id = try #require(created.selectedId)
    let live = try store.liveOpen(item: id, url: "https://cancel.example/")
    func keptTransaction(_ rev: UInt64) -> LiveTransaction {
        LiveTransaction(offTheRecord: false, epoch: 1, rev: rev, cause: .engine,
                        strips: [LiveStrip(window: "cancel", tabs: [LiveTab(offTheRecord: false, profile: .default,
                            liveId: live.id, item: id, opener: nil, navigated: false, url: nil, title: nil)], active: live.id)])
    }
    _ = try store.liveApply(transaction: keptTransaction(0))
    var delivered: WorkspaceSnapshot?
    var closed: [String] = []
    engine.onSnapshot = { delivered = $0 }
    engine.onRowClose = { closed.append($0) }
    engine.close(id: id, archive: true)
    await withCheckedContinuation { continuation in session.queue.async { continuation.resume() } }
    _ = try store.restoreItem(windowId: "cancel", id: id)
    _ = try store.selectItem(windowId: "cancel", id: id)
    engine.refresh()
    try await waitUntil { delivered?.spaces.flatMap(\.today).contains { $0.id == id && !$0.unloaded } == true }
    #expect(closed.isEmpty)
    delivered = nil
    if removal == "cancel" {
        engine.tabCloseCancelled(id, commandId: "unknown")
        _ = try store.archiveItem(windowId: "cancel", id: id)
        engine.refresh()
    } else {
        engine.close(id: id, archive: true, animate: removal == "close")
        engine.refresh()
    }
    try await waitUntil { delivered?.archive.contains { $0.id == id } == true }
    #expect(closed == (removal == "close" ? [id] : []))
}

@Test @MainActor
func aCancelledLiveClosePublishesTheRestoredRow() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("stay.sqlite").path,
                                   windowID: "stay", card: NSView(), session: session)
    let store = try #require(session.store)
    _ = try store.createSpace(windowId: "stay", name: "Work", spaceId: "work")
    let created = try store.createTab(windowId: "stay", url: "https://stay.example/")
    let id = try #require(created.selectedId)
    let live = try store.liveOpen(item: id, url: "https://stay.example/")
    _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine,
        strips: [LiveStrip(window: "stay", tabs: [LiveTab(offTheRecord: false, profile: .default, liveId: live.id,
            item: id, opener: nil, navigated: false, url: nil, title: nil)], active: live.id)]))
    let before = store.snapshot(windowId: "stay")
    let close = try store.liveArchive(item: id)
    var delivered: WorkspaceSnapshot?
    var closed: [String] = []
    engine.onSnapshot = { delivered = $0 }
    engine.onRowClose = { closed.append($0) }
    engine.tabCloseCancelled(id, commandId: close.id)
    try await waitUntil { delivered == before }
    #expect(store.liveTab(item: id) == live.id)
    #expect(try store.pendingHistoryPurges().isEmpty)
    #expect(closed.isEmpty)
    #expect(try store.liveCancelClose(commandId: close.id) == false)
}

@Test @MainActor
func clearTodayStayPublishesOnlyTheRefusedRowWithoutCloseMotion() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("clear-stay.sqlite").path,
                                   windowID: "stay", card: NSView(), session: session)
    let store = try #require(session.store)
    _ = try store.createSpace(windowId: "stay", name: "Work", spaceId: "work")
    let kept = try #require(store.createTab(windowId: "stay", url: "https://stay.example/").selectedId)
    let other = try #require(store.createTab(windowId: "stay", url: "https://leave.example/").selectedId)
    let live = try store.liveOpen(item: kept, url: "https://stay.example/")
    _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine,
        strips: [LiveStrip(window: "stay", tabs: [LiveTab(offTheRecord: false, profile: .default, liveId: live.id,
            item: kept, opener: nil, navigated: false, url: nil, title: nil)], active: live.id)]))
    let clear = try store.liveClearToday(windowId: "stay", spaceId: "work")
    let command = try #require(clear.targets.first { $0.command.item == kept }?.command)
    var delivered: WorkspaceSnapshot?
    var closed: [String] = []
    engine.onSnapshot = { delivered = $0 }
    engine.onRowClose = { closed.append($0) }
    engine.tabCloseCancelled(kept, commandId: command.id)
    try await waitUntil { delivered?.spaces.first { $0.id == "work" }?.today.map(\.id) == [kept] }
    #expect(delivered?.archive.contains { $0.id == other } == true)
    #expect(delivered?.spaces.first { $0.id == "work" }?.today.first?.unloaded == false)
    #expect(store.liveTab(item: kept) == live.id)
    #expect(try store.pendingHistoryPurges().allSatisfy { $0.item != kept })
    #expect(closed.isEmpty)
}
