import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func renameRows(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(renameRows) }

private func renameRow(_ id: String, _ parent: String, _ index: UInt32 = 0, kind: RowKind = .tab, depth: UInt32 = 0) -> Row {
    Row(folderHasTabs: false, parentId: parent, siblingIndex: index, collapsed: false, id: id,
        title: id, url: kind == .tab ? "https://\(id).example" : nil,
        depth: depth, kind: kind, unloaded: false, lastSelectedAt: nil)
}

private func renameSpace() -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 1, todayCount: 1, profileKey: "default", pinnedId: "ps", todayId: "ts", favoritesId: "fdefault", archiveAfter: .hours12,
                  profileName: "default", profile: .named("default"), id: "s", title: "s", icon: nil, look: nil,
                  favorites: [renameRow("fav", "fdefault")], pinned: [renameRow("pin", "ps")], today: [renameRow("a", "ts")])
}

@MainActor
private func renameWindow() -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: "a", spaces: [renameSpace()]))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 500), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
}

@Test @MainActor
func renameHidesTheRowTitleAndMutesItsTooltipUntilItEnds() throws {
    let (window, sidebar) = renameWindow()
    defer { window.contentView = nil }
    let row = try #require(renameRows(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "pin" })
    let label = try #require(renameRows(row).compactMap { $0 as? NSTextField }.first { !$0.isEditable && $0.stringValue == row.row.title })
    let other = try #require(renameRows(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "a" })
    var now = 0.0
    sidebar.tooltip.clock = { now }
    sidebar.tooltip.update(target: row, point: NSPoint(x: 20, y: 60))
    now = 1.6
    sidebar.tooltip.update(target: row, point: NSPoint(x: 20, y: 60))
    #expect(sidebar.tooltip.text == "https://pin.example")
    #expect(!label.isHidden)
    #expect(sidebar.tooltipTarget(for: row) === row)
    sidebar.beginRename(id: "pin")
    #expect(sidebar.renamingID == "pin" && row.renameField != nil)
    #expect(sidebar.tooltip.text == nil)
    #expect(label.isHidden)
    #expect(sidebar.tooltipTarget(for: row) == nil)
    // The field is the subview a real hover lands on.
    let field = try #require(row.renameField)
    #expect(sidebar.tooltipTarget(for: field) == nil)
    sidebar.tooltip.update(target: sidebar.tooltipTarget(for: row), point: NSPoint(x: 20, y: 60))
    now = 10
    sidebar.tooltip.update(target: sidebar.tooltipTarget(for: row), point: NSPoint(x: 20, y: 60))
    #expect(sidebar.tooltip.text == nil)
    // Another row keeps its tooltip while this one is renaming.
    #expect(sidebar.tooltipTarget(for: other) === other)
    // An unchanged commit returns both.
    row.finishRename(commit: true)
    #expect(row.renameField == nil && sidebar.renamingID == nil && !label.isHidden)
    #expect(sidebar.tooltipTarget(for: row) === row)
    // And a cancel after a raised tooltip does too.
    sidebar.tooltip.update(target: row, point: NSPoint(x: 20, y: 60))
    now = 20
    sidebar.tooltip.update(target: row, point: NSPoint(x: 20, y: 60))
    #expect(sidebar.tooltip.text == "https://pin.example")
    sidebar.beginRename(id: "pin")
    #expect(sidebar.tooltip.text == nil && label.isHidden)
    row.finishRename(commit: false)
    #expect(!label.isHidden && sidebar.renamingID == nil)
    #expect(sidebar.tooltipTarget(for: row) === row)
}

@Test @MainActor
func aRenamingFavoriteTileMutesItsTooltip() throws {
    let (window, sidebar) = renameWindow()
    defer { window.contentView = nil }
    let tile = try #require(renameRows(sidebar).compactMap { $0 as? FavoriteTile }.first)
    var now = 0.0
    sidebar.tooltip.clock = { now }
    sidebar.tooltip.update(target: tile, point: NSPoint(x: 20, y: 110))
    now = 1.6
    sidebar.tooltip.update(target: tile, point: NSPoint(x: 20, y: 110))
    #expect(sidebar.tooltip.text == "fav")
    sidebar.beginRename(id: "fav")
    #expect(sidebar.renamingID == "fav" && tile.renameField != nil)
    #expect(sidebar.tooltip.text == nil)
    #expect(sidebar.tooltipTarget(for: tile) == nil)
    tile.renameField?.finish(commit: true)
    #expect(tile.renameField == nil && sidebar.renamingID == nil)
    #expect(sidebar.tooltipTarget(for: tile) === tile)
    sidebar.tooltip.update(target: tile, point: NSPoint(x: 20, y: 110))
    now = 20
    sidebar.tooltip.update(target: tile, point: NSPoint(x: 20, y: 110))
    #expect(sidebar.tooltip.text == "fav")
}
