import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func reuseDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + reuseDescendants($0) }
}

private func reuseSnapshot(pinned: [Row], today: [Row] = [], favorites: [Row] = []) -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil,
                                            favorites: favorites, pinned: pinned, today: today)])
}

@MainActor
private func laidOutSidebar(_ snapshot: WorkspaceSnapshot, width: CGFloat = 240) -> SidebarView {
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    return sidebar
}

@Test @MainActor
func survivingRowsAndFavoritesKeepTheirInstancesAndRowFocus() throws {
    _ = NSApplication.shared
    let a = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "a", title: "Alpha", url: "https://a.example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let b = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "b", title: "Beta", url: nil, depth: 0, kind: .folder, unloaded: false, lastSelectedAt: nil)
    let favorite = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "f", title: "Favorite", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let other = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "g", title: "Other", url: nil, depth: 0, kind: .folder, unloaded: false, lastSelectedAt: nil)
    let added = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "h", title: "Added", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let sidebar = laidOutSidebar(reuseSnapshot(pinned: [a, b], favorites: [favorite, other]), width: 164)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    let focused = try #require(reuseDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "a" })
    let removed = try #require(reuseDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "b" })
    let tile = try #require(reuseDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first)
    #expect(window.makeFirstResponder(focused))
    #expect(sidebar.selectRow(id: "b"))
    #expect(window.firstResponder === focused)
    var renamed = a
    renamed.title = "Renamed"
    renamed.depth = 2
    sidebar.update(snapshot: reuseSnapshot(pinned: [b], today: [renamed], favorites: [other, added, favorite]))
    sidebar.layoutSubtreeIfNeeded()
    let surviving = try #require(reuseDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "a" })
    #expect(surviving === focused)
    #expect(window.firstResponder === focused)
    #expect(surviving.row == renamed)
    #expect(reuseDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first { $0.row.id == "f" } === tile)
    sidebar.frame.size.width = 500
    sidebar.layoutSubtreeIfNeeded()
    #expect(reuseDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first { $0.row.id == "f" } === tile)
    #expect(window.firstResponder === focused)
    sidebar.update(snapshot: reuseSnapshot(pinned: [renamed], favorites: [favorite]))
    #expect(removed.superview == nil)
    #expect(sidebar.selectedRowID == nil)
    #expect(window.firstResponder === focused)
}

@MainActor
struct ReuseTree: Equatable {
    let type: String
    let frame: NSRect
    let row: Row?
    let text: String?
    let tooltip: String?
    let image: Data?
    let fill: [CGFloat]?
    let accessibilityLabel: String?
    let accessibilityRole: NSAccessibility.Role?
    let acceptsKeyboardFocus: Bool?
    let refusesFirstResponder: Bool?
    let children: [ReuseTree]

    init(_ view: NSView, in sidebar: SidebarView) {
        type = String(describing: Swift.type(of: view))
        frame = sidebar.convert(view.bounds, from: view)
        row = (view as? SidebarRowView)?.row ?? (view as? FavoriteTile)?.row
        text = (view as? NSTextField)?.stringValue
        tooltip = view.toolTip
        image = ((view as? NSImageView)?.image ?? (view as? NSButton)?.image)?.tiffRepresentation
        fill = view.layer?.backgroundColor?.components
        accessibilityLabel = view.accessibilityLabel()
        accessibilityRole = view.accessibilityRole()
        acceptsKeyboardFocus = (view as? SidebarRowView)?.acceptsKeyboardFocus
        refusesFirstResponder = (view as? NSControl)?.refusesFirstResponder
        let views = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
        children = views.map { ReuseTree($0, in: sidebar) }
    }
}

@Test @MainActor
func incrementalRowsMatchFreshSnapshotTrees() {
    let a = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "a", title: "Alpha", url: "https://a.example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let b = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "b", title: "Beta", url: nil, depth: 0, kind: .folder, unloaded: false, lastSelectedAt: nil)
    let c = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "c", title: "Gamma", url: nil, depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let f = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "f", title: "Favorite", url: "https://f.example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let g = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "g", title: "Other favorite", url: nil, depth: 0, kind: .folder, unloaded: false, lastSelectedAt: nil)
    let initial = reuseSnapshot(pinned: [a, b], today: [c], favorites: [f, g])
    var renamed = a
    renamed.title = "Renamed on two\nlines"
    renamed.url = "https://renamed.example"
    var indented = b
    indented.depth = 2
    var split = a
    split.title = ""
    split.kind = .split
    var favorite = f
    favorite.title = "Renamed favorite"
    favorite.kind = .split
    let changes = [
        reuseSnapshot(pinned: [a, b, Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "new", title: "New", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)], today: [c], favorites: [f, g]),
        reuseSnapshot(pinned: [a], today: [c], favorites: [f, g]),
        reuseSnapshot(pinned: [b, a], today: [c], favorites: [f, g]),
        reuseSnapshot(pinned: [renamed, b], today: [c], favorites: [f, g]),
        reuseSnapshot(pinned: [a, indented], today: [c], favorites: [f, g]),
        reuseSnapshot(pinned: [split, b], today: [c], favorites: [f, g]),
        reuseSnapshot(pinned: [b], today: [a, c], favorites: [g, Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "h", title: "Added", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil), favorite]),
        reuseSnapshot(pinned: [a, b], favorites: [g]),
        reuseSnapshot(pinned: [], favorites: []),
        WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []),
    ]
    for width: CGFloat in [164, 240, 500] {
        for snapshot in changes {
            for selected in ["a", "b"] {
                let reused = laidOutSidebar(initial, width: width)
                #expect(reused.selectRow(id: "a"))
                reused.update(snapshot: snapshot)
                _ = reused.selectRow(id: selected)
                reused.layoutSubtreeIfNeeded()
                reused.layoutSubtreeIfNeeded()
                let fresh = laidOutSidebar(snapshot, width: width)
                _ = fresh.selectRow(id: selected)
                fresh.layoutSubtreeIfNeeded()
                fresh.layoutSubtreeIfNeeded()
                #expect(ReuseTree(reused, in: reused) == ReuseTree(fresh, in: fresh))
            }
        }
    }
}

@Test @MainActor
func reusedRowAndFavoriteActionsDeliverTheUpdatedModels() throws {
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "a", title: "Old", url: "https://old.example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let favorite = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "f", title: "Old favorite", url: "https://old-favorite.example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let sidebar = laidOutSidebar(reuseSnapshot(pinned: [row], favorites: [favorite]))
    var renamed = row
    renamed.title = "New"
    renamed.url = "https://new.example"
    renamed.kind = .split
    var updatedFavorite = favorite
    updatedFavorite.title = "New favorite"
    updatedFavorite.url = "https://new-favorite.example"
    sidebar.update(snapshot: reuseSnapshot(pinned: [renamed], favorites: [updatedFavorite]))
    var selected: [Row] = []
    sidebar.onSelect = { selected.append($0) }
    let view = try #require(reuseDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first)
    #expect(view.accessibilityPerformPress())
    let tile = try #require(reuseDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first)
    tile.performClick(nil)
    #expect(selected == [renamed, updatedFavorite])
}
