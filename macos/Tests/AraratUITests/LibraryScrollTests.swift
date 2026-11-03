import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
}

@MainActor
private func fixture(populated: Bool) -> (NSWindow, SidebarView, SidebarContainerView) {
    _ = NSApplication.shared
    let entries = populated ? (0..<100).map {
        ArchiveEntry(id: "closed-\($0)", title: "Entry \($0)", url: "https://example.com/\($0)", lifecycleChangedAt: UInt64($0))
    } : []
    let spaces = (0..<2).map {
        SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "s\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: entries, shownSpaceId: "s0", selectedId: nil, spaces: spaces))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = container
    container.resizeHandle.sidebarWidth = 332
    container.layoutSubtreeIfNeeded()
    return (window, sidebar, container)
}

@MainActor
private func send(_ window: NSWindow, sidebar: SidebarView, x: CGFloat, dx: Int32 = 0, dy: Int32 = 0,
                  phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil, time: Double) throws {
    let point = sidebar.convert(NSPoint(x: x, y: 350), to: nil)
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
    let screen = window.convertPoint(toScreen: point)
    event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
    if phase == nil && dy != 0 { event.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1) }
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
    event.timestamp = UInt64(time * 1_000_000_000)
    let nsEvent = try #require(NSEvent(cgEvent: event))
    let hit = try #require(window.contentView?.hitTest(point))
    hit.scrollWheel(with: nsEvent)
}

@Test @MainActor
func libraryPreviewReceivesTerminalEventsThroughActualHitTargets() throws {
    for populated in [false, true] {
        for cancelled in [false, true] {
            let (window, sidebar, container) = fixture(populated: populated)
            defer { window.contentView = nil }
            try send(window, sidebar: sidebar, x: 310, dx: 9500, phase: .began, time: 100)
            container.layoutSubtreeIfNeeded()
            try send(window, sidebar: sidebar, x: 310, phase: cancelled ? .cancelled : .ended, time: 100.02)
            try send(window, sidebar: sidebar, x: 310, dx: 100, momentum: .begin, time: 100.03)
            try send(window, sidebar: sidebar, x: 310, momentum: .end, time: 100.04)
            #expect(sidebar.libraryOpen == !cancelled)
            sidebar.finishScrollPresentation()
            #expect(!window.isVisible)
        }
    }
}

@Test @MainActor
func libraryListKeepsItsAxisAndOriginAcrossHitTargets() async throws {
    for populated in [false, true] {
        let (window, sidebar, container) = fixture(populated: populated)
        defer { window.contentView = nil }
        sidebar.setLibraryOpen(true)
        container.layoutSubtreeIfNeeded()
        let library = try #require(descendants(sidebar).compactMap { $0 as? LibraryView }.first)
        let scroll = try #require(descendants(library).compactMap { $0 as? NSScrollView }.first)
        try send(window, sidebar: sidebar, x: 310, dx: -400, dy: -1, phase: .began, time: 100)
        try send(window, sidebar: sidebar, x: 20, dy: -120, phase: .changed, time: 100.01)
        try send(window, sidebar: sidebar, x: 20, phase: .ended, time: 100.02)
        #expect(sidebar.libraryOpen && library.layer?.transform.m41 == 0)
        #expect(scroll.contentView.bounds.minY == 0)
        try send(window, sidebar: sidebar, x: 310, dx: -5, time: 101)
        #expect(sidebar.libraryOpen && library.layer?.transform.m41 == 0)
        container.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        let document = try #require(scroll.documentView)
        document.layoutSubtreeIfNeeded()
        let point = sidebar.convert(NSPoint(x: 310, y: 350), to: nil)
        let hit = try #require(window.contentView?.hitTest(point))
        print("ARCHIVE-WHEEL before", populated, "hit", String(describing: type(of: hit)), "document", document.frame, "clip", scroll.contentView.bounds)
        if populated {
            #expect(hit === scroll || hit.isDescendant(of: scroll), "Vertical wheel hit \(type(of: hit)) must belong to the archive scroll view")
            #expect(document.frame.height > scroll.contentView.bounds.height, "Archive document height \(document.frame.height) must exceed clip height \(scroll.contentView.bounds.height)")
        } else {
            #expect(scroll.isHidden, "Empty archive scroll view must be hidden; wheel hit is \(type(of: hit))")
        }
        try send(window, sidebar: sidebar, x: 310, dy: -120, time: 101.5)
        print("ARCHIVE-WHEEL after event", populated, scroll.contentView.bounds)
        try await waitUntil { !populated || scroll.contentView.bounds.minY > 0 }
        print("ARCHIVE-WHEEL after poll", populated, scroll.contentView.bounds)
        let wheelPosition = scroll.contentView.bounds.minY
        if populated { #expect(wheelPosition > 0) }
        try send(window, sidebar: sidebar, x: 310, dx: -1, dy: -120, phase: .began, time: 102)
        try send(window, sidebar: sidebar, x: 310, dy: -120, phase: .changed, time: 102.005)
        try send(window, sidebar: sidebar, x: 20, dx: -400, dy: -120, phase: .changed, time: 102.01)
        try send(window, sidebar: sidebar, x: 20, phase: .ended, time: 102.02)
        try await waitUntil { !populated || scroll.contentView.bounds.minY > wheelPosition }
        #expect(sidebar.libraryOpen && library.layer?.transform.m41 == 0)
        if populated { #expect(scroll.contentView.bounds.minY > wheelPosition) }
        try send(window, sidebar: sidebar, x: 20, dx: -20, phase: .began, time: 103)
        #expect(library.layer?.transform.m41 == -10)
        try send(window, sidebar: sidebar, x: 310, phase: .ended, time: 103.02)
        #expect(!sidebar.libraryOpen && sidebar.spaceShown == 0)
    }
}

@Test @MainActor
func overlayWheelTargetsAreInwardOnlyAndRespectInversionAndPause() {
    for inverted in [false, true] {
        let sign = inverted ? -1.0 : 1.0
        for (index, dx, target) in [(-1, -2.0, 0), (2, 2.0, 1)] {
            var state = SpaceScrollState()
            #expect(state.handle(.init(dx: dx * sign, inverted: inverted, time: 100), index: index, count: 2, pitch: 240) == .settle(index: target, offset: 0, switched: true))
            #expect(state.handle(.init(dx: dx * sign, inverted: inverted, time: 100.249), index: target, count: 2, pitch: 240) == .ignored)
        }
        for (index, dx) in [(-1, 2.0), (2, -2.0)] {
            var state = SpaceScrollState()
            #expect(state.handle(.init(dx: dx * sign, inverted: inverted, time: 100), index: index, count: 2, pitch: 240) == .ignored)
        }
    }
}

@Test @MainActor
func libraryRailWheelReturnsToSpaceZeroThroughTheHitTarget() throws {
    for populated in [false, true] {
        let (window, sidebar, container) = fixture(populated: populated)
        defer { window.contentView = nil }
        sidebar.showSpace(at: 1)
        sidebar.setLibraryOpen(true)
        container.layoutSubtreeIfNeeded()
        let library = try #require(descendants(sidebar).compactMap { $0 as? LibraryView }.first)
        try send(window, sidebar: sidebar, x: 20, dx: 5, time: 100)
        #expect(sidebar.libraryOpen && library.layer?.transform.m41 == 0)
        try send(window, sidebar: sidebar, x: 20, dx: -5, time: 101)
        #expect(!sidebar.libraryOpen && sidebar.spaceShown == 0)
        #expect(library.layer?.animation(forKey: "space.scroll") is CASpringAnimation)
    }
}

@Test @MainActor
func libraryRailHasNoOutwardFollowAndUsesTheSpaceReleaseRule() {
    var state = SpaceScrollState()
    #expect(state.handle(.init(dx: 20, phase: .began, time: 100), index: -1, count: 2, pitch: 240) == .follow(0))
    #expect(state.handle(.init(dx: 0, phase: .ended, time: 100.02), index: -1, count: 2, pitch: 240) == .settle(index: -1, offset: 0, switched: false))
    #expect(state.handle(.init(dx: -20, phase: .began, time: 101), index: -1, count: 2, pitch: 240) == .follow(-10))
    #expect(state.handle(.init(dx: 0, phase: .ended, time: 101.02), index: -1, count: 2, pitch: 240) == .settle(index: 0, offset: -10, switched: true))
    _ = state.handle(.init(dx: -5000, phase: .began, time: 102), index: -1, count: 2, pitch: 240)
    guard case .settle(let index, _, _) = state.handle(.init(dx: 0, phase: .ended, time: 102.02), index: -1, count: 2, pitch: 240) else { Issue.record("Expected settle"); return }
    #expect(index == 0)
}

@Test @MainActor
func scrollPagesClipAtSidebarWithoutChangingThePanelOrResizeHandle() throws {
    for floating in [false, true] {
        let (window, sidebar, container) = fixture(populated: true)
        defer { window.contentView = nil }
        if floating { container.toggleSidebar(); container.layoutSubtreeIfNeeded() }
        let panel = try #require(sidebar.superview)
        let mask = panel.layer?.masksToBounds
        let border = panel.layer?.borderWidth
        let shadow = panel.layer?.shadowOpacity
        try send(window, sidebar: sidebar, x: 310, dx: 9500, phase: .began, time: 100)
        #expect(sidebar.layer?.masksToBounds == true)
        #expect(panel.layer?.masksToBounds == mask)
        #expect(panel.layer?.borderWidth == border)
        #expect(panel.layer?.shadowOpacity == shadow)
        #expect(container.resizeHandle.superview === panel)
        let button = try #require(sidebar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Library" })
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(point) === button)
        let handle = container.resizeHandle
        let handlePoint = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(handlePoint) === handle)
    }
}

@Test @MainActor
func wheelOpensLibraryLikeTrackpadAndPausesBeforeRailReturn() async throws {
    for populated in [false, true] {
        let (window, sidebar, container) = fixture(populated: populated)
        defer { window.contentView = nil }
        try send(window, sidebar: sidebar, x: 150, dx: 9500, phase: .began, time: 90)
        try send(window, sidebar: sidebar, x: 150, phase: .ended, time: 90.02)
        try await Task.sleep(for: .milliseconds(700))
        container.layoutSubtreeIfNeeded()
        let trackpadWidth = sidebar.bounds.width
        let trackpadState = container.sidebarState
        #expect(sidebar.libraryOpen && trackpadWidth == 402)
        sidebar.setLibraryOpen(false)
        try await Task.sleep(for: .milliseconds(700))
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.bounds.width == 332)
        try send(window, sidebar: sidebar, x: 150, dx: 5, time: 100)
        #expect(sidebar.libraryOpen)
        let library = try #require(descendants(sidebar).compactMap { $0 as? LibraryView }.first)
        #expect(library.layer?.animation(forKey: "space.scroll") is CASpringAnimation)
        try send(window, sidebar: sidebar, x: 20, dx: -5, time: 100.100)
        #expect(sidebar.libraryOpen && sidebar.spaceShown == 0)
        try send(window, sidebar: sidebar, x: 20, dx: -5, time: 100.249)
        #expect(sidebar.libraryOpen && sidebar.spaceShown == 0)
        try await Task.sleep(for: .milliseconds(700))
        container.layoutSubtreeIfNeeded()
        #expect(sidebar.bounds.width == trackpadWidth)
        #expect(container.sidebarState == trackpadState)
        #expect(library.layer?.transform.m41 == 0)
        try send(window, sidebar: sidebar, x: 150, dx: -5, time: 100.250)
        #expect(sidebar.libraryOpen)
        try send(window, sidebar: sidebar, x: 20, dx: -5, time: 100.251)
        #expect(!sidebar.libraryOpen && sidebar.spaceShown == 0)
        #expect(library.layer?.animation(forKey: "space.scroll") is CASpringAnimation)
        #expect(!window.isVisible)
    }
}

@Test @MainActor
func wheelFromSpaceOneCannotCarryIntoLibraryDuringPause() throws {
    let (window, sidebar, _) = fixture(populated: true)
    defer { window.contentView = nil }
    sidebar.showSpace(at: 1)
    try send(window, sidebar: sidebar, x: 150, dx: 5, time: 100)
    #expect(sidebar.spaceShown == 0 && !sidebar.libraryOpen)
    try send(window, sidebar: sidebar, x: 150, dx: 5, time: 100.249)
    #expect(sidebar.spaceShown == 0 && !sidebar.libraryOpen)
    try send(window, sidebar: sidebar, x: 150, dx: 5, time: 100.250)
    #expect(sidebar.libraryOpen)
    #expect(!window.isVisible)
}

@Test @MainActor
func wheelLibraryBoundaryUsesTheSameAccumulationAndInversion() {
    for inverted in [false, true] {
        for delay in [0.040, 0.049, 0.050] {
            var state = SpaceScrollState()
            let sign = inverted ? -1.0 : 1.0
            #expect(state.handle(.init(dx: sign * 0.6, inverted: inverted, time: 0), index: 0, count: 2, pitch: 332) == .ignored)
            #expect(state.handle(.init(dx: sign * 0.6, inverted: inverted, time: delay), index: 0, count: 2, pitch: 332) ==
                    (delay <= 0.049 ? .settle(index: -1, offset: 0, switched: true) : .ignored))
        }
    }
}

@Test @MainActor
func autoArchivePublishWaitsForTheGestureAndItsScrollPresentation() throws {
    let (window, sidebar, _) = fixture(populated: false)
    defer { window.contentView = nil }
    var ready = 0
    sidebar.onAutoArchiveReady = { ready += 1 }
    #expect(sidebar.canPublishAutoArchive)
    try send(window, sidebar: sidebar, x: 310, dx: -30, phase: .began, time: 100)
    #expect(!sidebar.canPublishAutoArchive)
    try send(window, sidebar: sidebar, x: 310, phase: .ended, time: 100.02)
    #expect(!sidebar.canPublishAutoArchive)
    sidebar.finishScrollPresentation()
    #expect(sidebar.canPublishAutoArchive)
    #expect(ready == 1)
    try send(window, sidebar: sidebar, x: 310, dy: -10, phase: .began, time: 101)
    #expect(!sidebar.canPublishAutoArchive)
    try send(window, sidebar: sidebar, x: 310, phase: .ended, time: 101.02)
    #expect(sidebar.canPublishAutoArchive)
    #expect(ready == 2)
    #expect(!window.isVisible)
}
