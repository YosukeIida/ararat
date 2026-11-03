import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func interactionRows(_ view: NSView) -> [SidebarRowView] {
    view.subviews.flatMap { ($0 as? SidebarRowView).map { [$0] } ?? interactionRows($0) }
}

private func interactionSnapshot(selected: String? = "pin") -> WorkspaceSnapshot {
    let row: (String) -> Row = { Row(id: $0, title: String(repeating: $0, count: 60), url: "https://\($0).example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) }
    return WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: selected, spaces: [
        SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "work", title: "Work", icon: nil, look: nil,
                      favorites: [row("favorite")], pinned: [row("pin"), row("other")], today: [row("a"), row("b")])])
}

@MainActor
private func interactionWindow() -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: interactionSnapshot())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 500), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    return (window, sidebar)
}

@MainActor
private func rowEvent(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@Test @MainActor
func middleClickAndHoverButtonsUseTheTargetRowsAction() throws {
    let (window, sidebar) = interactionWindow()
    defer { window.contentView = nil }
    var closed: [String] = []
    var archived: [String] = []
    sidebar.onClose = { closed.append($0) }
    sidebar.onArchive = { archived.append($0) }
    let rows = interactionRows(sidebar)
    let pin = try #require(rows.first { $0.row.id == "pin" })
    let other = try #require(rows.first { $0.row.id == "other" })
    let today = try #require(rows.first { $0.row.id == "a" })
    #expect(pin.closeButton.accessibilityLabel() == "Close and Keep Pinned")
    #expect(other.closeButton.accessibilityLabel() == "Archive this tab")
    pin.closeButton.performClick(nil)
    other.closeButton.performClick(nil)
    let cgMiddle = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
    let middle = try #require(NSEvent(cgEvent: cgMiddle))
    #expect(middle.buttonNumber == 2)
    today.otherMouseUp(with: middle)
    other.otherMouseUp(with: middle)
    pin.otherMouseUp(with: middle)
    #expect(closed == ["pin", "a", "pin"])
    #expect(archived == ["other", "other"])
    let favorite = try #require(sidebar.subviews.flatMap { descendants($0) }.compactMap { $0 as? FavoriteTile }.first)
    favorite.otherMouseUp(with: middle)
    #expect(closed == ["pin", "a", "pin"])
    #expect(!window.isVisible && !window.isKeyWindow)
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@Test @MainActor
func hoverMasksTheTitleWithoutChangingItsFrame() throws {
    let (window, sidebar) = interactionWindow()
    defer { window.contentView = nil }
    let row = try #require(interactionRows(sidebar).first { $0.row.id == "pin" })
    let title = try #require(row.subviews.compactMap { $0 as? NSTextField }.first)
    row.pointerLocation = { nil }
    row.refreshHover()
    row.layoutSubtreeIfNeeded()
    let frame = title.frame
    #expect(sidebar.bounds.width == 240)
    #expect(row.frame.width == 224)
    #expect(row.closeButton.isHidden)
    #expect(title.layer?.mask == nil)
    let point = row.convert(NSPoint(x: 30, y: 20), to: nil)
    row.pointerLocation = { point }
    row.refreshHover()
    row.layoutSubtreeIfNeeded()
    #expect(title.frame == frame)
    #expect(!row.closeButton.isHidden)
    #expect(title.layer?.mask is CAGradientLayer)
    row.pointerLocation = { nil }
    row.refreshHover()
    row.layoutSubtreeIfNeeded()
    #expect(title.frame == frame)
    #expect(title.layer?.mask == nil)
    var short = row.row
    short.title = "Mail"
    row.update(row: short, selected: true)
    row.layoutSubtreeIfNeeded()
    let shortFrame = title.frame
    row.pointerLocation = { point }
    row.refreshHover()
    row.layoutSubtreeIfNeeded()
    #expect(title.frame == shortFrame)
    #expect(title.frame.maxX <= row.closeButton.frame.minX)
    #expect(title.layer?.mask == nil)

}

@Test @MainActor
func slightMovementClicksWithoutReorderingAndPressTracksStillPointer() throws {
    let (window, sidebar) = interactionWindow()
    defer { window.contentView = nil }
    let row = try #require(interactionRows(sidebar).first { $0.row.id == "a" })
    var selections: [String] = []
    sidebar.onSelect = { selections.append($0.id) }
    let start = row.convert(NSPoint(x: 30, y: 20), to: nil)
    row.pointerLocation = { start }
    row.mouseDown(with: try rowEvent(.leftMouseDown, point: start))
    #expect(row.pressed)
    let moved = NSPoint(x: start.x + 1, y: start.y)
    row.mouseDragged(with: try rowEvent(.leftMouseDragged, point: moved))
    row.mouseUp(with: try rowEvent(.leftMouseUp, point: moved))
    #expect(selections == ["a"])
    #expect(interactionRows(sidebar).map(\.row.id) == ["pin", "other", "a", "b"])
    #expect(!row.pressed)
    row.mouseDown(with: try rowEvent(.leftMouseDown, point: start))
    sidebar.applyClose(id: "other", snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: "pin", spaces: [
        SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [],
                      today: [Row(id: "a", title: "a", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)])]))
    row.refreshHover()
    #expect(!row.hovered && !row.pressed)
}

@Test @MainActor
func tooltipsUseIdleClockSwapImmediatelyAndClickResetsDelay() {
    let tooltip = SidebarTooltip()
    var now = 10.0
    tooltip.clock = { now }
    let first = NSButton(title: "One", target: nil, action: nil)
    let second = NSButton(title: "Two", target: nil, action: nil)
    first.toolTip = "One"
    second.toolTip = "Two"
    tooltip.capture(in: first)
    tooltip.capture(in: second)
    #expect(first.toolTip == nil)
    tooltip.update(target: first, point: NSPoint(x: 1, y: 1))
    now += 1.59
    tooltip.update(target: first, point: NSPoint(x: 1, y: 1))
    #expect(tooltip.text == nil)
    now += 0.02
    tooltip.update(target: first, point: NSPoint(x: 1, y: 1))
    #expect(tooltip.text == "One")
    tooltip.update(target: second, point: NSPoint(x: 2, y: 2))
    #expect(tooltip.text == "Two")
    tooltip.update(target: nil, point: NSPoint(x: 2.5, y: 2.5))
    #expect(tooltip.text == nil)
    tooltip.update(target: first, point: NSPoint(x: 3, y: 3))
    #expect(tooltip.text == nil)
    tooltip.dismiss()
    tooltip.update(target: first, point: NSPoint(x: 1, y: 1))
    #expect(tooltip.text == nil)
    now += 1
    tooltip.update(target: first, point: NSPoint(x: 3, y: 3))
    now += 1
    tooltip.update(target: first, point: NSPoint(x: 3, y: 3))
    #expect(tooltip.text == nil)
    now += 0.61
    tooltip.update(target: first, point: NSPoint(x: 3, y: 3))
    #expect(tooltip.text == "One")
    tooltip.update(target: nil, point: nil)
    #expect(tooltip.text == nil)
}

@Test @MainActor
func stillPointerRefreshesHoverAfterScrollingWithoutMouseEvents() async throws {
    let (window, sidebar) = interactionWindow()
    defer { window.contentView = nil }
    var snapshot = interactionSnapshot()
    snapshot.spaces[0].today = (0..<30).map { Row(id: "t\($0)", title: "Tab \($0)", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) }
    sidebar.update(snapshot: snapshot)
    let row = try #require(interactionRows(sidebar).first { $0.row.id == "t0" })
    let point = row.convert(NSPoint(x: 20, y: 20), to: nil)
    for view in interactionRows(sidebar) { view.pointerLocation = { point }; view.refreshHover() }
    #expect(row.hovered)
    let scroll = try #require(descendants(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    scroll.move(to: 41)
    try await waitUntil { !row.hovered }
    #expect(interactionRows(sidebar).contains { $0.row.id == "t1" && $0.hovered })
    #expect(!window.isVisible && !window.isKeyWindow)
}

@Test @MainActor
func tooltipPopsInAndFadesOutInTwoFramesWithoutTakingInput() throws {
    let (window, sidebar) = interactionWindow()
    defer { window.contentView = nil }
    let tooltip = SidebarTooltip()
    var now = 0.0
    tooltip.clock = { now }
    let row = try #require(interactionRows(sidebar).first)
    row.toolTip = "Tip"
    tooltip.capture(in: row)
    let point = row.convert(NSPoint(x: 20, y: 20), to: nil)
    tooltip.update(target: row, point: point)
    now = 1.6
    tooltip.update(target: row, point: point)
    let label = try #require(sidebar.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Tip" })
    #expect(label.frame.height == 28)
    #expect(label.layer?.animationKeys() == nil)
    #expect(label.hitTest(label.frame.origin) == nil)
    tooltip.dismiss()
    let fade = try #require(label.layer?.animation(forKey: "tooltip.hide") as? CABasicAnimation)
    #expect(fade.duration == 2.0 / 60)
    #expect(fade.toValue as? Double == 0)
    #expect(!window.isVisible && !window.isKeyWindow)
}
