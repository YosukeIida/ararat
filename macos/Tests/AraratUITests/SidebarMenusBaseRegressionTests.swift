import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func sidebarMenuControlsExistAtPublicInteractionPoints() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore.open(path: directory.appendingPathComponent("base.sqlite").path)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    _ = try store.importArcSidebar(windowId: "regression", json: String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8), windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil).snapshot
    _ = try store.moveItem(windowId: "regression", id: "tab-a", container: "today-work", index: 0, openFolder: false)
    let snapshot = try store.createTab(windowId: "regression", url: "https://today.example")
    let today = try #require(snapshot.selectedId)
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
    sidebar.layoutSubtreeIfNeeded()
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    let rows = views(sidebar).compactMap { $0 as? SidebarRowView }
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    #expect(sidebar.newSpaceMenu.items.map(\.title) == ["New Space", "New Folder"])
    for (id, titles) in [("folder-docs", ["New Nested Folder…", "Rename…", "Duplicate", "Move to", "Delete"]), ("tab-spec", ["Copy Link", "Rename…", "Duplicate", "Move to", "Close Tab", "Remove Pin"]), (today, ["Copy Link", "Rename…", "Duplicate", "Move to", "Archive Tab"])] {
        let row = try #require(rows.first { $0.row.id == id })
        #expect(row.menu(for: event)?.items.map(\.title) == titles)
    }
    #expect(rows.contains { $0.row.id == "split-1" })
    #expect(rows.first { $0.row.id == "split-1" }?.menu(for: event) == nil)
    #expect(!rows.contains { $0.row.id == "tab-a" })
    let favorite = try #require(views(sidebar).compactMap { $0 as? FavoriteTile }.first)
    #expect(favorite.menu(for: event)?.items.map(\.title) == ["Copy Link", "Rename…", "Move to", "Close Tab", "Remove Favorite"])
    let folder = try #require(rows.first { $0.row.id == "folder-docs" })
    #expect(folder.accessibilityCustomActions()?.map(\.name) == ["Collapse"])
    sidebar.updateSelection(id: "tab-spec")
    let pin = try #require(rows.first { $0.row.id == "tab-spec" })
    #expect(!views(pin).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Double-click to rename" && !$0.isHidden })
    let doubleClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
    pin.mouseDown(with: doubleClick)
    #expect(views(pin).compactMap { $0 as? NSTextField }.contains { $0.accessibilityLabel() == "Rename" })
    var selected: [String] = []
    sidebar.onSelect = { selected.append($0.id) }
    #expect(folder.accessibilityPerformPress())
    #expect(selected.isEmpty && sidebar.selectedRowID == "tab-spec")

}
