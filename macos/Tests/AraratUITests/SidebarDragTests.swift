import AppKit
import AraratKit
import Testing
@testable import AraratUI

private func dragRow(_ id: String, _ parent: String, _ index: UInt32 = 0, kind: RowKind = .tab, collapsed: Bool = false, depth: UInt32 = 0) -> Row {
    Row(folderHasTabs: false, parentId: parent, siblingIndex: index, collapsed: collapsed, id: id, title: id, url: kind == .tab ? "https://\(id).example" : nil,
        depth: depth, kind: kind, unloaded: false, lastSelectedAt: nil)
}

private func dragSpace(_ id: String = "s", profile: String = "default", pinned: [Row] = [], today: [Row] = [], favorites: [Row] = []) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: UInt32(pinned.filter { $0.parentId == "p\(id)" }.count), todayCount: UInt32(today.filter { $0.parentId == "t\(id)" }.count), profileKey: profile, pinnedId: "p\(id)", todayId: "t\(id)", favoritesId: "f\(profile)", archiveAfter: .hours12,
                  profileName: profile, profile: .named(profile), id: id, title: id, icon: nil, look: nil, favorites: favorites, pinned: pinned, today: today)
}

private func dragFixture() -> SpaceSnapshot {
    dragSpace(pinned: [dragRow("pin", "ps"), dragRow("folder", "ps", 1, kind: .folder),
                      dragRow("nested", "folder", kind: .folder, collapsed: true, depth: 1),
                      dragRow("child", "folder", 1, depth: 1)], today: [dragRow("a", "ts"), dragRow("b", "ts", 1)],
              favorites: [dragRow("fav0", "fdefault"), dragRow("fav1", "fdefault", 1)])
}

private func pureGeometry(_ space: SpaceSnapshot = dragFixture()) -> SidebarDragGeometry {
    SidebarDragGeometry(bounds: CGRect(x: 0, y: 0, width: 240, height: 700), list: CGRect(x: 8, y: 180, width: 224, height: 450),
        pinnedArea: CGRect(x: 8, y: 149, width: 224, height: 31),
        favorites: CGRect(x: 8, y: 90, width: 224, height: 47),
        rows: (space.pinned + space.today).enumerated().map { .init(row: $1, frame: CGRect(x: 8, y: 180 + $0 * 41, width: 224, height: 41)) },
        dock: [(dragSpace("other"), CGRect(x: 50, y: 650, width: 34, height: 32)),
               (dragSpace("foreign", profile: "named"), CGRect(x: 84, y: 650, width: 34, height: 32))], space: space)
}

@Test @MainActor
func favoriteDropAcceptsAnAbsentContainer() {
    let original = dragSpace(today: [dragRow("a", "ts")])
    let space = SpaceSnapshot(pinnedCount: original.pinnedCount, todayCount: original.todayCount, profileKey: original.profileKey, pinnedId: original.pinnedId, todayId: original.todayId, favoritesId: nil, archiveAfter: original.archiveAfter, profileName: original.profileName, profile: original.profile, id: original.id, title: original.title, icon: original.icon, look: original.look, favorites: original.favorites, pinned: original.pinned, today: original.today)
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 100), geometry: pureGeometry(space), dragged: space.today[0]) == .favorites(container: nil, index: 0))
}

@Test
func dropResolverCoversBoundariesFoldersFavoritesDockAndRefusals() throws {
    let g = pureGeometry()
    let a = try #require(g.space.today.first)
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 180), geometry: g, dragged: a) == .insert(container: "ps", index: 0, lineY: 180, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 221), geometry: g, dragged: a) == .insert(container: "ps", index: 1, lineY: 221, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 241), geometry: g, dragged: a) == .folder("folder"))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 282), geometry: g, dragged: a) == .folder("nested"))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 303), geometry: g, dragged: a) == .insert(container: "folder", index: 1, lineY: 303, depth: 1))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 385), geometry: g, dragged: a) == .insert(container: "ts", index: 0, lineY: 385, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 426), geometry: g, dragged: a) == .insert(container: "ts", index: 1, lineY: 426, depth: 0))
    for (x, index) in [(8.0, 0), (90, 1), (231, 2)] {
        #expect(resolveSidebarDrop(position: CGPoint(x: x, y: 100), geometry: g, dragged: a) == .favorites(container: "fdefault", index: index))
    }
    #expect(resolveSidebarDrop(position: CGPoint(x: 50, y: 660), geometry: g, dragged: a) == .dock(space: "other", container: "tother", index: 0))
    let folder = try #require(g.space.pinned.first { $0.id == "folder" })
    #expect(resolveSidebarDrop(position: CGPoint(x: 50, y: 660), geometry: g, dragged: folder) == .dock(space: "other", container: "pother", index: 0))
    for point in [CGPoint(x: 30, y: 100), CGPoint(x: 30, y: 400), CGPoint(x: 30, y: 241), CGPoint(x: 30, y: 282), CGPoint(x: 30, y: 303)] {
        #expect(resolveSidebarDrop(position: point, geometry: g, dragged: folder) == .refused)
    }
    for point in [CGPoint(x: 84, y: 660), CGPoint(x: -1, y: 200), CGPoint(x: 240, y: 200), CGPoint(x: 30, y: 30), CGPoint(x: 30, y: 700)] {
        #expect(resolveSidebarDrop(position: point, geometry: g, dragged: a) == .refused)
    }
    let split = dragRow("split", "ps", kind: .split)
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 100), geometry: g, dragged: split) == .refused)
    let pin = try #require(g.space.pinned.first)
    #expect(resolveSidebarDrop(position: CGPoint(x: 50, y: 660), geometry: g, dragged: pin) == .dock(space: "other", container: "pother", index: 0))
    let favorite = try #require(g.space.favorites.first)
    #expect(resolveSidebarDrop(position: CGPoint(x: 230, y: 100), geometry: g, dragged: favorite) == .favorites(container: "fdefault", index: 1))
    #expect(resolveSidebarDrop(position: CGPoint(x: 40, y: 330), geometry: g, dragged: a) == .insert(container: "folder", index: 2, lineY: 344, depth: 1))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 261), geometry: g, dragged: a) == .insert(container: "folder", index: 0, lineY: 262, depth: 1))
    let empty = pureGeometry(dragSpace())
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 160), geometry: empty, dragged: a) == .insert(container: "ps", index: 0, lineY: 180, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 200), geometry: empty, dragged: a) == .insert(container: "ts", index: 0, lineY: 180, depth: 0))
}

@MainActor
private func dragDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(dragDescendants) }

@MainActor
private func dragWindow(_ space: SpaceSnapshot = dragFixture()) -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: "b", spaces: [space, dragSpace("other")]))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    sidebar.dragReduceMotion = { true }
    return (window, sidebar)
}

@MainActor
private func dragEvent(_ type: NSEvent.EventType, sidebar: SidebarView, position: CGPoint) throws -> NSEvent {
    let point = sidebar.convert(CGPoint(x: position.x, y: sidebar.bounds.height - position.y), to: nil)
    return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@Test @MainActor
func organizeCheckUsesMouseAndEscapeInput() {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    #expect(sidebar.organizeCheckBegin(id: "a", destination: "pin"))
    #expect(sidebar.organizeCheckDragging && sidebar.organizeCheckDropLine)
    #expect(sidebar.organizeCheckEnd(cancel: true))
    #expect(sidebar.organizeCheckIdle)
    #expect(sidebar.organizeCheckEnd())
    #expect(sidebar.organizeCheckBegin(id: "folder", destination: "today"))
    #expect(!sidebar.organizeCheckDragging)
    #expect(sidebar.organizeCheckEnd())
}

@Test @MainActor
func organizeCheckDrivesSeedThroughCore() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "organize", card: NSView(), seedOrganize: true, session: session)
    let store = try #require(session.store)
    let sidebar = SidebarView(snapshot: store.snapshot(windowId: "organize"))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.dragReduceMotion = { true }
    sidebar.onSelect = { row in
        do { sidebar.applySelection(snapshot: try store.selectItem(windowId: "organize", id: row.id)) }
        catch { Issue.record("select: \(error)") }
    }
    sidebar.onMove = { id, container, index, open, completion in
        do { completion(try store.moveItem(windowId: "organize", id: id, container: container, index: UInt32(index), openFolder: open)) }
        catch { Issue.record("move: \(error)"); completion(nil) }
    }
    sidebar.layoutSubtreeIfNeeded()
    func space() -> SpaceSnapshot { store.snapshot(windowId: "organize").spaces.first { $0.id == "organize-work" }! }
    func row(_ name: String) throws -> Row { try #require((space().pinned + space().today + space().favorites).first { $0.url == "about:blank?organize-\(name)" }) }
    let today = try row("today")
    #expect(sidebar.organizeCheckBegin(id: today.id, destination: "organize-outer"))
    #expect(sidebar.organizeCheckDropLine && sidebar.organizeCheckEnd())
    #expect(try row("today").parentId == space().pinnedId && sidebar.organizeCheckHint(id: today.id))
    #expect(try sidebar.organizeCheckBegin(id: row("folder").id, destination: "organize-inner"))
    #expect(sidebar.organizeCheckEnd())
    #expect(try row("folder").parentId == "organize-inner")
    #expect(try sidebar.organizeCheckBegin(id: row("favorite").id, destination: "favorites"))
    #expect(sidebar.organizeCheckEnd())
    #expect(try row("favorite").parentId == "organize-favorites")
    #expect(try sidebar.organizeCheckBegin(id: row("dock").id, destination: "dock"))
    #expect(sidebar.organizeCheckEnd())
    let result = store.snapshot(windowId: "organize")
    #expect(result.shownSpaceId == "organize-work")
    #expect(result.spaces.first { $0.id == "organize-other" }?.pinned.contains { $0.url == "about:blank?organize-dock" } == true)
}

@MainActor
private func startDrag(_ sidebar: SidebarView, id: String) throws -> SidebarRowView {
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == id })
    let frame = try #require(sidebar.dragGeometry()?.rows.first { $0.row.id == id }?.frame)
    row.mouseDown(with: try dragEvent(.leftMouseDown, sidebar: sidebar, position: CGPoint(x: frame.midX, y: frame.midY)))
    #expect(sidebar.selectedRowID == id || row.row.kind == .folder)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: CGPoint(x: frame.midX + 4, y: frame.midY)))
    if row.row.kind == .folder { #expect(sidebar.drag == nil) }
    else { #expect(sidebar.drag?.active == true) }
    return row
}

@Test @MainActor
func emptyFavoritesDoNotCoverPinnedDropTargets() throws {
    for hasPin in [false, true] {
        let original = dragSpace(pinned: hasPin ? [dragRow("pin", "ps")] : [], today: [dragRow("a", "ts")])
        let space = SpaceSnapshot(pinnedCount: original.pinnedCount, todayCount: original.todayCount, profileKey: original.profileKey, pinnedId: original.pinnedId, todayId: original.todayId, favoritesId: nil, archiveAfter: original.archiveAfter, profileName: original.profileName, profile: original.profile, id: original.id, title: original.title, icon: original.icon, look: original.look, favorites: original.favorites, pinned: original.pinned, today: original.today)
        let (window, sidebar) = dragWindow(space)
        defer { window.contentView = nil }
        let row = try startDrag(sidebar, id: "a")
        let g = try #require(sidebar.dragGeometry())
        let point = hasPin ? CGPoint(x: 30, y: try #require(g.rows.first { $0.row.id == "pin" }).frame.minY + 0.5) : CGPoint(x: g.pinnedArea.midX, y: g.pinnedArea.midY)
        #expect(!g.favorites.contains(point))
        row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
        guard case .insert(let container, let index, _, _) = sidebar.dropTarget else { Issue.record("expected pinned insertion"); continue }
        #expect(container == space.pinnedId && index == 0)
        sidebar.cancelOperation(nil)
    }
}

@Test @MainActor
func firstFavoriteDropCreatesContainerAndSettles() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "first-favorite", card: NSView(), session: session)
    let initial = try session.queue.sync { try #require(session.store).createTab(windowId: "first-favorite", url: "about:blank?favorite") }
    let space = try #require(initial.spaces.first)
    let id = try #require(initial.selectedId)
    #expect(space.favoritesId == nil)
    let sidebar = SidebarView(snapshot: initial)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.dragReduceMotion = { true }
    let adapter = WorkspaceAdapter(windowID: "first-favorite", session: session)
    let actions = SidebarActions()
    actions.configureEditing(adapter: adapter, isActive: { true }, window: { window }, show: { _ in }, record: { _ in })
    actions.bind(to: sidebar)
    sidebar.layoutSubtreeIfNeeded()
    let row = try startDrag(sidebar, id: id)
    let zone = try #require(sidebar.dragGeometry()?.favorites)
    #expect(zone.height > 0 && zone.height <= 8.5)
    let point = CGPoint(x: zone.midX, y: zone.midY)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
    sidebar.stepDrag()
    #expect(sidebar.dropTarget == .favorites(container: nil, index: 0))
    row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
    try await waitUntil { sidebar.drag == nil && sidebar.dragCopyView == nil }
    let result = try session.queue.sync { try #require(session.store).snapshot(windowId: "first-favorite") }
    let updated = try #require(result.spaces.first)
    #expect(updated.favoritesId != nil && updated.favorites.first?.id == id)
    #expect(dragDescendants(sidebar).compactMap { $0 as? FavoriteTile }.contains { $0.row.id == id })
}

@Test @MainActor
func inProcessDragsMapEveryTargetOnceAndKeepOtherRowsStill() throws {
    for target in 0..<5 {
        let (window, sidebar) = dragWindow()
        defer { window.contentView = nil }
        var moves: [(String, String, Int, Bool)] = []
        sidebar.onMove = { id, container, index, open, completion in
            moves.append((id, container, index, open))
            completion(nil)
        }
        let row = try startDrag(sidebar, id: "a")
        let geometry = try #require(sidebar.dragGeometry())
        let before = geometry.rows.map(\.frame)
        let point: CGPoint
        let container: String
        switch target {
        case 0: point = CGPoint(x: 30, y: geometry.rows[0].frame.minY); container = "ps"
        case 1: point = CGPoint(x: 30, y: geometry.rows[1].frame.midY); container = "folder"
        case 2: point = CGPoint(x: 30, y: geometry.favorites.midY); container = "fdefault"
        case 3: point = CGPoint(x: geometry.dock[1].frame.midX, y: geometry.dock[1].frame.midY); container = "tother"
        default: point = CGPoint(x: 30, y: geometry.rows.last!.frame.maxY); container = "ts"
        }
        row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
        if target != 2 { #expect(sidebar.dragGeometry()?.rows.map(\.frame) == before) }
        if target == 0 {
            let box = try #require(sidebar.dropIndicator.path?.boundingBoxOfPath)
            #expect(abs(box.midY - (sidebar.bounds.height - geometry.rows[0].frame.minY)) < 0.01)
            #expect(sidebar.dropIndicator.lineWidth == 2)
        }
        if target == 2 {
            let tiles = dragDescendants(sidebar).compactMap { $0 as? FavoriteTile }
            #expect(tiles.count == 2)
            #expect(abs(tiles[0].frame.width - (224.0 - 16) / 3) < 1)
        }
        row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
        row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
        #expect(moves.count == 1)
        #expect(moves.first?.0 == "a" && moves.first?.1 == container)
        #expect(moves.first?.3 == (target == 1))
        #expect(sidebar.drag == nil && sidebar.dragCopyView == nil && !sidebar.dragSettling)
        #expect(!window.isVisible && !window.isKeyWindow)
    }
}

@Test @MainActor
func refusedFolderDropAndEscapeNeverMoveOrLeaveDragState() throws {
    for escape in [false, true] {
        let (window, sidebar) = dragWindow()
        defer { window.contentView = nil }
        var moves = 0
        sidebar.onMove = { _, _, _, _, completion in moves += 1; completion(nil) }
        let row = try startDrag(sidebar, id: escape ? "a" : "folder")
        let geometry = try #require(sidebar.dragGeometry())
        let point = CGPoint(x: 30, y: escape ? geometry.rows[0].frame.minY : geometry.favorites.midY)
        row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
        if escape { sidebar.cancelOperation(nil) } else { #expect(sidebar.dropTarget == .refused) }
        row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
        #expect(moves == 0 && sidebar.drag == nil && sidebar.dragCopyView == nil)
    }
}

@Test @MainActor
func folderHoverUsesInjectedClockAndOnlyOpensOnce() throws {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    var now = 10.0
    sidebar.dragClock = { now }
    var opened: [String] = []
    sidebar.onOpenFolder = { id, completion in opened.append(id); completion(nil) }
    let row = try startDrag(sidebar, id: "a")
    let nested = try #require(sidebar.dragGeometry()?.rows.first { $0.row.id == "nested" })
    let point = CGPoint(x: nested.frame.midX, y: nested.frame.midY)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
    now += 0.599
    sidebar.stepDrag()
    #expect(opened.isEmpty)
    now += 0.002
    sidebar.stepDrag()
    sidebar.stepDrag()
    #expect(opened == ["nested"])
    sidebar.cancelOperation(nil)
}

@Test @MainActor
func favoritesStartDraggingThroughTheirOwnEvents() throws {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    let tile = try #require(dragDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first)
    let local = sidebar.convert(tile.bounds, from: tile)
    let position = CGPoint(x: local.midX, y: sidebar.bounds.height - local.midY)
    var selections = 0
    sidebar.onSelect = { _ in selections += 1 }
    tile.mouseDown(with: try dragEvent(.leftMouseDown, sidebar: sidebar, position: position))
    tile.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: CGPoint(x: position.x + 4, y: position.y)))
    #expect(sidebar.drag?.active == true && selections == 1)
    sidebar.cancelOperation(nil)
    tile.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: position))
    #expect(selections == 1)
}

@Test @MainActor
func settleFinishesThroughAnimationCompletionWithoutSleep() async throws {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    sidebar.dragReduceMotion = { false }
    let row = try startDrag(sidebar, id: "a")
    row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: CGPoint(x: -20, y: 0)))
    #expect(sidebar.dragSettling)
    let copy = try #require(sidebar.dragCopyView)
    #expect(copy.layer?.animation(forKey: "drag.settle")?.duration == 0.1)
    CATransaction.flush()
    copy.layer?.removeAnimation(forKey: "drag.settle")
    for _ in 0..<100 where sidebar.dragSettling { await Task.yield() }
    #expect(!sidebar.dragSettling && sidebar.dragCopyView == nil)
}

@Test @MainActor
func dragAutoscrollUsesClockAndBlocksHorizontalSpaceChanges() throws {
    let today = (0..<40).map { dragRow("t\($0)", "ts", UInt32($0)) }
    let (window, sidebar) = dragWindow(dragSpace(pinned: [dragRow("pin", "ps")], today: today))
    defer { window.contentView = nil }
    var now = 10.0
    sidebar.dragClock = { now }
    let row = try startDrag(sidebar, id: "t0")
    let list = try #require(sidebar.dragGeometry()?.list)
    let scroll = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: CGPoint(x: list.midX, y: list.maxY - 1)))
    now += 0.1
    sidebar.stepDrag()
    #expect(abs(scroll.contentView.bounds.minY - 24) < 0.01)
    let origin = scroll.contentView.bounds.minY
    now += 0.05
    sidebar.stepDrag()
    #expect(abs(scroll.contentView.bounds.minY - origin - 12) < 0.01)
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -100, wheel3: 0))
    let event = try #require(NSEvent(cgEvent: cg))
    sidebar.scrollWheel(with: event)
    #expect(sidebar.spaceShown == 0)
    #expect(!sidebar.canPublishAutoArchive)
    sidebar.cancelOperation(nil)
    #expect(sidebar.canPublishAutoArchive)
}

@Test @MainActor
func successfulMovePreservesSelectionScrollAndCoreFolderState() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore.open(path: directory.appendingPathComponent("drag.sqlite").path)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
    _ = try store.importArcSidebar(windowId: "drag", json: String(contentsOf: fixture, encoding: .utf8), windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil).snapshot
    _ = try store.createSpace(windowId: "drag", name: "Other", spaceId: "other")
    try store.showSpace(windowId: "drag", spaceId: "space-work")
    _ = try store.setFolderCollapsed(windowId: "drag", id: "folder-docs", collapsed: true)
    let selected = try store.selectItem(windowId: "drag", id: "tab-mail")
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: selected)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    sidebar.dragReduceMotion = { true }
    var moves = 0
    sidebar.onMove = { id, container, index, open, completion in
        moves += 1
        do {
            let snapshot = try store.moveItem(windowId: "drag", id: id, container: container, index: UInt32(index), openFolder: open)
            completion(snapshot)
        } catch { Issue.record("move failed: \(error)"); completion(nil) }
    }
    let tile = try #require(dragDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first)
    let tileFrame = sidebar.convert(tile.bounds, from: tile)
    let press = CGPoint(x: tileFrame.midX, y: sidebar.bounds.height - tileFrame.midY)
    tile.mouseDown(with: try dragEvent(.leftMouseDown, sidebar: sidebar, position: press))
    let folder = try #require(sidebar.dragGeometry()?.rows.first { $0.row.id == "folder-docs" })
    let drop = CGPoint(x: folder.frame.midX, y: folder.frame.midY)
    tile.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: drop))
    tile.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: drop))
    let result = store.snapshot(windowId: "drag")
    #expect(moves == 1 && result.selectedId == "tab-mail" && sidebar.selectedRowID == "tab-mail")
    let space = try #require(result.spaces.first { $0.id == "space-work" })
    #expect(space.pinned.first { $0.id == "tab-mail" }?.parentId == "folder-docs")
    #expect(space.pinned.first { $0.id == "folder-docs" }?.collapsed == false)
    #expect(result.shownSpaceId == "space-work" && sidebar.spaceShown == 0)
    #expect(sidebar.dragCopyView == nil)
    #expect(!window.isVisible)
}

@Test @MainActor
func middlePressAndPinnedButtonNeverSelectOrStartDragging() throws {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    var selections = 0
    var closes: [String] = []
    var archives: [String] = []
    sidebar.onSelect = { _ in selections += 1 }
    sidebar.onClose = { closes.append($0) }
    sidebar.onArchive = { archives.append($0) }
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "pin" })
    for type in [CGEventType.otherMouseDown, .otherMouseUp] {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center))
        let event = try #require(NSEvent(cgEvent: cg))
        if type == .otherMouseDown { row.otherMouseDown(with: event) } else { row.otherMouseUp(with: event) }
        #expect(selections == 0 && sidebar.drag == nil)
    }
    #expect(closes.isEmpty && archives == ["pin"])
    row.closeButton.performClick(nil)
    #expect(archives == ["pin", "pin"] && selections == 0 && sidebar.selectedRowID == "b")
    sidebar.updateSelection(id: "pin")
    row.closeButton.performClick(nil)
    #expect(closes == ["pin"] && selections == 0 && sidebar.drag == nil)
}

@Test @MainActor
func adapterMoveAndFolderOpenPublishTheCoreResult() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let adapter = WorkspaceAdapter(windowID: "drag-adapter")
    func value<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
    }
    _ = try await value { adapter.open(path: directory.appendingPathComponent("workspace.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let selected = try await value { adapter.select(id: "tab-mail", completion: $0) }
    let moved = try await value { adapter.move(id: "tab-mail", container: "folder-docs", index: 0, openFolder: true, completion: $0) }
    #expect(moved.selectedId == selected.selectedId)
    #expect(moved.spaces[0].pinned.first { $0.id == "tab-mail" }?.parentId == "folder-docs")
    #expect(moved.spaces[0].pinned.first { $0.id == "folder-docs" }?.collapsed == false)
    let opened = try await value { adapter.openFolder(id: "folder-docs", completion: $0) }
    #expect(opened == moved)
    do {
        _ = try await value { adapter.move(id: "tab-mail", container: "pin-home", index: 0, openFolder: false, completion: $0) }
        Issue.record("cross-profile move was accepted")
    } catch { #expect(error is CoreError) }
    let unchanged = try await value { adapter.snapshot(completion: $0) }
    #expect(unchanged == moved)
    _ = try await value { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func draggingSplitMemberMovesTheWholeSplit() throws {
    let split = dragRow("split", "ps", kind: .split)
    let member = dragRow("member", "split", depth: 1)
    let (window, sidebar) = dragWindow(dragSpace(pinned: [split, member], today: [dragRow("a", "ts")]))
    defer { window.contentView = nil }
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "member" })
    let frame = sidebar.convert(row.bounds, from: row)
    let press = CGPoint(x: frame.midX, y: sidebar.bounds.height - frame.midY)
    var moved: [String] = []
    sidebar.onMove = { id, _, _, _, done in moved.append(id); done(nil) }
    row.mouseDown(with: try dragEvent(.leftMouseDown, sidebar: sidebar, position: press))
    #expect(sidebar.selectedRowID == "member")
    let target = try #require(sidebar.dragGeometry()?.rows.first { $0.row.id == "a" })
    let point = CGPoint(x: target.frame.midX, y: target.frame.maxY)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
    row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
    #expect(moved == ["split"])
}

@Test @MainActor
func movedRowKeepsTheVisibleScrollAnchorAndDoesNotReveal() throws {
    let today = (0..<40).map { dragRow("t\($0)", "ts", UInt32($0)) }
    let original = dragSpace(pinned: [dragRow("pin", "ps")], today: today)
    let (window, sidebar) = dragWindow(original)
    defer { window.contentView = nil }
    let scroll = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    scroll.move(to: 600)
    let row = try startDrag(sidebar, id: "t16")
    let anchor = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "t14" })
    let before = sidebar.convert(anchor.bounds, from: anchor)
    var moved = today[16]
    var after = original
    after.today.remove(at: 16)
    moved.siblingIndex = UInt32(after.today.count)
    after.today.append(moved)
    for index in after.today.indices { after.today[index].siblingIndex = UInt32(index) }
    sidebar.onMove = { _, _, _, _, done in
        done(WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: "t16", spaces: [after, dragSpace("other")]))
    }
    let cell = try #require(sidebar.dragGeometry()?.dock.first)
    let point = CGPoint(x: cell.frame.midX, y: cell.frame.midY)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
    row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
    #expect(sidebar.convert(anchor.bounds, from: anchor) == before)
    #expect(sidebar.selectedRowID == "t16" && !scroll.isRevealing)
}

@Test @MainActor
func clickingSplitMemberSelectsItWithoutMovingTheSplit() throws {
    let (window, sidebar) = dragWindow(dragSpace(pinned: [dragRow("split", "ps", kind: .split), dragRow("member", "split", depth: 1)]))
    defer { window.contentView = nil }
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "member" })
    let rect = sidebar.convert(row.bounds, from: row)
    let point = CGPoint(x: rect.midX, y: sidebar.bounds.height - rect.midY)
    var selected: [String] = []
    var moves = 0
    sidebar.onSelect = { selected.append($0.id) }
    sidebar.onMove = { _, _, _, _, done in moves += 1; done(nil) }
    row.mouseDown(with: try dragEvent(.leftMouseDown, sidebar: sidebar, position: point))
    row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
    #expect(selected == ["member"] && sidebar.selectedRowID == "member" && moves == 0)
}

@Test
func folderLowerBandResolvesFirstChildOrAfterClosedEmptyFolder() throws {
    let a = dragRow("a", "ts")
    for expanded in [true, false] {
        for empty in [true, false] {
            let folder = dragRow("folder", "ps", 1, kind: .folder, collapsed: !expanded)
            let children = expanded && !empty ? [dragRow("child", "folder", depth: 1)] : []
            let g = pureGeometry(dragSpace(pinned: [dragRow("pin", "ps"), folder] + children, today: [a]))
            let rect = g.rows[1].frame
            for y in [rect.maxY - SidebarDragMetrics.rowBoundaryInset, rect.maxY - 0.001] {
                let expected: SidebarDrop = expanded && !empty
                    ? .insert(container: "folder", index: 0, lineY: rect.maxY, depth: 1)
                    : .insert(container: "ps", index: 2, lineY: rect.maxY, depth: 0)
                #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: y), geometry: g, dragged: a) == expected)
            }
            #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: rect.maxY - SidebarDragMetrics.rowBoundaryInset - 0.001), geometry: g, dragged: a) == .folder("folder"))
        }
    }
}

@MainActor
private final class DragNativeScrollProbe: SidebarScrollView {
    var onNative: (() -> Void)?
    var nativeCalls = 0
    override func scrollNatively(with event: NSEvent) { nativeCalls += 1; onNative?() }
}

@Test @MainActor
func draggingAllowsVerticalScrollAndRetargetsUnderTheStillPointer() throws {
    let (window, sidebar) = dragWindow(dragSpace(today: (0..<40).map { dragRow("t\($0)", "ts", UInt32($0)) }))
    defer { window.contentView = nil }
    _ = try startDrag(sidebar, id: "t0")
    let geometry = try #require(sidebar.dragGeometry())
    let point = CGPoint(x: geometry.list.midX, y: geometry.rows[2].frame.midY - 1)
    sidebar.moveDrag(to: point)
    let before = sidebar.dropTarget
    let list = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    let native = DragNativeScrollProbe()
    native.onScroll = list.onScroll
    native.onNative = { list.move(to: list.contentView.bounds.minY + 41) }
    for trackpad in [false, true] {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -41, wheel2: 0, wheel3: 0))
        if trackpad { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue)) }
        let event = try #require(NSEvent(cgEvent: cg))
        native.scrollWheel(with: event)
    }
    #expect(native.nativeCalls == 2 && list.contentView.bounds.minY == 82)
    for trackpad in [false, true] {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -100, wheel3: 0))
        if trackpad { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue)) }
        native.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    }
    #expect(native.nativeCalls == 2)
    #expect(sidebar.dropTarget != before)
    #expect(sidebar.drag?.position == point && sidebar.spaceShown == 0)
    sidebar.cancelOperation(nil)
}

@Test @MainActor
func onlySuccessfulSameSpaceTodayDragShowsRenameHint() throws {
    for target in 0..<4 {
        let (window, sidebar) = dragWindow()
        defer { window.contentView = nil }
        sidebar.renameHintClock = { 100 }
        let row = try startDrag(sidebar, id: "a")
        let geometry = try #require(sidebar.dragGeometry())
        let container = target == 2 ? "pother" : "ps"
        sidebar.onMove = { _, _, _, _, done in
            guard target != 1 else { done(nil); return }
            var a = row.row
            a.parentId = container
            let source = dragSpace(pinned: target == 2 ? [] : [a], today: [])
            let other = dragSpace("other", pinned: target == 2 ? [a] : [])
            done(WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: "a", spaces: [source, other]))
        }
        let point = target == 2 ? CGPoint(x: geometry.dock[1].frame.midX, y: geometry.dock[1].frame.midY) : CGPoint(x: 30, y: geometry.rows[0].frame.minY)
        row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
        row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
        let hint = try #require(dragDescendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Double-click to rename" })
        #expect(hint.isHidden == (target == 1 || target == 2))
        if target == 3 {
            sidebar.showSpace(at: 1)
            #expect(hint.isHidden)
        }
    }
}

@Test
func folderEndBoundaryLevelsFollowThePointerX() throws {
    let dragged = dragRow("a", "ts")
    let owner = pureGeometry(dragSpace(pinned: [dragRow("b", "ps"), dragRow("untitled", "ps", 1, kind: .folder),
                                                dragRow("google", "untitled", 0, depth: 1), dragRow("example", "untitled", 1, depth: 1)],
                                       today: [dragged]))
    // Rows: b 180-221, untitled 221-262, google 262-303, example 303-344, a 344-385.
    let end = owner.rows[3].frame.maxY
    // Over the child's title the drop stays inside, after the row above.
    #expect(resolveSidebarDrop(position: CGPoint(x: 60, y: 338), geometry: owner, dragged: dragged) == .insert(container: "untitled", index: 2, lineY: end, depth: 1))
    // Left of the child's indent it is the end of pinned, whatever the x is below the band.
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 338), geometry: owner, dragged: dragged) == .insert(container: "ps", index: 2, lineY: end, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 8, y: 338), geometry: owner, dragged: dragged) == .insert(container: "ps", index: 2, lineY: end, depth: 0))
}

@Test
func nestedFolderEndsReachEveryLevel() throws {
    let dragged = dragRow("a", "ts")
    let g = pureGeometry(dragSpace(pinned: [dragRow("pinA", "ps", kind: .folder), dragRow("sub", "pinA", kind: .folder, depth: 1),
                                            dragRow("leaf", "sub", depth: 2)], today: [dragged]))
    // Rows: pinA 180-221, sub 221-262, leaf 262-303, a 303-344; the boundary ends all three levels.
    let end = g.rows[2].frame.maxY
    #expect(resolveSidebarDrop(position: CGPoint(x: 60, y: 290), geometry: g, dragged: dragged) == .insert(container: "sub", index: 1, lineY: end, depth: 2))
    #expect(resolveSidebarDrop(position: CGPoint(x: 40, y: 290), geometry: g, dragged: dragged) == .insert(container: "pinA", index: 1, lineY: end, depth: 1))
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 290), geometry: g, dragged: dragged) == .insert(container: "ps", index: 1, lineY: end, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 8, y: 290), geometry: g, dragged: dragged) == .insert(container: "ps", index: 1, lineY: end, depth: 0))
}

@Test
func theRootLevelIsOfferedOnlyWherePinnedEnds() throws {
    let dragged = dragRow("a", "ts")
    let g = pureGeometry(dragSpace(pinned: [dragRow("pinA", "ps", kind: .folder), dragRow("sub", "pinA", kind: .folder, depth: 1),
                                            dragRow("leaf", "sub", depth: 2), dragRow("z", "ps", 1)], today: [dragged]))
    // Rows: pinA 180-221, sub 221-262, leaf 262-303, z 303-344; pinned continues after leaf, so no root level.
    let end = g.rows[2].frame.maxY
    #expect(resolveSidebarDrop(position: CGPoint(x: 60, y: 290), geometry: g, dragged: dragged) == .insert(container: "sub", index: 1, lineY: end, depth: 2))
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 290), geometry: g, dragged: dragged) == .insert(container: "pinA", index: 1, lineY: end, depth: 1))
}

@Test
func pinnedEndBoundsTheDividerGapAndTheTrailingZone() throws {
    let dragged = dragRow("a", "ts")
    let space = dragSpace(pinned: [dragRow("b", "ps"), dragRow("untitled", "ps", 1, kind: .folder),
                                   dragRow("google", "untitled", 0, depth: 1), dragRow("example", "untitled", 1, depth: 1)],
                          today: [dragged])
    let g = SidebarDragGeometry(bounds: CGRect(x: 0, y: 0, width: 240, height: 700), list: CGRect(x: 8, y: 180, width: 224, height: 450),
        pinnedArea: CGRect(x: 8, y: 149, width: 224, height: 31), favorites: CGRect(x: 8, y: 90, width: 224, height: 47),
        rows: [ .init(row: space.pinned[0], frame: CGRect(x: 8, y: 180, width: 224, height: 41)),
                .init(row: space.pinned[1], frame: CGRect(x: 8, y: 221, width: 224, height: 41)),
                .init(row: space.pinned[2], frame: CGRect(x: 8, y: 262, width: 224, height: 41)),
                .init(row: space.pinned[3], frame: CGRect(x: 8, y: 303, width: 224, height: 41)),
                .init(row: space.today[0], frame: CGRect(x: 8, y: 385, width: 224, height: 41)) ],
        dock: [], space: space)
    // The row's lower band and the gap above the divider mid-point give the same answer.
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 338), geometry: g, dragged: dragged) == .insert(container: "ps", index: 2, lineY: 344, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 360), geometry: g, dragged: dragged) == .insert(container: "ps", index: 2, lineY: 344, depth: 0))
    // Below the mid-point the drop goes before the first Today row.
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 370), geometry: g, dragged: dragged) == .insert(container: "ts", index: 0, lineY: 385, depth: 0))
    // With Today empty the zone below the last pinned row offers the same levels.
    let emptyToday = SidebarDragGeometry(bounds: g.bounds, list: g.list, pinnedArea: g.pinnedArea, favorites: g.favorites,
        rows: g.rows.prefix(4).map { $0 }, dock: [], space: dragSpace(profile: "default",
            pinned: [dragRow("b", "ps"), dragRow("untitled", "ps", 1, kind: .folder),
                     dragRow("google", "untitled", 0, depth: 1), dragRow("example", "untitled", 1, depth: 1)], today: []))
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 360), geometry: emptyToday, dragged: dragged) == .insert(container: "ps", index: 2, lineY: 344, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 60, y: 360), geometry: emptyToday, dragged: dragged) == .insert(container: "untitled", index: 2, lineY: 344, depth: 1))
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 390), geometry: emptyToday, dragged: dragged) == .insert(container: "ts", index: 0, lineY: 344, depth: 0))
}

@Test
func aCollapsedFolderBoundaryDoesNotLevel() throws {
    let dragged = dragRow("a", "ts")
    let g = pureGeometry()
    // The collapsed nested row has no ending ancestor (folder's last visible row is child): the
    // answer must not depend on x. Rows: nested 262-303.
    for x in [8.0, 30, 60] {
        #expect(resolveSidebarDrop(position: CGPoint(x: x, y: 302), geometry: g, dragged: dragged) == .insert(container: "folder", index: 1, lineY: 303, depth: 1))
    }
}

@Test @MainActor
func foreignDockRefusalDimsCellAndRestoresCursor() throws {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    var snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: "b", spaces: [dragFixture(), dragSpace("foreign", profile: "other")])
    sidebar.update(snapshot: snapshot)
    var cursors: [Bool] = []
    sidebar.dockCursor = { cursors.append($0) }
    let row = try startDrag(sidebar, id: "a")
    let geometry = try #require(sidebar.dragGeometry())
    let foreign = geometry.dock[1].frame
    let point = CGPoint(x: foreign.midX, y: foreign.midY)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
    let dock = try #require(dragDescendants(sidebar).compactMap { $0 as? SpaceDockView }.first)
    #expect(dock.cellStates[1].refused)
    #expect(dock.subviews[1].alphaValue == 0.35)
    #expect(cursors.last == true)
    sidebar.cancelOperation(nil)
    #expect(!dock.cellStates[1].refused && dock.subviews[1].alphaValue == 1)
    #expect(cursors.last == false)
    snapshot.spaces.removeLast()
}

@Test @MainActor
func leavingForeignDockRestoresCursorBeforeDrop() throws {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    sidebar.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: "b", spaces: [dragFixture(), dragSpace("foreign", profile: "other")]))
    var cursors: [Bool] = []
    sidebar.dockCursor = { cursors.append($0) }
    let row = try startDrag(sidebar, id: "a")
    let geometry = try #require(sidebar.dragGeometry())
    let foreign = geometry.dock[1].frame
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: CGPoint(x: foreign.midX, y: foreign.midY)))
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: CGPoint(x: geometry.list.midX, y: geometry.list.midY)))
    #expect(cursors == [true, false])
    let dock = try #require(dragDescendants(sidebar).compactMap { $0 as? SpaceDockView }.first)
    #expect(!dock.cellStates[1].refused)
    sidebar.cancelOperation(nil)
}
