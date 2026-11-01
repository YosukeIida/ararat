import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func hiddenSidebar() -> SidebarState {
    var state = SidebarState()
    state.hasSelection = true
    state.toggle()
    return state
}

@MainActor
private func move(_ state: inout SidebarState, x: CGFloat, y: CGFloat = 300, at time: TimeInterval,
                  active: Bool = true, key: Bool = true, windowWidth: CGFloat = 800) {
    state.update(pointer: NSPoint(x: 100 + x, y: 100 + y), now: time,
                 window: NSRect(x: 100, y: 100, width: windowWidth, height: 600), width: 240, active: active, key: key)
}

@Test @MainActor
func sidebarToggleAndRevealTransitions() {
    var state = hiddenSidebar()
    #expect(state.mode == .hidden)
    move(&state, x: 5, at: 0)
    move(&state, x: 5, at: 0.150)
    #expect(state.mode == .floating)
    state.toggle()
    #expect(state.mode == .docked)
    state.toggle()
    #expect(state.mode == .hidden)
}

@Test @MainActor
func sidebarDwellRequiresAnUninterruptedStay() {
    var state = hiddenSidebar()
    move(&state, x: 0, at: 0)
    move(&state, x: 0, at: 0.149)
    #expect(state.mode == .hidden)
    move(&state, x: 6, at: 0.149)
    #expect(state.dwellStartedAt == nil)
    move(&state, x: -47, at: 1)
    move(&state, x: -47, at: 1.149)
    #expect(state.mode == .hidden)
    move(&state, x: -47, at: 1.150)
    #expect(state.mode == .floating)
    #expect(state.dwellStartedAt == nil)
}

@Test @MainActor
func floatingSidebarAppliesThePointerLimitsInsideAndOutsideTheWindow() {
    let cases: [(CGFloat, CGFloat, Bool)] = [
        (-250, 300, true), (-251, 300, false), (317, 300, true), (318, 300, false),
        (100, 600, true), (100, 601, false), (-47, 300, true), (0, 300, true),
    ]
    for windowWidth: CGFloat in [200, 800] {
        for (x, y, stays) in cases {
            var state = hiddenSidebar()
            move(&state, x: 0, at: 0)
            move(&state, x: 0, at: 0.150)
            move(&state, x: x, y: y, at: 1, windowWidth: windowWidth)
            #expect(state.mode == (stays ? .floating : .hidden))
        }
    }
}

@Test @MainActor
func inactiveAndNonKeyWindowsCancelDwellAndHideSelectedFloatingSidebars() {
    for (active, key) in [(false, true), (true, false)] {
        var state = hiddenSidebar()
        move(&state, x: 0, at: 0)
        move(&state, x: 0, at: 0.150, active: active, key: key)
        #expect(state.mode == .hidden)
        #expect(state.dwellStartedAt == nil)
        move(&state, x: 0, at: 1)
        move(&state, x: 0, at: 1.150)
        #expect(state.mode == .floating)
        move(&state, x: 0, at: 2, active: active, key: key)
        #expect(state.mode == .hidden)
    }
}

@Test @MainActor
func noSelectionSuspendsEveryHideRuleButStillAllowsToggling() {
    var state = SidebarState()
    state.toggle()
    #expect(state.mode == .floating)
    move(&state, x: -1000, y: 1000, at: 1, active: false, key: false)
    #expect(state.mode == .floating)
    state.toggle()
    #expect(state.mode == .docked)
    state.toggle()
    state.hasSelection = true
    move(&state, x: -1000, y: 1000, at: 2, active: false, key: false)
    #expect(state.mode == .hidden)
}

@Test @MainActor
func revealDoesNotStartAboveBelowOrTooFarLeftOfTheWindow() {
    for point in [NSPoint(x: 0, y: 601), NSPoint(x: 0, y: -1), NSPoint(x: -251, y: 300)] {
        var state = hiddenSidebar()
        move(&state, x: point.x, y: point.y, at: 0)
        move(&state, x: point.x, y: point.y, at: 1)
        #expect(state.mode == .hidden)
        #expect(state.dwellStartedAt == nil)
    }
}

@Test @MainActor
func dragCollapseUsesThePointerThreshold() {
    var state = SidebarState()
    state.hasSelection = true
    let atThreshold = state.collapseDrag(pointerX: 81)
    #expect(!atThreshold)
    #expect(state.mode == .docked)
    let belowThreshold = state.collapseDrag(pointerX: 80)
    #expect(belowThreshold)
    #expect(state.mode == .hidden)
    state.toggle()
    #expect(state.mode == .docked)
    state.hasSelection = false
    let withoutSelection = state.collapseDrag(pointerX: 0)
    #expect(withoutSelection)
    #expect(state.mode == .floating)
}

@Test @MainActor
func widthChangesRelayoutACleanContainerWithoutToggling() {
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: []))
    let page = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: page)
    container.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
    container.layoutSubtreeIfNeeded()
    #expect(!container.needsLayout)
    let panel = container.subviews.compactMap { $0 as? NSVisualEffectView }.first!
    for width: CGFloat in [320, 164] {
        container.resizeHandle.sidebarWidth = width
        #expect(panel.frame.width == width)
        #expect(page.frame.minX == width)
        #expect(!container.needsLayout)
        container.resizeHandle.resetWidth()
        #expect(panel.frame.width == 240)
        #expect(page.frame.minX == 240)
        #expect(!container.needsLayout)
    }
    #expect(container.resizeHandle.accessibilityPerformIncrement())
    #expect(panel.frame.width == 241)
    #expect(page.frame.minX == 241)
    #expect(container.resizeHandle.accessibilityPerformDecrement())
    #expect(panel.frame.width == 240)
    #expect(page.frame.minX == 240)
}

@Test @MainActor
func floatingPanelGeometryAndDragCollapseKeepTheExistingSidebar() {
    let row = Row(id: "tab", title: "Title", url: nil, depth: 0, kind: .tab, unloaded: false)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: [
        SpaceSnapshot(id: "space", title: "Work", icon: nil, favorites: [], pinned: [row], today: [])
    ]))
    let page = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: page)
    container.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
    container.layoutSubtreeIfNeeded()
    #expect(page.frame == NSRect(x: 240, y: 10, width: 850, height: 700))
    container.toggleSidebar()
    let panel = container.subviews.compactMap { $0 as? NSVisualEffectView }.first!
    #expect(panel.frame == NSRect(x: 5, y: 5, width: 240, height: 710))
    #expect(panel.layer?.cornerCurve == .continuous)
    #expect(panel.layer?.cornerRadius == 11)
    #expect(panel.layer?.borderWidth == 1)
    #expect(page.frame == NSRect(x: 10, y: 10, width: 1080, height: 700))
    #expect(sidebar.superview === panel)
    container.toggleSidebar()
    container.resizeHandle.sidebarWidth = 320
    container.layoutSubtreeIfNeeded()
    #expect(panel.frame.width == 320)
    #expect(page.frame.minX == 320)
    container.resizeHandle.resetWidth()
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.selectRow(id: "tab"))
    container.selectionChanged()
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 238, y: 300), modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 80, y: 300), modifierFlags: [], timestamp: 1,
                                  windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    container.resizeHandle.mouseDown(with: down)
    container.resizeHandle.mouseDragged(with: drag)
    #expect(container.sidebarState == "hidden")
    #expect(container.resizeHandle.sidebarWidth == 164)
    #expect(page.frame == NSRect(x: 10, y: 10, width: 1080, height: 700))
    let animation = panel.layer?.animation(forKey: "sidebar.position") as? CABasicAnimation
    #expect(animation?.duration == SidebarMetrics.dockHideDuration)
    #expect((animation?.fromValue as? NSValue)?.pointValue != (animation?.toValue as? NSValue)?.pointValue)
    let returnDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 400, y: 300), modifierFlags: [], timestamp: 2,
                                        windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
    container.resizeHandle.mouseDragged(with: returnDrag)
    #expect(container.resizeHandle.sidebarWidth == 164)
    container.toggleSidebar()
    #expect(container.sidebarState == "docked")
    #expect(page.frame.minX == 164)
    #expect(container.resizeHandle.sidebarWidth == 164)
}
