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

/// A drag area's press is stored and follows one rule (design, 2026-11-16): within the threshold
/// nothing happens, past it the stored press is handed to the window server exactly once, with the
/// event the view kept. The two effectful steps are injected, so no event goes through `NSApp` and
/// no window is ordered front.
@MainActor
private func dragPress(clickCount: Int = 1, at point: NSPoint = NSPoint(x: 100, y: 100)) throws
    -> (window: NSWindow, view: NSView, event: NSEvent, held: WindowDrag.Held, handed: () -> [NSEvent], acted: () -> Int) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = view
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: clickCount, pressure: 1))
    var handed: [NSEvent] = []
    var acts = 0
    let held = try #require(WindowDrag.Held(in: view, with: event, action: .zoom,
                                            hand: { handed.append($0) },
                                            run: { _ in acts += 1 }))
    return (window, view, event, held, { handed }, { acts })
}

@Test @MainActor
func aStoredPressAsksForOneDragPastTheThresholdWithThePressItKept() throws {
    let press = try dragPress()
    defer { press.window.contentView = nil }
    let origin = press.held.origin
    // A point or two of hand movement is still a click.
    press.held.dragged(to: NSPoint(x: origin.x + 2, y: origin.y + 1))
    #expect(press.handed().isEmpty)
    #expect(!press.held.handedOver)
    // Past 3 pt it is a drag, asked for once, with the stored mouse-down event itself.
    press.held.dragged(to: NSPoint(x: origin.x + 40, y: origin.y - 10))
    #expect(press.handed().count == 1)
    #expect(press.handed().first === press.event)
    #expect(press.held.handedOver)
    // Later points ask for nothing more, and the system's release runs no action.
    press.held.dragged(to: NSPoint(x: origin.x + 80, y: origin.y - 20))
    press.held.released(at: NSPoint(x: origin.x + 80, y: origin.y - 20))
    #expect(press.handed().count == 1)
    #expect(press.acted() == 0)
}

/// A second click that never moved runs the title-bar action on its release, once (review H1 of
/// review 6): a third press is a fresh one and does nothing, and a release after the action owes
/// nothing.
@Test @MainActor
func aStationarySecondClickRunsTheActionOnce() throws {
    let press = try dragPress(clickCount: 2)
    defer { press.window.contentView = nil }
    let origin = press.held.origin
    // A point of movement, and then the release, still a click.
    press.held.dragged(to: NSPoint(x: origin.x + 1, y: origin.y))
    press.held.released(at: NSPoint(x: origin.x + 1, y: origin.y))
    #expect(press.acted() == 1)
    press.held.released(at: NSPoint(x: origin.x + 1, y: origin.y))
    #expect(press.acted() == 1)
    // A single click on the title bar does nothing on its release.
    let single = try dragPress(clickCount: 1)
    defer { single.window.contentView = nil }
    single.held.released(at: single.held.origin)
    #expect(single.acted() == 0)
}

/// A second press that moves drags the window and never runs the action (review H1), including a
/// release past the threshold whose dragged events were lost: the release point decides too.
@Test @MainActor
func aSecondClickThatMovesNeverActs() throws {
    let press = try dragPress(clickCount: 2)
    defer { press.window.contentView = nil }
    let origin = press.held.origin
    press.held.dragged(to: NSPoint(x: origin.x + 30, y: origin.y))
    #expect(press.handed().count == 1)
    press.held.released(at: NSPoint(x: origin.x + 30, y: origin.y))
    #expect(press.acted() == 0)
    // A release that jumped with no dragged event at all is a move as well.
    let jumped = try dragPress(clickCount: 2)
    defer { jumped.window.contentView = nil }
    jumped.held.released(at: NSPoint(x: jumped.held.origin.x + 60, y: jumped.held.origin.y))
    #expect(jumped.acted() == 0)
    #expect(jumped.handed().isEmpty)
}

/// A press that landed on a view inside the drag area keeps its own click: the press is not the
/// area's to take, so no held press is made for it (review M1 of review 5).
@Test @MainActor
func aPressOnAnInnerViewIsNotTheDragAreasToTake() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let area = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = area
    defer { window.contentView = nil }
    let inner = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
    area.addSubview(inner)
    func mouseDown(_ point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 1))
    }
    #expect(WindowDrag.Held(in: area, with: try mouseDown(NSPoint(x: 60, y: 60))) == nil)
    #expect(WindowDrag.Held(in: area, with: try mouseDown(NSPoint(x: 300, y: 200))) != nil)
}
