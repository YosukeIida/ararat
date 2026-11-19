import AppKit
import AraratKit
import Testing
@testable import AraratUI

private func hoverSnapshot(_ ids: [String]) -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil,
        favorites: [], pinned: [], today: ids.map { Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: $0, title: $0, url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) })])
}

@MainActor
private func hoverRows(_ view: NSView) -> [SidebarRowView] {
    view.subviews.flatMap { ($0 as? SidebarRowView).map { [$0] } ?? hoverRows($0) }
}

@MainActor
private func hoverWindow(_ ids: [String]) -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: hoverSnapshot(ids))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
}

@Test @MainActor
func reusedHoverMatchesAFreshLayoutAfterReorder() throws {
    let (window, sidebar) = hoverWindow(["a", "b", "c"])
    defer { window.contentView = nil }
    let original = try #require(hoverRows(sidebar).first { $0.row.id == "a" })
    let point = original.convert(NSPoint(x: 20, y: 20), to: nil)
    for row in hoverRows(sidebar) { row.pointerLocation = { point }; row.refreshHover() }
    #expect(original.hovered)
    #expect(abs(try #require(original.subviews[0].layer?.backgroundColor?.alpha) - SidebarMetrics.rowHoverFillAlpha(for: original.effectiveAppearance)) < 0.000001)
    sidebar.update(snapshot: hoverSnapshot(["b", "c", "a"]))
    sidebar.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    #expect(hoverRows(sidebar).first { $0.row.id == "a" } === original)
    #expect(!original.hovered)
    #expect(original.subviews[0].layer?.backgroundColor?.alpha == 0)
    let (freshWindow, fresh) = hoverWindow(["b", "c", "a"])
    defer { freshWindow.contentView = nil }
    for row in hoverRows(fresh) { row.pointerLocation = { point }; row.refreshHover() }
    let reusedState = Dictionary(uniqueKeysWithValues: hoverRows(sidebar).map { ($0.row.id, $0.hovered) })
    let freshState = Dictionary(uniqueKeysWithValues: hoverRows(fresh).map { ($0.row.id, $0.hovered) })
    #expect(reusedState == freshState)
    #expect(!window.isVisible && !window.isKeyWindow)
}

@Test @MainActor
func closingARowRechecksHoverForTheRowsThatMoveUp() throws {
    let (window, sidebar) = hoverWindow(["a", "b", "c"])
    defer { window.contentView = nil }
    let moving = try #require(hoverRows(sidebar).first { $0.row.id == "c" })
    let point = moving.convert(NSPoint(x: 20, y: 20), to: nil)
    for row in hoverRows(sidebar) { row.pointerLocation = { point }; row.refreshHover() }
    #expect(moving.hovered)
    #expect(abs(try #require(moving.subviews[0].layer?.backgroundColor?.alpha) - SidebarMetrics.rowHoverFillAlpha(for: moving.effectiveAppearance)) < 0.000001)
    sidebar.applyClose(id: "b", snapshot: hoverSnapshot(["a", "c"]))
    window.displayIfNeeded()
    #expect(hoverRows(sidebar).first { $0.row.id == "c" } === moving)
    #expect(moving.layer?.animation(forKey: "row.close.move") != nil)
    #expect(!moving.hovered)
    #expect(moving.subviews[0].layer?.backgroundColor?.alpha == 0)
    #expect(!window.isVisible && !window.isKeyWindow)
}
