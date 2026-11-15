import AppKit
import AraratKit
import Testing
@testable import AraratUI

private func dragRow(_ id: String) -> Row {
    Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: id, title: "Tab \(id)",
        url: "https://example.com/\(id)", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
}

private func dragSnapshot() -> WorkspaceSnapshot {
    let spaces = ["work", "home", "read"].enumerated().map { index, id in
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "",
                      favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .default,
                      id: id, title: id.capitalized, icon: nil, look: nil, favorites: [], pinned: [],
                      today: index == 0 ? [dragRow("a"), dragRow("b")] : [])
    }
    return WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: "a", spaces: spaces)
}

@MainActor
private func dragWindow() -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [],
                          backing: .buffered, defer: false)
    let sidebar = SidebarView(snapshot: dragSnapshot())
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return (window, sidebar)
}

/// The four owners of a drag area (P4): the container for the card's frame, the sidebar and the
/// header for their empty gaps, the list for the space below its last row.
@Test @MainActor
func sidebarEmptyAreasBelongToTheWindowDragAndRowsDoNot() throws {
    let (window, sidebar) = dragWindow()
    defer { window.contentView = nil }
    let points = sidebar.checkDragAreaPoints()
    func hit(_ point: NSPoint) -> NSView? {
        let inSuperview = sidebar.superview.map { $0.convert(point, from: nil) } ?? point
        return sidebar.hitTest(inSuperview)
    }
    let belowRows = try #require(points["below_rows"])
    #expect(hit(belowRows) is SidebarScrollView)
    let dockGap = try #require(points["dock_gap"])
    #expect(hit(dockGap) === sidebar)
    let columnGap = try #require(points["column_gap"])
    #expect(hit(columnGap) === sidebar)
    // Controls and rows keep their own hits.
    let row = try #require(sidebar.checkRowPoint())
    #expect(!sidebar.isWindowDragArea(try #require(hit(row))))
    let cell = try #require(sidebar.checkDockCellPoint())
    #expect(hit(cell) is SpaceDockButton)
    #expect(!sidebar.isWindowDragArea(try #require(hit(cell))))
    let field = sidebar.urlFieldCheckFrame
    #expect(!sidebar.isWindowDragArea(try #require(hit(NSPoint(x: field.midX, y: field.midY)))))
}

/// A window point in the card's margins is the container's own area; its press moves the window.
@Test @MainActor
func cardMarginsAreTheContainersDragArea() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [],
                          backing: .buffered, defer: false)
    let sidebar = SidebarView(snapshot: dragSnapshot())
    let page = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: page)
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    defer { window.contentView = nil }
    #expect(container.checkPressTarget(at: container.checkAboveCardPoint()) == "frame")
    #expect(container.checkPressTarget(at: container.checkHeaderGapPoint()) == "header")
    let right = NSPoint(x: window.frame.width - 4, y: window.frame.height / 2)
    #expect(container.checkPressTarget(at: right) == "frame")
    // The page and the sidebar keep their hits.
    let pagePoint = page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
    #expect(container.checkPressTarget(at: pagePoint) == "NSView")
}

@Test
func fullScreenWindowsRefuseTheDrag() {
    #expect(WindowDrag.allowsDrag(styleMask: [.titled, .resizable]))
    #expect(WindowDrag.allowsDrag(styleMask: [.borderless]))
    #expect(!WindowDrag.allowsDrag(styleMask: [.titled, .fullScreen]))
}

@Test
func doubleClickFollowsTheTitleBarSetting() throws {
    let suite = "ararat.window-drag.tests"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("Maximize", forKey: "AppleActionOnDoubleClick")
    #expect(WindowDoubleClickAction.fromDefaults(defaults) == .zoom)
    defaults.set("Minimize", forKey: "AppleActionOnDoubleClick")
    #expect(WindowDoubleClickAction.fromDefaults(defaults) == .minimize)
    defaults.set("None", forKey: "AppleActionOnDoubleClick")
    #expect(WindowDoubleClickAction.fromDefaults(defaults) == .nothing)
    // A Mac that never changed the setting has no key: the system's default is zoom.
    defaults.removeObject(forKey: "AppleActionOnDoubleClick")
    #expect(WindowDoubleClickAction.fromDefaults(defaults) == .zoom)
}
