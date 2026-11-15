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

/// A press on an overlay inside the page keeps its own click (review M1): the container only
/// starts a drag when the press resolves to the container itself, so a forwarded press from an
/// error page or the "Shown in another window" placeholder does not move or zoom the window.
@Test @MainActor
func aPressOnTheCardsOverlayDoesNotReachTheContainersDrag() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [],
                          backing: .buffered, defer: false)
    let sidebar = SidebarView(snapshot: dragSnapshot())
    let page = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: page)
    window.contentView = container
    let overlay = PageFailureView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    overlay.autoresizingMask = [.width, .height]
    page.addSubview(overlay)
    container.layoutSubtreeIfNeeded()
    defer { window.contentView = nil }
    let overlayPoint = overlay.convert(NSPoint(x: 24, y: 24), to: nil)
    #expect(WindowDrag.pressTarget(in: window, at: overlayPoint) === overlay)
    #expect(WindowDrag.pressTarget(in: window, at: overlayPoint) !== container)
    // The card's own margin still resolves to the container, so its press keeps dragging.
    #expect(WindowDrag.pressTarget(in: window, at: container.checkAboveCardPoint()) === container)
    // And the sidebar's empty area resolves to the sidebar, not to something it forwards to.
    let sidebarPoint = try #require(sidebar.checkDragAreaPoints()["column_gap"])
    #expect(WindowDrag.pressTarget(in: window, at: sidebarPoint) === sidebar)
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

/// The setting's value is read on each press; the test pins every stored value without touching
/// the host's defaults (review L4).
@Test
func doubleClickFollowsTheTitleBarSetting() {
    #expect(WindowDoubleClickAction.fromSetting("Maximize") == .zoom)
    #expect(WindowDoubleClickAction.fromSetting("Minimize") == .minimize)
    #expect(WindowDoubleClickAction.fromSetting("None") == .nothing)
    // A Mac that never changed the setting has no key, and an unknown value (macOS 15's "Fill")
    // behaves as the system's default zoom.
    #expect(WindowDoubleClickAction.fromSetting(nil) == .zoom)
    #expect(WindowDoubleClickAction.fromSetting("Fill") == .zoom)
}

/// A double click's second press that moves drags the window and never runs the title-bar action
/// (review H1): the tracker only acts on a release that stayed within the threshold, and each
/// drag step moves the window by the pointer's own step.
@Test @MainActor
func aSecondPressThatMovesDragsAndNeverActs() {
    var tracker = WindowDrag.SecondPressTracker(press: NSPoint(x: 100, y: 100))
    // A point or two of hand movement is still a stationary click.
    #expect(tracker.handle(.init(type: .leftMouseDragged, location: NSPoint(x: 102, y: 100))) == .ignore)
    // Past the threshold it is a drag, and the first step catches up from the press point.
    #expect(tracker.handle(.init(type: .leftMouseDragged, location: NSPoint(x: 140, y: 90)))
            == .move(NSPoint(x: 40, y: -10)))
    #expect(tracker.dragging)
    // Later steps move by their own delta only.
    #expect(tracker.handle(.init(type: .leftMouseDragged, location: NSPoint(x: 150, y: 80)))
            == .move(NSPoint(x: 10, y: -10)))
    #expect(tracker.handle(.init(type: .leftMouseUp, location: NSPoint(x: 150, y: 80))) == .end)
}

/// A release that stayed within the threshold runs the action, and a press that jumps before its
/// release does not (review H1).
@Test @MainActor
func aStationarySecondClickActsOnTheRelease() {
    var tracker = WindowDrag.SecondPressTracker(press: NSPoint(x: 100, y: 100))
    #expect(tracker.handle(.init(type: .leftMouseDragged, location: NSPoint(x: 101, y: 101))) == .ignore)
    #expect(tracker.handle(.init(type: .leftMouseUp, location: NSPoint(x: 101, y: 101))) == .action)
    #expect(!tracker.dragging)
    var jumped = WindowDrag.SecondPressTracker(press: NSPoint(x: 100, y: 100))
    #expect(jumped.handle(.init(type: .leftMouseUp, location: NSPoint(x: 160, y: 100))) == .end)
    // Anything that is not a drag or a release leaves the decision open.
    var other = WindowDrag.SecondPressTracker(press: NSPoint(x: 100, y: 100))
    #expect(other.handle(.init(type: .mouseMoved, location: NSPoint(x: 300, y: 300))) == .ignore)
    #expect(other.handle(.init(type: .leftMouseUp, location: NSPoint(x: 100, y: 100))) == .action)
}
