import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func widthFixture() -> (SidebarView, SidebarContainerView) {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
    container.layoutSubtreeIfNeeded()
    return (sidebar, container)
}

@Test @MainActor
func libraryTakesItsOwnWidthWhateverTheUsersSidebarWidth() throws {
    let (sidebar, container) = widthFixture()
    #expect(sidebar.frame.width == SidebarMetrics.defaultWidth)
    sidebar.setLibraryOpen(true)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.libraryWidth)
    #expect(container.resizeHandle.sidebarWidth == SidebarMetrics.defaultWidth)
    #expect(container.savedPresentation.sidebarWidth.map { CGFloat($0) } == SidebarMetrics.defaultWidth)
    // The library keeps its width whatever the user's own width is.
    sidebar.setLibraryOpen(false)
    container.layoutSubtreeIfNeeded()
    container.resizeHandle.sidebarWidth = 164
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == 164)
    sidebar.setLibraryOpen(true)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.libraryWidth)
    #expect(container.resizeHandle.sidebarWidth == 164)
    sidebar.setLibraryOpen(false)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == 164)
}

@Test @MainActor
func narrowWindowClampsTheLibraryListAndKeepsThePageMinimum() throws {
    let (sidebar, container) = widthFixture()
    container.resizeHandle.sidebarWidth = SidebarMetrics.defaultWidth
    sidebar.setLibraryOpen(true)
    container.layoutSubtreeIfNeeded()
    container.frame.size.width = 500
    container.layoutSubtreeIfNeeded()
    // The page card keeps its 240 pt minimum; the Library's list gives up the difference.
    #expect(container.pageCard.frame.width == 240)
    #expect(sidebar.frame.width == 500 - SidebarMetrics.cardInset - 240)
    let library = try #require(libraryDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    #expect(library.frame.width == sidebar.frame.width)
    container.frame.size.width = 1000
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.libraryWidth)
}

@Test @MainActor
func floatingLibraryWidensThePanelInsideTheWindow() throws {
    let (sidebar, container) = widthFixture()
    container.toggleSidebar()
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.defaultWidth)
    sidebar.setLibraryOpen(true)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.libraryWidth)
    sidebar.setLibraryOpen(false)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.defaultWidth)
    // A window narrower than the Library clamps the panel to the floating inset.
    container.frame.size.width = 380
    container.layoutSubtreeIfNeeded()
    sidebar.setLibraryOpen(true)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == 380 - SidebarMetrics.floatingInset * 2)
}

@Test @MainActor
func libraryOpenIgnoresWidthDragsAndAccessibilityChanges() throws {
    let (sidebar, container) = widthFixture()
    let handle = container.resizeHandle
    #expect(handle.accessibilityPerformIncrement())
    #expect(handle.sidebarWidth == SidebarMetrics.defaultWidth + 1)
    handle.sidebarWidth = SidebarMetrics.defaultWidth
    sidebar.setLibraryOpen(true)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.libraryWidth)
    // The Library's edge does not resize the user's sidebar: no accessibility step either.
    #expect(!handle.accessibilityPerformIncrement())
    #expect(!handle.accessibilityPerformDecrement())
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 420, y: 300), modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 620, y: 300), modifierFlags: [], timestamp: 1,
                                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    handle.mouseDown(with: down)
    handle.mouseDragged(with: drag)
    #expect(handle.sidebarWidth == SidebarMetrics.defaultWidth)
    #expect(handle.displayedWidth == SidebarMetrics.libraryWidth)
    #expect(container.savedPresentation.sidebarWidth.map { CGFloat($0) } == SidebarMetrics.defaultWidth)
    sidebar.setLibraryOpen(false)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.frame.width == SidebarMetrics.defaultWidth)
    #expect(handle.sidebarWidth == SidebarMetrics.defaultWidth)
    #expect(container.savedPresentation.sidebarWidth.map { CGFloat($0) } == SidebarMetrics.defaultWidth)
    // Closed, the same handle resizes again.
    handle.mouseDown(with: down)
    handle.mouseDragged(with: drag)
    #expect(handle.sidebarWidth == SidebarMetrics.defaultWidth + 200)
}

@Test @MainActor
func libraryOpenCollapsesOncePerDrag() throws {
    let (sidebar, container) = widthFixture()
    let handle = container.resizeHandle
    var collapses = 0
    let realDrag = handle.onDrag
    handle.onDrag = { x in
        let collapsed = realDrag?(x) ?? false
        if collapsed { collapses += 1 }
        return collapsed
    }
    sidebar.setLibraryOpen(true)
    container.layoutSubtreeIfNeeded()
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 420, y: 300), modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let collapseDrag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 40, y: 300), modifierFlags: [], timestamp: 1,
                                                       windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    handle.mouseDown(with: down)
    // Left of the collapse point, the first event collapses the sidebar; the rest of the drag
    // must not run the collapse again and restart its motion.
    handle.mouseDragged(with: collapseDrag)
    handle.mouseDragged(with: collapseDrag)
    handle.mouseDragged(with: collapseDrag)
    #expect(collapses == 1)
    #expect(container.sidebarState != "docked")
}

@MainActor
private func libraryDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + libraryDescendants($0) }
}
