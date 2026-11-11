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
    // F3: the 24 pt line at the child indent (the icon column of depth 1).
    #expect(abs(line.lineFrameInRow.minX - (10 + 16)) < 0.5)
    #expect(abs(line.lineFrameInRow.width - SidebarMetrics.noTabsLineWidth) < 0.5)
    // It is not a row: a click never selects it.
    #expect(sidebar.selectRow(id: "folder/no-tabs"))
    #expect(sidebar.selectedRowID != "folder/no-tabs")
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
    nameRow.hovered = false
    // The flag rides in the space snapshot: a collapsed snapshot shows the chevron at rest.
    sidebar.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [u25Collapsed(space)]))
    sidebar.layoutSubtreeIfNeeded()
    #expect(abs(nameX() - 40) < 0.5)
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
    #expect(menu.items.map(\.title) == ["Rename Space…", "Edit Look…", "Space Settings…", "New Folder", "Delete Space…"])
    #expect(menu.items.map(\.title) == sidebar.dockMenuItems(for: space.id).map(\.title))
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
        LiveTab(profile: .default, liveId: live, item: item, opener: nil, navigated: false, url: nil, title: title)
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
