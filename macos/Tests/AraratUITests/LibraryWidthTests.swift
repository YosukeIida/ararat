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

@MainActor
private func libraryDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + libraryDescendants($0) }
}
