import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func libraryDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + libraryDescendants($0) }
}

@Test @MainActor
func libraryButtonEscapeAndRestorePreserveUserWidthAndLastPage() throws {
    _ = NSApplication.shared
    let entry = Row(id: "closed", title: "A closed tab", url: "https://closed.example", depth: 0, kind: .tab, unloaded: false)
    let space = SpaceSnapshot(id: "home", title: "Home", icon: nil, favorites: [], pinned: [], today: [])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [entry], shownSpaceId: "home", selectedId: nil, spaces: [space]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
    container.resizeHandle.sidebarWidth = 347
    container.layoutSubtreeIfNeeded()
    let button = try #require(libraryDescendants(sidebar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Library" })
    #expect(button.frame.width == 32 && button.frame.height == 32)
    #expect(abs(button.frame.midY - 25) < 0.1)
    button.performClick(nil)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.libraryOpen)
    #expect(sidebar.frame.width == 417)
    #expect(container.resizeHandle.sidebarWidth == 347)
    #expect(sidebar.libraryPage == "Archive")
    sidebar.cancelOperation(nil)
    container.layoutSubtreeIfNeeded()
    #expect(!sidebar.libraryOpen && sidebar.frame.width == 347)
    button.performClick(nil)
    button.performClick(nil)
    #expect(!sidebar.libraryOpen && sidebar.libraryPage == "Archive")
    sidebar.setLibraryOpen(true)
    var restored: String?
    sidebar.onRestore = { id in
        restored = id
        var opened = space
        opened.today = [entry]
        sidebar.applyRestore(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: id, spaces: [opened]))
    }
    let restore = try #require(libraryDescendants(sidebar).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "closed" })
    restore.performClick(nil)
    container.layoutSubtreeIfNeeded()
    #expect(restored == "closed")
    #expect(!sidebar.libraryOpen && sidebar.selectedRowID == "closed")
    #expect(sidebar.frame.width == 347 && container.resizeHandle.sidebarWidth == 347)
}

@Test @MainActor
func libraryIsTheScrollPageBeforeTheFirstSpaceAndStaysOnRelease() {
    var scroll = SpaceScrollState()
    #expect(scroll.handle(.init(dx: 300, phase: .began, time: 0), index: 0, count: 2, pitch: 240) == .follow(150))
    #expect(scroll.handle(.init(dx: 0, phase: .ended, time: 0.2), index: 0, count: 2, pitch: 240) == .settle(index: -1, offset: 150, switched: true))
    #expect(scroll.handle(.init(dx: -300, phase: .began, time: 1), index: -1, count: 2, pitch: 240) == .follow(-150))
    #expect(scroll.handle(.init(dx: 0, phase: .ended, time: 1.2), index: -1, count: 2, pitch: 240) == .settle(index: 0, offset: -150, switched: true))
}

@Test @MainActor
func wheelCannotOpenLibraryAtFirstSpaceOrLeaveLibraryOrPassLastSpace() {
    let spaces = (0..<2).map { SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space-0", selectedId: nil, spaces: spaces))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    let event: (Int32, Double) -> NSEvent = { dx, time in
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        cg.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }
    sidebar.scrollWheel(with: event(5, 100))
    #expect(!sidebar.libraryOpen && sidebar.spaceShown == 0)
    sidebar.setLibraryOpen(false)
    sidebar.showSpace(at: 1)
    sidebar.scrollWheel(with: event(-5, 101))
    #expect(!sidebar.libraryOpen && sidebar.spaceShown == 1)
    sidebar.setLibraryOpen(true)
    sidebar.scrollWheel(with: event(-5, 102))
    #expect(sidebar.libraryOpen && sidebar.spaceShown == 1)
    sidebar.scrollWheel(with: event(5, 103))
    #expect(sidebar.libraryOpen && sidebar.spaceShown == 1)
}

@Test @MainActor
func sidebarScrollOpensLibraryStaysOpenAndScrollsBackToFirstSpace() async throws {
    _ = NSApplication.shared
    let space = SpaceSnapshot(id: "home", title: "Home", icon: nil, favorites: [], pinned: [], today: [])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: nil, spaces: [space]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = container
    defer { window.contentView = nil }
    container.layoutSubtreeIfNeeded()
    let event: (Int32, CGScrollPhase, Double) -> NSEvent = { dx, phase, time in
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }
    sidebar.scrollWheel(with: event(300, .began, 100))
    sidebar.scrollWheel(with: event(0, .ended, 100.2))
    #expect(sidebar.libraryOpen)
    let library = try #require(libraryDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    #expect(library.layer?.animation(forKey: "space.scroll") is CASpringAnimation)
    try await Task.sleep(for: .milliseconds(800))
    #expect(sidebar.libraryOpen)
    sidebar.scrollWheel(with: event(-400, .began, 102))
    sidebar.scrollWheel(with: event(0, .ended, 102.2))
    #expect(!sidebar.libraryOpen && sidebar.spaceShown == 0)
    #expect(container.resizeHandle.sidebarWidth == SidebarMetrics.defaultWidth)
}
