import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func reviewAll(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(reviewAll) }

private func reviewSnapshot(pinned: Bool = false, selected: String = "t0", removing: String? = nil) -> WorkspaceSnapshot {
    let rows = (0..<30).map { "t\($0)" }.filter { $0 != removing }.map {
        Row(parentId: "", siblingIndex: 0, collapsed: false, id: $0, title: $0, url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    return WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: selected, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", id: "work", title: "Work", icon: nil, look: nil, favorites: [],
                      pinned: pinned ? rows : [], today: pinned ? [] : rows)])
}

@MainActor
private func reviewWindow(_ snapshot: WorkspaceSnapshot = reviewSnapshot()) -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let view = SidebarView(snapshot: snapshot)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 500), styleMask: [], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    return (window, view)
}

@Test @MainActor
func backgroundCloseAndArchiveDoNotRevealTheUnchangedSelection() throws {
    for pinned in [false, true] {
        let (window, sidebar) = reviewWindow(reviewSnapshot(pinned: pinned))
        defer { window.contentView = nil }
        let scroll = try #require(reviewAll(sidebar).compactMap { $0 as? SidebarScrollView }.first)
        var now = 0.0
        scroll.clock = { now }
        scroll.move(to: 600)
        let before = scroll.contentView.bounds.minY
        sidebar.applyClose(id: "t25", snapshot: reviewSnapshot(pinned: pinned, removing: "t25"))
        now = 1
        scroll.stepReveal()
        #expect(scroll.contentView.bounds.minY == before)
        sidebar.applyClose(id: "t0", snapshot: reviewSnapshot(pinned: pinned, selected: "t1", removing: "t0"))
        now = 2
        scroll.stepReveal()
        #expect(scroll.contentView.bounds.minY < before)
    }
}

@Test @MainActor
func tooltipSweepStaysVisibleAndReentryAfterAPauseWaitsForIdle() {
    let tooltip = SidebarTooltip()
    var now = 10.0
    tooltip.clock = { now }
    let first = NSButton(title: "One", target: nil, action: nil)
    let second = NSButton(title: "Two", target: nil, action: nil)
    first.toolTip = "One"; second.toolTip = "Two"
    tooltip.capture(in: first); tooltip.capture(in: second)
    tooltip.update(target: first, point: NSPoint(x: 1, y: 1))
    now += 1.7
    tooltip.update(target: first, point: NSPoint(x: 1, y: 1))
    #expect(tooltip.text == "One")
    for step in 0..<4 {
        now += 1.0 / 60
        tooltip.update(target: second, point: NSPoint(x: 10 + Double(step), y: 1))
        #expect(tooltip.text == "Two")
    }
    tooltip.update(target: nil, point: nil)
    now += 600
    tooltip.update(target: first, point: NSPoint(x: 1, y: 2))
    #expect(tooltip.text == nil)
    now += 1.59
    tooltip.update(target: first, point: NSPoint(x: 1, y: 2))
    #expect(tooltip.text == nil)
    now += 0.02
    tooltip.update(target: first, point: NSPoint(x: 1, y: 2))
    #expect(tooltip.text == "One")
}

@Test @MainActor
func shortTitlesHaveNoHoverMask() throws {
    let (window, sidebar) = reviewWindow()
    defer { window.contentView = nil }
    let view = try #require(reviewAll(sidebar).compactMap { $0 as? SidebarRowView }.first)
    let point = view.convert(NSPoint(x: 20, y: 20), to: nil)
    view.pointerLocation = { point }
    view.refreshHover()
    view.layoutSubtreeIfNeeded()
    let title = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(view.closeButton.frame.minX >= title.frame.maxX)
    #expect(title.layer?.mask == nil)
}

@Test @MainActor
func attachedIdleSidebarHasNoRepeatingTimer() {
    let (window, sidebar) = reviewWindow()
    defer { window.contentView = nil }
    let timers = Mirror(reflecting: sidebar).children.compactMap { $0.value as? Timer }.filter(\.isValid)
    #expect(timers.isEmpty)
}

@Test @MainActor
func rowAccessibilityActionsWorkWithoutThePointer() throws {
    for pinned in [false, true] {
        let (window, sidebar) = reviewWindow(reviewSnapshot(pinned: pinned))
        defer { window.contentView = nil }
        var closed: [String] = []
        var archived: [String] = []
        sidebar.onClose = { closed.append($0) }
        sidebar.onArchive = { archived.append($0) }
        for id in ["t0", "t1"] {
            let row = try #require(reviewAll(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == id })
            row.pointerLocation = { nil }; row.refreshHover()
            #expect(row.closeButton.isHidden)
            let action = try #require(row.accessibilityCustomActions()?.first)
            #expect(action.name == (pinned && id == "t0" ? "Close and Keep Pinned" : "Archive this tab"))
            #expect(action.handler?() == true)
        }
        #expect(closed == (pinned ? ["t0"] : ["t0", "t1"]))
        #expect(archived == (pinned ? ["t1"] : []))
    }
}

@Test @MainActor
func middleClickClosesTodaySplitsButLeavesPinnedSplitsAlone() throws {
    let row = Row(parentId: "", siblingIndex: 0, collapsed: false, id: "split", title: "Split", url: nil, depth: 0, kind: .split, unloaded: false, lastSelectedAt: nil)
    let view = SidebarRowView(row: row, selected: false) { _ in }
    var closed = 0
    view.onClose = { _ in closed += 1 }
    let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
    let event = try #require(NSEvent(cgEvent: cg))
    view.otherMouseUp(with: event)
    #expect(closed == 1)
    view.pinned = true
    view.otherMouseUp(with: event)
    #expect(closed == 1)
}

@Test @MainActor
func pressSelectsOnceAndReleaseOutsideDoesNothingElse() throws {
    let (window, sidebar) = reviewWindow()
    defer { window.contentView = nil }
    let row = try #require(reviewAll(sidebar).compactMap { $0 as? SidebarRowView }.first)
    let inside = row.convert(NSPoint(x: 20, y: 20), to: nil)
    let outside = row.convert(NSPoint(x: -20, y: 20), to: nil)
    var point = inside
    row.pointerLocation = { point }
    var selections = 0
    sidebar.onSelect = { _ in selections += 1 }
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: inside, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: outside, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    row.mouseDown(with: down)
    #expect(selections == 1)
    point = outside
    row.refreshHover()
    #expect(!row.pressed)
    row.mouseUp(with: up)
    #expect(selections == 1)
}

@Test @MainActor
func tooltipIdleTimerIsOneShotAndCancelledOnDeallocation() throws {
    var tooltip: SidebarTooltip? = SidebarTooltip()
    var now = 0.0
    tooltip?.clock = { now }
    let target = NSView()
    target.toolTip = "Tip"
    tooltip?.capture(in: target)
    tooltip?.update(target: target, point: NSPoint(x: 1, y: 1))
    let timer = try #require(tooltip?.idleTimer)
    #expect(timer.isValid)
    #expect(timer.timeInterval == 0)
    now = 1.6
    timer.fire()
    #expect(tooltip?.text == "Tip")
    #expect(tooltip?.idleTimer == nil)
    #expect(!timer.isValid)
    tooltip?.dismiss()
    tooltip?.update(target: target, point: NSPoint(x: 2, y: 2))
    let pending = try #require(tooltip?.idleTimer)
    tooltip = nil
    #expect(!pending.isValid)
}

@Test @MainActor
func sidebarDeallocationRemovesItsAttachedClickMonitor() {
    var removals = 0
    weak var released: SidebarView?
    autoreleasepool {
        let (window, sidebar) = reviewWindow()
        released = sidebar
        sidebar.removeClickMonitor = { token in
            removals += 1
            NSEvent.removeMonitor(token)
        }
        _ = window
    }
    #expect(released == nil)
    #expect(removals == 1)
}
