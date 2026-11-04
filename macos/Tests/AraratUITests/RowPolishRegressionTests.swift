import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func middleClickClosesTodayThroughTheSharedClosePath() throws {
    _ = NSApplication.shared
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "today", title: "Today", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: nil, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [row])])
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 500)
    sidebar.layoutSubtreeIfNeeded()
    func rows(_ view: NSView) -> [SidebarRowView] {
        view.subviews.flatMap { ($0 as? SidebarRowView).map { [$0] } ?? rows($0) }
    }
    let view = try #require(rows(sidebar).first)
    var closed: String?
    sidebar.onClose = { closed = $0 }
    let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
    let event = try #require(NSEvent(cgEvent: cgEvent))
    view.otherMouseUp(with: event)
    #expect(closed == "today")
}

@Test @MainActor
func pinnedRowsExposeAnAccessibleHoverAction() throws {
    _ = NSApplication.shared
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "pin", title: "Pinned", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let view = SidebarRowView(row: row, selected: true) { _ in }
    view.frame = NSRect(x: 0, y: 0, width: 220, height: 41)
    view.pointerLocation = { NSPoint(x: 20, y: 20) }
    view.refreshHover()
    let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
    #expect(!button.isHidden)
    #expect(button.accessibilityLabel() != nil)
}
