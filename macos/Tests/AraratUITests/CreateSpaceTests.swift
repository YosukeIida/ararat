import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func creationDescendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + creationDescendants($0) } }

@MainActor
private func creationSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: "space-1", selectedId: nil, spaces: (0..<3).map {
        SpaceSnapshot(profileName: "Research", id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: [])
    })
}

@Test @MainActor
func newSpaceMenuCancelEscapeAndReturnUseTheCreationPage() throws {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: creationSnapshot())
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.newSpaceMenu.items.map(\.title) == ["New Space"])
    sidebar.setLibraryOpen(true)
    let menuItem = try #require(sidebar.newSpaceMenu.items.first)
    #expect(NSApp.sendAction(try #require(menuItem.action), to: menuItem.target, from: menuItem))
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.createSpaceOpen && !sidebar.libraryOpen && sidebar.spaceShown == 1)
    #expect(sidebar.frame.width == container.resizeHandle.sidebarWidth)
    var page = try #require(creationDescendants(sidebar).compactMap { $0 as? CreateSpaceView }.first)
    let cancel = try #require(creationDescendants(page).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Cancel space creation" })
    cancel.performClick(nil)
    #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 1)
    sidebar.showCreateSpace()
    sidebar.cancelOperation(nil)
    #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 1)
    sidebar.showCreateSpace()
    container.layoutSubtreeIfNeeded()
    page = try #require(creationDescendants(sidebar).compactMap { $0 as? CreateSpaceView }.first)
    let field = try #require(creationDescendants(page).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Space name" })
    let create = try #require(creationDescendants(page).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Create Space" })
    let profile = try #require(creationDescendants(page).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Current profile: Research" })
    #expect(!profile.isEditable && profile.stringValue == "Research")
    #expect(field.frame.height == 36 && create.frame.height == 36)
    #expect(abs(page.convert(field.bounds, from: field).minX - 14) < 0.1)
    let card = try #require(profile.superview?.superview)
    #expect(card.frame.height == 59)
    #expect(abs(page.convert(card.bounds, from: card).minY - page.convert(field.bounds, from: field).maxY - 6) < 0.1)
    #expect(!create.isEnabled)
    field.stringValue = " \t\n"
    page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(!create.isEnabled)
    field.stringValue = "  Project Notes  "
    page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(create.isEnabled)
    var names: [String] = []
    sidebar.onCreateSpace = { names.append($0) }
    #expect(NSApp.sendAction(try #require(field.action), to: field.target, from: field))
    create.performClick(nil)
    #expect(names == ["Project Notes"])
    #expect(!create.isEnabled)
    sidebar.creationFailed("Try again")
    #expect(create.isEnabled && field.isEditable)
    var created = creationSnapshot()
    created.spaces.append(SpaceSnapshot(profileName: "Research", id: "new", title: "Project Notes", icon: nil, favorites: [], pinned: [], today: []))
    created.shownSpaceId = "new"
    sidebar.applyCreatedSpace(snapshot: created)
    #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 3)
}

@Test @MainActor
func addingSpaceDockButtonsKeepsTheSidebarWidthAndShowsTheSelectedSpace() throws {
    _ = NSApplication.shared
    var snapshot = creationSnapshot()
    snapshot.spaces = (0..<12).map {
        SpaceSnapshot(profileName: "Research", id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: [])
    }
    snapshot.shownSpaceId = "space-11"
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.frame = NSRect(x: 0, y: 0, width: 178, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == 178)
    let selected = try #require(creationDescendants(sidebar).compactMap { $0 as? NSButton }.first { $0.toolTip == "Space 11" })
    let dock = try #require(selected.superview)
    let scroll = try #require(dock.enclosingScrollView)
    #expect(scroll.documentVisibleRect.contains(selected.frame))
    sidebar.showCreateSpace()
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == 178 && sidebar.createSpaceOpen)
}

@Test @MainActor
func trackpadCreationUsesTheAbsoluteLastPageAndWheelRemainsInert() async throws {
    _ = NSApplication.shared
    for floating in [false, true] {
        let sidebar = SidebarView(snapshot: creationSnapshot())
        let container = SidebarContainerView(sidebar: sidebar, page: NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        if floating { container.toggleSidebar() }
        container.layoutSubtreeIfNeeded()
        sidebar.showSpace(at: 2)
        let scroll = try #require(creationDescendants(sidebar).compactMap { $0 as? NSScrollView }.first)
        let send: (Int32, CGScrollPhase?, Double) -> Void = { dx, phase, time in
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            cg.timestamp = UInt64(time * 1_000_000_000)
            scroll.scrollWheel(with: NSEvent(cgEvent: cg)!)
        }
        send(-5, nil, 100)
        #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 2)
        send(-300, .began, 101)
        let preview = try #require(creationDescendants(sidebar).compactMap { $0 as? CreateSpaceView }.first)
        #expect(abs(try #require(preview.layer).transform.m41 - 90) < 0.01)
        #expect(!preview.active && !sidebar.createSpaceOpen)
        send(0, .ended, 101.2)
        #expect(sidebar.createSpaceOpen)
        #expect(preview.layer?.animation(forKey: "space.scroll") is CASpringAnimation)
        try await Task.sleep(for: .milliseconds(800))
        #expect(sidebar.createSpaceOpen && sidebar.frame.width == container.resizeHandle.sidebarWidth)
        send(5, nil, 103)
        #expect(sidebar.createSpaceOpen)
        send(300, .began, 104)
        send(0, .ended, 104.2)
        #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 2)
        sidebar.showCreateSpace()
        sidebar.cancelOperation(nil)
        #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 2)
        #expect(!window.isVisible)
    }
}
