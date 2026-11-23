import AppKit
import AraratKit
import Testing
@testable import AraratUI

private func dragRow(_ id: String, _ parent: String, _ index: UInt32 = 0, kind: RowKind = .tab, collapsed: Bool = false, depth: UInt32 = 0) -> Row {
    Row(folderHasTabs: false, parentId: parent, siblingIndex: index, collapsed: collapsed, id: id, title: id, url: kind == .tab ? "https://\(id).example" : nil,
        depth: depth, kind: kind, unloaded: false, lastSelectedAt: nil)
}

private func dragSpace(_ id: String = "s", profile: String = "default", pinned: [Row] = [], today: [Row] = [], favorites: [Row] = []) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: UInt32(pinned.filter { $0.parentId == "p\(id)" }.count), todayCount: UInt32(today.filter { $0.parentId == "t\(id)" }.count), profileKey: profile, pinnedId: "p\(id)", todayId: "t\(id)", favoritesId: "f\(id)", archiveAfter: .hours12,
                  profileName: profile, profile: .named(profile), id: id, title: id, icon: nil, look: nil, favorites: favorites, pinned: pinned, today: today)
}

private func dragFixture() -> SpaceSnapshot {
    dragSpace(pinned: [dragRow("pin", "ps"), dragRow("folder", "ps", 1, kind: .folder),
                      dragRow("nested", "folder", kind: .folder, collapsed: true, depth: 1),
                      dragRow("child", "folder", 1, depth: 1)], today: [dragRow("a", "ts"), dragRow("b", "ts", 1)],
              favorites: [dragRow("fav0", "fs"), dragRow("fav1", "fs", 1)])
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
func favoriteDropUsesTheEmptyGridRoot() {
    let space = dragSpace(today: [dragRow("a", "ts")])
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 100), geometry: pureGeometry(space), dragged: space.today[0]) == .favorites(container: "fs", index: 0))
}

@Test @MainActor
func numberedSpaceMoveAppendsToTheTargetFavorites() {
    let favorite = dragRow("moving", "fs")
    let source = dragSpace(favorites: [favorite])
    let target = dragSpace("other", favorites: [dragRow("existing", "fother")])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: source.id,
        selectedId: favorite.id, spaces: [source, target]))
    var moved = false
    sidebar.onMove = { id, container, index, openFolder, completion in
        moved = true
        #expect(id == favorite.id && container == "fother" && index == 1 && !openFolder)
        completion(nil)
    }
    sidebar.organize(command: "move_to_space_2")
    #expect(moved)
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
        #expect(resolveSidebarDrop(position: CGPoint(x: x, y: 100), geometry: g, dragged: a) == .favorites(container: "fs", index: index))
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
    #expect(resolveSidebarDrop(position: CGPoint(x: 50, y: 660), geometry: g, dragged: favorite) == .dock(space: "other", container: "fother", index: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 84, y: 660), geometry: g, dragged: favorite) == .refused)
    #expect(resolveSidebarDrop(position: CGPoint(x: 230, y: 100), geometry: g, dragged: favorite) == .favorites(container: "fs", index: 1))
    #expect(resolveSidebarDrop(position: CGPoint(x: 40, y: 330), geometry: g, dragged: a) == .insert(container: "folder", index: 2, lineY: 344, depth: 1))
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 261), geometry: g, dragged: a) == .insert(container: "folder", index: 0, lineY: 262, depth: 1))
    let empty = pureGeometry(dragSpace())
    // A drop on the space name pins at the top of pinned, with no pins too (design).
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
    let copy = sidebar.dragCopyView
    #expect(copy?.closeButton.isHidden == true)
    #expect(sidebar.dropIndicator.zPosition > (copy?.layer?.zPosition ?? 0))
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
    #expect(try row("favorite").parentId == "organize-work:favorites")
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
        guard case .insert(let container, let index, _, _) = sidebar.dropTarget else { Issue.record("expected an insertion"); continue }
        // A drop on the space name pins at the top of pinned, with no pins too.
        #expect(container == space.pinnedId && index == 0)
        sidebar.cancelOperation(nil)
    }
}

@Test @MainActor
func firstFavoriteDropUsesExistingSpaceContainerAndSettles() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path, windowID: "first-favorite", card: NSView(), seedOrganize: true, session: session)
    let store = try #require(session.store)
    let space = try #require(store.snapshot(windowId: "first-favorite").spaces.first { $0.id == "organize-other" })
    let id = try #require(space.today.first?.id)
    let initial = try store.showSpaceSelectingTab(windowId: "first-favorite", spaceId: space.id, itemId: id)
    let root = try #require(space.favoritesId)
    #expect(space.favorites.isEmpty)
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
    let zone = try #require(sidebar.dragGeometry()?.favorites)
    #expect(zone.height > 0 && zone.height <= 8.5)
    #expect(sidebar.organizeCheckBegin(id: id, destination: "favorites"))
    sidebar.stepDrag()
    #expect(sidebar.dropTarget == .favorites(container: root, index: 0))
    #expect(sidebar.organizeCheckEnd())
    try await waitUntil { sidebar.drag == nil && sidebar.dragCopyView == nil }
    let result = try session.queue.sync { try #require(session.store).snapshot(windowId: "first-favorite") }
    let updated = try #require(result.spaces.first { $0.id == space.id })
    #expect(updated.favoritesId == root && updated.favorites.map(\.id) == [id])
    let work = try #require(result.spaces.first { $0.id == "organize-work" })
    #expect(updated.profileKey == work.profileKey && updated.favoritesId != work.favoritesId)
    #expect(work.favorites.count == 2 && work.favorites.allSatisfy { $0.id != id })
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
        case 2: point = CGPoint(x: 30, y: geometry.favorites.midY); container = "fs"
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

@Suite struct SidebarFolderDragTests {
    @Test(arguments: [false, true]) @MainActor
    func heldDragSpringsAndRestoresTheFolderUntilDropped(cancel: Bool) throws {
        let directory = try testTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WorkspaceSession()
        let windowID = "organize"
        let folder = "organize-inner"
        _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                              windowID: windowID, card: NSView(), seedOrganize: true, session: session)
        let store = try #require(session.store)
        let seeded = try #require(store.snapshot(windowId: windowID).spaces.first { $0.id == "organize-work" })
        let child = try #require(seeded.pinned.first { $0.url == "about:blank?organize-folder" })
        let source = try #require(seeded.today.first { $0.url == "about:blank?organize-today" })
        _ = try store.moveItem(windowId: windowID, id: child.id, container: folder, index: 0, openFolder: false)
        let initial = try store.selectItem(windowId: windowID, id: source.id)
        func pinned(_ snapshot: WorkspaceSnapshot) -> [Row] {
            snapshot.spaces.first { $0.id == "organize-work" }?.pinned ?? []
        }
        #expect(pinned(initial).first { $0.id == folder }?.collapsed == true)

        let (window, sidebar) = dragWindow(seeded)
        defer { window.contentView = nil }
        sidebar.update(snapshot: initial)
        var now = 10.0
        sidebar.dragClock = { now }
        sidebar.onFolderDragRows = { id, completion in
            completion(store.folderDragRows(windowId: windowID, folderId: id))
        }
        sidebar.onMove = { id, container, index, open, completion in
            #expect(!cancel && id == source.id && container == folder && open)
            do { completion(try store.moveItem(windowId: windowID, id: id, container: container, index: UInt32(index), openFolder: open)) }
            catch { Issue.record("move: \(error)"); completion(nil) }
        }

        let originFrame = try #require(sidebar.rowFrameForCheck(source.id))
        let headFrame = try #require(sidebar.rowFrameForCheck(folder))
        let head = CGPoint(x: headFrame.midX, y: headFrame.midY)
        try #require(sidebar.beginDragForCheck(id: source.id, at: CGPoint(x: originFrame.midX, y: originFrame.midY)))
        defer { sidebar.cancelOperation(nil) }
        sidebar.moveDragForCheck(to: head)
        now += 0.599
        sidebar.stepDrag()
        #expect(!sidebar.organizeCheckFolderOpen(id: folder))
        now += 0.002
        sidebar.stepDrag()
        try #require(sidebar.organizeCheckFolderOpen(id: folder))
        #expect(store.snapshot(windowId: windowID) == initial)

        if cancel {
            sidebar.cancelOperation(nil)
            #expect(sidebar.organizeCheckIdle && !sidebar.organizeCheckFolderOpen(id: folder))
            #expect(store.snapshot(windowId: windowID) == initial)
            return
        }

        sidebar.organizeCheckAim(at: CGPoint(x: head.x, y: 0))
        #expect(sidebar.organizeCheckDragging && !sidebar.organizeCheckFolderOpen(id: folder))
        #expect(store.snapshot(windowId: windowID) == initial)
        sidebar.moveDragForCheck(to: head)
        now += 0.601
        sidebar.stepDrag()
        try #require(sidebar.organizeCheckFolderOpen(id: folder))
        try #require(sidebar.releaseDragForCheck(at: head))
        let dropped = pinned(store.snapshot(windowId: windowID))
        #expect(dropped.first { $0.id == source.id }?.parentId == folder)
        #expect(dropped.first { $0.id == folder }?.collapsed == false)
    }

    @Test func hoverRequiresAClosedFolderWithTabs() throws {
        var folder = try #require(dragFixture().pinned.first { $0.id == "nested" })
        let hit = SidebarDrop.folder(folder.id)
        func candidate(_ drop: SidebarDrop) -> String? {
            sidebarSpringCandidate(drop: drop, rows: [.init(row: folder, frame: .zero)])
        }
        #expect(candidate(hit) == nil)
        folder.folderHasTabs = true
        #expect(candidate(.insert(container: "folder", index: 0, lineY: 0, depth: 1)) == nil)
        #expect(candidate(hit) == folder.id)
        folder.collapsed = false
        #expect(candidate(hit) == nil)
    }

    @Test func aimingAwayResetsThe600MillisecondDwell() {
        var hover = SidebarFolderHover()
        hover.aim(at: "folder", now: 0)
        #expect(hover.ready(now: 0.599) == nil)
        hover.aim(at: nil, now: 0.599)
        #expect(hover.ready(now: 0.6) == nil)
        hover.aim(at: "folder", now: 1)
        hover.aim(at: "folder", now: 1.5)
        #expect(hover.ready(now: 1.599) == nil)
        #expect(hover.ready(now: 1.601) == "folder")
        #expect(hover.ready(now: 2) == nil)
    }

    @Test func refoldAndFolderHeadUseTheYabThresholds() {
        #expect(sidebarShouldRefold(want: -0.801, last: 2, landsInside: false))
        #expect(!sidebarShouldRefold(want: -0.8, last: 2, landsInside: false))
        #expect(!sidebarShouldRefold(want: 3.5, last: 2, landsInside: false))
        #expect(sidebarShouldRefold(want: 3.501, last: 2, landsInside: false))
        #expect(!sidebarShouldRefold(want: 3.501, last: 2, landsInside: true))
        #expect(sidebarAimsIntoSprung(want: -0.5, alreadyAimingInside: false))
        #expect(!sidebarAimsIntoSprung(want: 0.6, alreadyAimingInside: false))
        #expect(sidebarAimsIntoSprung(want: 0.6, alreadyAimingInside: true))
    }

    @Test func previewRowsDoNotChangeTheStoreAndNestedDropsKeepTheirPathOpen() throws {
        let directory = try testTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WorkspaceStore.open(path: directory.appendingPathComponent("workspace.sqlite").path)
        let window = "drag"
        _ = try store.createSpace(windowId: window, name: "Work", spaceId: "work")
        _ = try store.createFolder(windowId: window, id: "outer", name: "Outer", container: "work:pinned", index: 0, wrapping: [])
        _ = try store.createFolder(windowId: window, id: "inner", name: "Inner", container: "outer", index: 0, wrapping: [])
        let child = try #require(store.createTab(windowId: window, url: "about:blank?child").selectedId)
        _ = try store.moveItem(windowId: window, id: child, container: "inner", index: 0, openFolder: false)
        let source = try #require(store.createTab(windowId: window, url: "about:blank?source").selectedId)
        _ = try store.setFolderCollapsed(windowId: window, id: "inner", collapsed: true)
        let before = try store.setFolderCollapsed(windowId: window, id: "outer", collapsed: true)
        let pinned = try #require(before.spaces.first?.pinned)
        let outer = store.folderDragRows(windowId: window, folderId: "outer")
        let inner = store.folderDragRows(windowId: window, folderId: "inner")
        let preview = sidebarPreviewPinned(pinned, sprungFolders: [("outer", outer), ("inner", inner)])
        #expect(preview.map(\.id) == ["outer", "inner", child])
        #expect(preview.map(\.depth) == [0, 1, 2])
        #expect(preview.allSatisfy { !$0.collapsed })
        #expect(store.snapshot(windowId: window) == before)
        let dropped = try store.moveItem(windowId: window, id: source, container: "inner", index: 1, openFolder: true)
        #expect(dropped.spaces.first?.pinned.map(\.id) == ["outer", "inner", child, source])
    }

    @Test func hapticTracksLandingInsteadOfLinePosition() {
        let pinned = SidebarDrop.insert(container: "pinned", index: 0, lineY: 10, depth: 0)
        let shifted = SidebarDrop.insert(container: "pinned", index: 0, lineY: 20, depth: 0)
        let reordered = SidebarDrop.insert(container: "pinned", index: 1, lineY: 20, depth: 0)
        let today = SidebarDrop.insert(container: "today", index: 0, lineY: 20, depth: 0)
        let folder = SidebarDrop.folder("folder")
        #expect(shifted.haptic(from: pinned, today: "today") == nil)
        #expect(reordered.haptic(from: pinned, today: "today") == .alignment)
        #expect(today.haptic(from: pinned, today: "today") == .levelChange)
        #expect(folder.haptic(from: pinned, today: "today") == .levelChange)
        #expect(pinned.haptic(from: folder, today: "today") == .levelChange)
    }
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
func middlePressAndPinnedButtonFollowTheLoadState() throws {
    // R1/D2: a loaded pin's −/middle click unloads it and keeps the pin; an unloaded pin's
    // ✕ archives it and the pin goes too. Selection does not decide.
    let loadedPin = dragRow("pin", "ps")
    let unloadedPin = Row(folderHasTabs: false, parentId: "ps", siblingIndex: 1, collapsed: false, id: "pin-off",
                          title: "pin-off", url: "https://pin-off.example", depth: 0, kind: .tab, unloaded: true, lastSelectedAt: nil)
    let space = dragSpace(pinned: [loadedPin, unloadedPin], today: [dragRow("a", "ts")])
    let (window, sidebar) = dragWindow(space)
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
    // The middle click on the loaded pin unloaded it, so the pin stayed.
    #expect(closes == ["pin"] && archives.isEmpty)
    row.closeButton.performClick(nil)
    #expect(closes == ["pin", "pin"] && archives.isEmpty && selections == 0 && sidebar.selectedRowID == "b")
    let off = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "pin-off" })
    off.closeButton.performClick(nil)
    #expect(archives == ["pin-off"] && closes == ["pin", "pin"] && selections == 0 && sidebar.drag == nil)
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
func draggingSplitRowMovesTheWholeSplit() throws {
    let split = dragRow("split", "ps", kind: .split)
    let member = dragRow("member", "split", depth: 1)
    let (window, sidebar) = dragWindow(dragSpace(pinned: [split, member], today: [dragRow("a", "ts")]))
    defer { window.contentView = nil }
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "split" })
    let frame = sidebar.convert(row.bounds, from: row)
    let press = CGPoint(x: frame.midX, y: sidebar.bounds.height - frame.midY)
    var moved: [String] = []
    sidebar.onMove = { id, _, _, _, done in moved.append(id); done(nil) }
    let down = try dragEvent(.leftMouseDown, sidebar: sidebar, position: press)
    let hit = try #require(window.contentView?.hitTest(down.locationInWindow))
    hit.mouseDown(with: down)
    #expect(sidebar.selectedRowID == "split")
    let target = try #require(sidebar.dragGeometry()?.rows.first { $0.row.id == "a" })
    let point = CGPoint(x: target.frame.midX, y: target.frame.maxY)
    hit.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
    hit.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
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
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "split" })
    let button = try #require(dragDescendants(row).compactMap { $0 as? SplitSegmentButton }.first { $0.paneTitle == "member" })
    var selected: [String] = []
    var moves = 0
    sidebar.onSelect = { selected.append($0.id) }
    sidebar.onMove = { _, _, _, _, done in moves += 1; done(nil) }
    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    let hit = try #require(window.contentView?.hitTest(point))
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    hit.mouseDown(with: down); hit.mouseUp(with: up)
    #expect(selected == ["member"] && sidebar.selectedRowID == "split" && moves == 0)
}

@Test @MainActor
func draggedSplitShowsItsPanesAsSegments() throws {
    let split = dragRow("split", "ts", kind: .split)
    let (window, sidebar) = dragWindow(dragSpace(today: [split, dragRow("b", "split", depth: 1), dragRow("c", "split", 1, depth: 1)]))
    defer { window.contentView = nil }
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "split" })
    let frame = try #require(sidebar.dragGeometry()?.rows.first { $0.row.id == "split" }?.frame)
    row.mouseDown(with: try dragEvent(.leftMouseDown, sidebar: sidebar, position: CGPoint(x: frame.midX, y: frame.midY)))
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: CGPoint(x: frame.midX + 4, y: frame.midY)))
    // The dragged row is the same split row, so it draws the same segments with the same focused
    // pane, and no row-level glyph behind them.
    let copy = try #require(sidebar.dragCopyView)
    copy.layoutSubtreeIfNeeded()
    let segments = dragDescendants(copy).compactMap { $0 as? SplitSegmentButton }
    #expect(segments.map(\.pane.id) == ["b", "c"])
    #expect(segments.map(\.active) == dragDescendants(row).compactMap { $0 as? SplitSegmentButton }.map(\.active))
    let glyph = try #require(copy.subviews.compactMap { $0 as? NSImageView }.first)
    #expect(glyph.isHidden)
    sidebar.cancelOperation(nil)
    #expect(sidebar.dragCopyView == nil)
    // A drag that starts on a pane's segment drags the split, and that pane is the focused one.
    let segment = try #require(dragDescendants(row).compactMap { $0 as? SplitSegmentButton }.first { $0.pane.id == "b" })
    let local = sidebar.convert(segment.bounds, from: segment)
    let position = CGPoint(x: local.midX, y: sidebar.bounds.height - local.midY)
    let hit = try #require(window.contentView?.hitTest(sidebar.convert(CGPoint(x: local.midX, y: local.midY), to: nil)))
    hit.mouseDown(with: try dragEvent(.leftMouseDown, sidebar: sidebar, position: position))
    hit.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: CGPoint(x: position.x + 4, y: position.y)))
    let moved = try #require(sidebar.dragCopyView)
    moved.layoutSubtreeIfNeeded()
    let movedSegments = dragDescendants(moved).compactMap { $0 as? SplitSegmentButton }
    #expect(movedSegments.map(\.pane.id) == ["b", "c"])
    #expect(movedSegments.map(\.active) == [true, false])
    sidebar.cancelOperation(nil)
}

@Test @MainActor
func splitMenuFollowsTheAxisAndThePanePosition() throws {
    let split = dragRow("split", "ts", kind: .split)
    let first = dragRow("first", "split", depth: 1)
    let second = dragRow("second", "split", depth: 1)
    let (window, sidebar) = dragWindow(dragSpace(today: [split, first, second]))
    defer { window.contentView = nil }
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "split" })
    let buttons = dragDescendants(row).compactMap { $0 as? SplitSegmentButton }.filter { $0.paneTitle == "first" || $0.paneTitle == "second" }
        .sorted { $0.frame.minX < $1.frame.minX }
    #expect(buttons.count == 2)
    let right = try #require(buttons.first)
    func titles(_ menu: NSMenu?) -> [String] { menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }
    // Side by side: Move Left/Right, and the first pane cannot move left.
    #expect(titles(row.menu(for: eventOver(right, in: window))) ==
            ["Move Left", "Move Right", "Add Right Split", "Add Left Split", "Separate Tab from Split",
             "Convert to Vertical Split View", "Close Pane"])
    #expect(row.menu(for: eventOver(right, in: window))?.items[0].isEnabled == false)
    // The last pane cannot move right.
    let last = try #require(buttons.last)
    #expect(row.menu(for: eventOver(last, in: window))?.items[1].isEnabled == false)
    // Stacked: the words and the Convert title follow the axis.
    sidebar.splitIsVertical = { _ in true }
    #expect(titles(row.menu(for: eventOver(right, in: window))) ==
            ["Move Up", "Move Down", "Add Right Split", "Add Left Split", "Separate Tab from Split",
             "Convert to Horizontal Split View", "Close Pane"])
}

private func eventOver(_ view: NSView, in window: NSWindow) -> NSEvent {
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    return NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}

@Test @MainActor
func splitSegmentForwardsContextAndMiddleClick() throws {
    let split = dragRow("split", "ts", kind: .split)
    let member = dragRow("member", "split", depth: 1)
    let (window, sidebar) = dragWindow(dragSpace(today: [split, member]))
    defer { window.contentView = nil }
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "split" })
    let button = try #require(dragDescendants(row).compactMap { $0 as? SplitSegmentButton }.first { $0.paneTitle == "member" })
    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    let hit = try #require(window.contentView?.hitTest(point))
    let right = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    // U25d: a segment carries the split commands for the pane it was right-clicked on.
    let menu = try #require(hit.menu(for: right))
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) ==
            ["Move Left", "Move Right", "Add Right Split", "Add Left Split", "Separate Tab from Split",
             "Convert to Vertical Split View", "Close Pane"])
    var closed: String?
    sidebar.onClose = { closed = $0 }
    let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: point, mouseButton: .center))
    let middle = try #require(NSEvent(cgEvent: cg))
    hit.otherMouseUp(with: middle)
    #expect(closed == "split")
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

@MainActor
private func dropPinBeforeSelection(staleSelection: String? = nil) throws -> (SidebarView, WorkspaceSnapshot) {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: staleSelection, spaces: [dragFixture(), dragSpace("other")]))
    sidebar.frame = CGRect(x: 0, y: 0, width: 240, height: 700)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    sidebar.dragReduceMotion = { true }
    sidebar.renameHintClock = { 100 }
    let row = try startDrag(sidebar, id: "a")
    let geometry = try #require(sidebar.dragGeometry())
    let dropped = WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: staleSelection,
        spaces: [dragSpace(pinned: [dragRow("a", "ps")], today: [dragRow("b", "ts"), dragRow("c", "ts", 1)]), dragSpace("other")])
    sidebar.onMove = { _, _, _, _, done in done(dropped) }
    let point = CGPoint(x: 30, y: geometry.rows[0].frame.minY)
    row.mouseDragged(with: try dragEvent(.leftMouseDragged, sidebar: sidebar, position: point))
    row.mouseUp(with: try dragEvent(.leftMouseUp, sidebar: sidebar, position: point))
    #expect(sidebar.selectedRowID == staleSelection)
    #expect(!sidebar.organizeCheckHint(id: "a"))
    #expect(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "a" }?.pinned == true)
    return (sidebar, dropped)
}

@Test(arguments: ["move", "moveIfLive", "collapse", "edit"]) @MainActor
func editRepliesKeepSelectionPublishedBeforeDelivery(route: String) async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                          windowID: "organize", card: NSView(), seedOrganize: true, session: session)
    let initial = try session.queue.sync {
        _ = try session.store!.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine, strips: []))
        return session.store!.snapshot(windowId: "organize")
    }
    let space = try #require(initial.spaces.first { $0.id == "organize-work" })
    let id = try #require(space.today.first?.id)
    #expect(initial.selectedId == nil)
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: initial)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.dragReduceMotion = { true }
    sidebar.renameHintClock = { 100 }
    let adapter = WorkspaceAdapter(windowID: "organize", session: session)
    let actions = SidebarActions()
    let replies = AsyncStream<WorkspaceSnapshot>.makeStream()
    defer { replies.continuation.finish() }
    var recorded: [String?] = []
    var shown: [String?] = []
    actions.configureEditing(adapter: adapter, isActive: { true }, window: { window }, show: { snapshot in
        shown.append(snapshot.selectedId)
        sidebar.update(snapshot: snapshot)
        if route == "move" || route == "moveIfLive" { replies.continuation.yield(snapshot) }
    }, record: { recorded.append($0.selectedId) })
    actions.bind(to: sidebar)
    let receive: (WorkspaceSnapshot?) -> Void = { snapshot in
        if let snapshot {
            sidebar.update(snapshot: snapshot)
            replies.continuation.yield(snapshot)
        } else { Issue.record("edit unexpectedly failed"); replies.continuation.finish() }
    }
    switch route {
    case "moveIfLive":
        let live = try session.queue.sync { try session.store!.liveOpen(item: id, url: "about:blank") }
        sidebar.onMove = { item, container, index, openFolder, completion in
            adapter.moveIfLive(id: item, container: container, index: index, openFolder: openFolder, expectedLive: live.id) { result in
                guard case .success(let snapshot?) = result else { Issue.record("live move unexpectedly failed"); replies.continuation.finish(); return }
                recorded.append(snapshot.selectedId)
                completion(snapshot)
                shown.append(snapshot.selectedId)
                sidebar.update(snapshot: snapshot)
                replies.continuation.yield(snapshot)
            }
        }
        #expect(sidebar.organizeCheckBegin(id: id, destination: "organize-outer"))
        #expect(sidebar.organizeCheckEnd())
    case "move":
        #expect(sidebar.organizeCheckBegin(id: id, destination: "organize-outer"))
        #expect(sidebar.organizeCheckEnd())
    case "collapse": actions.onItemEdit?(.collapse(id: "organize-inner", collapsed: false), receive)
    default: actions.onItemEdit?(.rename(id: id, title: "Renamed", folder: false), receive)
    }
    let selected = try session.queue.sync {
        #expect(session.store!.snapshot(windowId: "organize").selectedId == nil)
        return try session.store!.selectItem(windowId: "organize", id: id)
    }
    #expect(recorded.isEmpty)
    sidebar.applySelection(snapshot: selected)
    #expect(sidebar.selectedRowID == id)
    var iterator = replies.stream.makeAsyncIterator()
    let delivered = try #require(await iterator.next())
    #expect(delivered == selected)
    #expect(recorded == [id])
    #expect(shown == [id])
    #expect(sidebar.selectedRowID == id)
    if route == "move" || route == "moveIfLive" {
        #expect(sidebar.organizeCheckHint(id: id))
        #expect(delivered.spaces.first { $0.id == space.id }?.pinned.contains { $0.id == id } == true)
    }
}

@Test(arguments: [false, true]) @MainActor
func pinHintWaitsForTheSelectionSnapshot(replace: Bool) throws {
    let (sidebar, dropped) = try dropPinBeforeSelection()
    var selected = dropped
    selected.selectedId = "a"
    if replace { sidebar.update(snapshot: selected) }
    else { sidebar.applySelection(snapshot: selected) }
    #expect(sidebar.organizeCheckHint(id: "a"))
    let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "a" })
    sidebar.renameHintClock = { 104 }
    row.refreshRenameHint()
    #expect(!sidebar.organizeCheckHint(id: "a"))
    sidebar.update(snapshot: selected)
    #expect(!sidebar.organizeCheckHint(id: "a"))
}

@Test(arguments: [false, true]) @MainActor
func pinHintWaitsPastAStaleNonNilSelection(replace: Bool) throws {
    let (sidebar, dropped) = try dropPinBeforeSelection(staleSelection: "b")
    sidebar.update(snapshot: dropped)
    #expect(!sidebar.organizeCheckHint(id: "a"))
    var selected = dropped
    selected.selectedId = "a"
    if replace { sidebar.update(snapshot: selected) }
    else { sidebar.applySelection(snapshot: selected) }
    #expect(sidebar.organizeCheckHint(id: "a"))
}

@Test(arguments: [nil, "b"] as [String?]) @MainActor
func pinHintIsDiscardedWhenAnotherRowIsSelectedFirst(staleSelection: String?) throws {
    let (sidebar, dropped) = try dropPinBeforeSelection(staleSelection: staleSelection)
    var selected = dropped
    selected.selectedId = staleSelection == nil ? "b" : "c"
    sidebar.applySelection(snapshot: selected)
    #expect(!sidebar.organizeCheckHint(id: "a"))
    selected.selectedId = "a"
    sidebar.applySelection(snapshot: selected)
    #expect(!sidebar.organizeCheckHint(id: "a"))
}

@Test(arguments: [false, true]) @MainActor
func pendingPinHintIsClearedBySpaceChangeOrRename(rename: Bool) throws {
    let (sidebar, dropped) = try dropPinBeforeSelection()
    if rename {
        sidebar.beginRename(id: "a")
        let row = try #require(dragDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "a" })
        row.finishRename(commit: false)
    } else {
        sidebar.showSpace(at: 1)
        sidebar.showSpace(at: 0)
    }
    var selected = dropped
    selected.selectedId = "a"
    sidebar.applySelection(snapshot: selected)
    #expect(!sidebar.organizeCheckHint(id: "a"))
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
    // T2: with Today empty, the space below the last pinned row is Today at index 0 — the
    // old 20 pt pinned zone and the divider gap's level choices are gone.
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 360), geometry: emptyToday, dragged: dragged) == .insert(container: "ts", index: 0, lineY: 344, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 60, y: 360), geometry: emptyToday, dragged: dragged) == .insert(container: "ts", index: 0, lineY: 344, depth: 0))
    #expect(resolveSidebarDrop(position: CGPoint(x: 20, y: 390), geometry: emptyToday, dragged: dragged) == .insert(container: "ts", index: 0, lineY: 344, depth: 0))
}

@Test
func anEmptyFoldersNoTabsLineAcceptsTheDrop() throws {
    let dragged = dragRow("a", "ts")
    let space = dragSpace(pinned: [dragRow("folder", "ps", kind: .folder),
                                   dragRow("folder/no-tabs", "folder", kind: .noTabs, depth: 1)],
                          today: [dragged])
    let g = SidebarDragGeometry(bounds: CGRect(x: 0, y: 0, width: 240, height: 700), list: CGRect(x: 8, y: 180, width: 224, height: 450),
        pinnedArea: CGRect(x: 8, y: 149, width: 224, height: 31), favorites: CGRect(x: 8, y: 90, width: 224, height: 47),
        rows: [ .init(row: space.pinned[0], frame: CGRect(x: 8, y: 180, width: 224, height: 41)),
                .init(row: space.pinned[1], frame: CGRect(x: 8, y: 221, width: 224, height: 24)),
                .init(row: space.today[0], frame: CGRect(x: 8, y: 300, width: 224, height: 41)) ],
        dock: [], space: space)
    // F3: the empty folder’s 24 pt line is a drop target for that folder.
    #expect(resolveSidebarDrop(position: CGPoint(x: 30, y: 233), geometry: g, dragged: dragged) == .folder("folder"))
    // The gap below a trailing marker ends that folder: index 0, not 1 (review 3a).
    #expect(resolveSidebarDrop(position: CGPoint(x: 60, y: 255), geometry: g, dragged: dragged)
        == .insert(container: "folder", index: 0, lineY: 245, depth: 1))
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
