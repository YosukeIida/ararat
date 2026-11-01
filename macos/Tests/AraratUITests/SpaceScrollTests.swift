import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test
func scrollClassificationUsesEitherPhase() {
    #expect(SpaceScrollEvent(dx: 1, time: 0).kind == .wheel)
    for phase in [SpaceScrollEvent.Phase.mayBegin, .began, .changed, .ended, .cancelled] {
        #expect(SpaceScrollEvent(dx: 1, phase: phase, time: 0).kind == .trackpad)
    }
    #expect(SpaceScrollEvent(dx: 1, momentum: true, time: 0).kind == .trackpad)
}

@Test @MainActor
func wheelAccumulatesOnlyWithinFortyNineMilliseconds() {
    for delay in [0.040, 0.049, 0.050] {
        var state = SpaceScrollState()
        let first = state.handle(.init(dx: -0.6, time: 0), index: 0, count: 3, pitch: 180)
        let second = state.handle(.init(dx: -0.6, time: delay), index: 0, count: 3, pitch: 180)
        #expect(first == .ignored)
        #expect(second == (delay <= 0.049 ? .settle(index: 1, offset: 0, switched: true) : .ignored))
    }
}

@Test @MainActor
func wheelThresholdIsStrictAndItsWindowSlides() {
    var state = SpaceScrollState()
    let one = state.handle(.init(dx: -1, time: 0), index: 0, count: 3, pitch: 180)
    let above = state.handle(.init(dx: -0.01, time: 0.01), index: 0, count: 3, pitch: 180)
    #expect(one == .ignored)
    #expect(above == .settle(index: 1, offset: 0, switched: true))
    state = SpaceScrollState()
    for time in [0.0, 0.030, 0.060] {
        let action = state.handle(.init(dx: -0.4, time: time), index: 0, count: 3, pitch: 180)
        #expect(action == .ignored)
    }
    let accumulated = state.handle(.init(dx: -0.4, time: 0.070), index: 0, count: 3, pitch: 180)
    #expect(accumulated == .settle(index: 1, offset: 0, switched: true))
}

@Test @MainActor
func wheelInversionAndDirectionMatchArc() {
    for inverted in [false, true] {
        var state = SpaceScrollState()
        let action = state.handle(.init(dx: -2, inverted: inverted, time: 0), index: 1, count: 3, pitch: 180)
        #expect(action == .settle(index: inverted ? 0 : 2, offset: 0, switched: true))
    }
}

@Test @MainActor
func wheelPauseIsMeasuredFromTheSwitchAndDoesNotExtend() {
    var state = SpaceScrollState()
    let first = state.handle(.init(dx: -2, time: 0), index: 0, count: 4, pitch: 180)
    #expect(first == .settle(index: 1, offset: 0, switched: true))
    for time in [0.030, 0.100, 0.249] {
        let action = state.handle(.init(dx: -20, time: time), index: 1, count: 4, pitch: 180)
        #expect(action == .ignored)
    }
    let afterPause = state.handle(.init(dx: -2, time: 0.250), index: 1, count: 4, pitch: 180)
    #expect(afterPause == .settle(index: 2, offset: 0, switched: true))
}

@Test @MainActor
func wheelVerticalInputPassesThroughEvenDuringPause() {
    var state = SpaceScrollState()
    _ = state.handle(.init(dx: -2, time: 0), index: 0, count: 3, pitch: 180)
    let vertical = state.handle(.init(dx: -2, dy: -3, time: 0.010), index: 1, count: 3, pitch: 180)
    let tie = state.handle(.init(dx: 2, dy: 2, time: 0.020), index: 1, count: 3, pitch: 180)
    #expect(vertical == .vertical)
    #expect(tie == .vertical)
}

@Test @MainActor
func trackpadFollowsHalfItsDeltaWithoutInverting() {
    for inverted in [false, true] {
        var state = SpaceScrollState()
        let first = state.handle(.init(dx: -4, phase: .began, inverted: inverted, time: 0), index: 1, count: 3, pitch: 180)
        let next = state.handle(.init(dx: -8, phase: .changed, inverted: inverted, time: 0.010), index: 1, count: 3, pitch: 180)
        #expect(first == .follow(-2))
        #expect(next == .follow(-6))
    }
}

@Test @MainActor
func trackpadLocksToItsFirstNonzeroAxis() {
    var state = SpaceScrollState()
    _ = state.handle(.init(dx: 0, phase: .began, time: 0), index: 1, count: 3, pitch: 180)
    let horizontal = state.handle(.init(dx: -4, dy: 1, phase: .changed, time: 0.010), index: 1, count: 3, pitch: 180)
    let staysHorizontal = state.handle(.init(dx: -2, dy: 100, phase: .changed, time: 0.020), index: 1, count: 3, pitch: 180)
    #expect(horizontal == .follow(-2))
    #expect(staysHorizontal == .follow(-3))
    state = SpaceScrollState()
    let vertical = state.handle(.init(dx: 1, dy: 4, phase: .began, time: 0), index: 1, count: 3, pitch: 180)
    let staysVertical = state.handle(.init(dx: 100, dy: 1, phase: .changed, time: 0.010), index: 1, count: 3, pitch: 180)
    _ = state.handle(.init(dx: 0, phase: .ended, time: 0.020), index: 1, count: 3, pitch: 180)
    let momentum = state.handle(.init(dx: 0, dy: 20, momentum: true, time: 0.030), index: 1, count: 3, pitch: 180)
    #expect(vertical == .vertical)
    #expect(staysVertical == .vertical)
    #expect(momentum == .vertical)
}

@Test @MainActor
func trackpadRecentVelocityPicksTheDirectionalBoundary() {
    for delta in [-2.0, 2] {
        var state = SpaceScrollState()
        _ = state.handle(.init(dx: delta, phase: .began, time: 0), index: 1, count: 3, pitch: 180)
        let release = state.handle(.init(dx: 0, phase: .ended, time: 0.060), index: 1, count: 3, pitch: 180)
        #expect(release == .settle(index: delta < 0 ? 2 : 0, offset: delta / 2, switched: true))
    }
    var state = SpaceScrollState()
    _ = state.handle(.init(dx: -100, phase: .began, time: 0), index: 1, count: 3, pitch: 180)
    _ = state.handle(.init(dx: 1, phase: .changed, time: 0.200), index: 1, count: 3, pitch: 180)
    let reversed = state.handle(.init(dx: 0, phase: .ended, time: 0.250), index: 1, count: 3, pitch: 180)
    #expect(reversed == .settle(index: 1, offset: -49.5, switched: false))
}

@Test @MainActor
func trackpadWithoutRecentVelocityUsesTheStrictHalfPageThreshold() {
    for delta in [-184.0, -180, -20, 20, 180, 184] {
        var state = SpaceScrollState()
        _ = state.handle(.init(dx: delta, phase: .began, time: 0), index: 1, count: 3, pitch: 180)
        let release = state.handle(.init(dx: 0, phase: .ended, time: 0.120), index: 1, count: 3, pitch: 180)
        let switches = abs(delta) > 180
        let target = switches ? (delta < 0 ? 2 : 0) : 1
        #expect(release == .settle(index: target, offset: delta / 2, switched: switches))
    }
}

@Test @MainActor
func horizontalGestureMomentumCannotSwitchAgain() {
    var state = SpaceScrollState()
    _ = state.handle(.init(dx: -2, phase: .began, time: 0), index: 0, count: 4, pitch: 180)
    _ = state.handle(.init(dx: 0, phase: .ended, time: 0.050), index: 0, count: 4, pitch: 180)
    let momentum = state.handle(.init(dx: -200, momentum: true, time: 0.060), index: 1, count: 4, pitch: 180)
    #expect(momentum == .ignored)
}

@Test @MainActor
func trackpadRubberBandsBothBoundariesAndSpringsBack() {
    let expected = 255 * (1 - 1 / (0.15 * 200 / 255 + 1))
    for (index, delta) in [(0, 400.0), (2, -400.0)] {
        var state = SpaceScrollState()
        let sign = delta < 0 ? -1.0 : 1.0
        let follow = state.handle(.init(dx: delta, phase: .began, time: 0), index: index, count: 3, pitch: 180)
        let release = state.handle(.init(dx: 0, phase: .ended, time: 0.050), index: index, count: 3, pitch: 180)
        #expect(follow == .follow(sign * expected))
        #expect(release == .settle(index: index, offset: sign * expected, switched: false))
    }
}

@Test @MainActor
func cancelledTrackpadGestureReturnsWithoutSwitching() {
    var state = SpaceScrollState()
    _ = state.handle(.init(dx: -20, phase: .began, time: 0), index: 1, count: 3, pitch: 180)
    let release = state.handle(.init(dx: 0, phase: .cancelled, time: 0.010), index: 1, count: 3, pitch: 180)
    #expect(release == .settle(index: 1, offset: -10, switched: false))
}

@Test @MainActor
func wheelSwitchUsesTheExistingSpacePathAndPreservesItsPause() {
    let spaces = (0..<3).map { SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: spaces))
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -2, wheel3: 0)!
    let event = NSEvent(cgEvent: cg)!
    sidebar.scrollWheel(with: event)
    #expect(sidebar.spaceShown == 1)
    sidebar.scrollWheel(with: event)
    #expect(sidebar.spaceShown == 1)
    sidebar.showSpace(at: 0)
    sidebar.scrollWheel(with: event)
    #expect(sidebar.spaceShown == 1)
}

@MainActor
private func scrollDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + scrollDescendants($0) }
}

@MainActor
private func trackpadEvent(dx: Int32, phase: CGScrollPhase?, momentum: Bool = false, time: Double) -> NSEvent {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum ? 1 : 0)
    cg.timestamp = UInt64(time * 1_000_000_000)
    return NSEvent(cgEvent: cg)!
}

@Test @MainActor
func trackpadRoutesThroughTheRowScrollViewAndAnimatesNeighborPages() throws {
    let spaces = (0..<2).map { SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: spaces))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    let scroll = try #require(scrollDescendants(sidebar).compactMap { $0 as? NSScrollView }.first)
    let begin = trackpadEvent(dx: -20, phase: .began, time: 100)
    #expect(begin.phase == .began)
    scroll.scrollWheel(with: begin)
    let preview = try #require(scrollDescendants(sidebar).compactMap { $0 as? SidebarView }.first)
    #expect(preview.spaceShown == 1)
    #expect(preview.superview?.frame.minX == 0)
    #expect(preview.superview?.layer?.transform.m41 == 230)
    scroll.scrollWheel(with: trackpadEvent(dx: 0, phase: .ended, time: 100.050))
    #expect(sidebar.spaceShown == 1)
    let springs = scrollDescendants(sidebar).compactMap { $0.layer?.animation(forKey: "space.scroll") as? CASpringAnimation }
    let spring = try #require(springs.first)
    #expect(abs(spring.stiffness - pow(2 * .pi / 0.250, 2)) < 0.000001)
    let returningPreview = try #require(scrollDescendants(sidebar).compactMap { $0 as? SidebarView }.first)
    let returningPage = try #require(returningPreview.superview)
    let returningSpring = try #require(returningPage.layer?.animation(forKey: "space.scroll") as? CASpringAnimation)
    #expect(returningSpring.fromValue as? Double == -10)
    #expect(returningSpring.toValue as? Double == -240)
    #expect(returningPage.layer?.transform.m41 == -240)
    scroll.scrollWheel(with: trackpadEvent(dx: -200, phase: nil, momentum: true, time: 100.060))
    #expect(sidebar.spaceShown == 1)
}

@Test @MainActor
func longTrackpadDragsChooseTheNearestPageAndBandBeyondTheList() {
    for delta in [-541.0, 541] {
        var state = SpaceScrollState()
        _ = state.handle(.init(dx: delta, phase: .began, time: 0), index: 3, count: 7, pitch: 180)
        let release = state.handle(.init(dx: 0, phase: .ended, time: 0.200), index: 3, count: 7, pitch: 180)
        #expect(release == .settle(index: delta < 0 ? 5 : 1, offset: delta / 2, switched: true))
    }
    var state = SpaceScrollState()
    let follow = state.handle(.init(dx: -800, phase: .began, time: 0), index: 1, count: 3, pitch: 180)
    let offset = -180 + SpaceScrollState.rubberBand(-220)
    let release = state.handle(.init(dx: 0, phase: .ended, time: 0.050), index: 1, count: 3, pitch: 180)
    #expect(follow == .follow(offset))
    #expect(release == .settle(index: 2, offset: offset, switched: true))
}

@Test @MainActor
func halfPageThresholdAndDirectionalReleaseScaleWithPitch() {
    for width in [164.0, 240, 500] {
        let pitch = width
        for sign in [-1.0, 1] {
            for factor in [0.99, 1.0, 1.01] {
                var state = SpaceScrollState()
                let delta = sign * pitch * factor
                _ = state.handle(.init(dx: delta, phase: .began, time: 0), index: 1, count: 3, pitch: pitch)
                let release = state.handle(.init(dx: 0, phase: .ended, time: 0.200), index: 1, count: 3, pitch: pitch)
                let target = factor > 1 ? (sign < 0 ? 2 : 0) : 1
                #expect(release == .settle(index: target, offset: delta / 2, switched: factor > 1))
            }
        }
        for (first, last, target) in [(-0.56, 0.01, 1), (-0.54, -0.01, 2)] {
            var state = SpaceScrollState()
            _ = state.handle(.init(dx: first * pitch, phase: .began, time: 0), index: 1, count: 3, pitch: pitch)
            _ = state.handle(.init(dx: last * pitch, phase: .changed, time: 0.200), index: 1, count: 3, pitch: pitch)
            let release = state.handle(.init(dx: 0, phase: .ended, time: 0.250), index: 1, count: 3, pitch: pitch)
            guard case let .settle(index, offset, switched) = release else { Issue.record("Expected a release decision"); return }
            #expect(index == target)
            #expect(abs(offset + pitch * 0.275) < 0.000001)
            #expect(switched == (target != 1))
        }
    }
}

@Test @MainActor
func neighborPagesUseTheSidebarWidthWithPaddingInBothForms() throws {
    for floating in [false, true] {
        for width: CGFloat in [164, 240, 500] {
            let spaces = (0..<3).map { SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: []) }
            let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: spaces))
            sidebar.showSpace(at: 1)
            let container = SidebarContainerView(sidebar: sidebar, page: NSView())
            container.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
            container.layoutSubtreeIfNeeded()
            if floating { container.toggleSidebar() }
            container.resizeHandle.sidebarWidth = width
            sidebar.scrollWheel(with: trackpadEvent(dx: -20, phase: .began, time: 100))
            let previews = scrollDescendants(sidebar).compactMap { $0 as? SidebarView }
            #expect(previews.count == 2)
            for preview in previews {
                let page = try #require(preview.superview)
                let viewport = try #require(page.superview)
                let current = try #require(viewport.subviews.compactMap { $0 as? NSStackView }.first)
                #expect(viewport.bounds.width == width - 16)
                #expect(current.frame.width == viewport.bounds.width)
                #expect(page.frame.width == viewport.bounds.width)
                #expect(page.frame == viewport.bounds)
                let position = CGFloat(try #require(page.layer?.transform.m41))
                let currentPosition = CGFloat(try #require(current.layer?.transform.m41))
                #expect(abs(position - currentPosition) == width)
                #expect(abs(position - currentPosition) - page.frame.width == 16)
                #expect(!page.frame.offsetBy(dx: position, dy: 0).intersects(current.frame.offsetBy(dx: currentPosition, dy: 0)))
                #expect(page.layer?.masksToBounds == true)
            }
            for sign: Int32 in [-1, 1] {
                for extra: Int32 in [-2, 0, 2] {
                    sidebar.showSpace(at: 1)
                    sidebar.scrollWheel(with: trackpadEvent(dx: sign * (Int32(width) + extra), phase: .began, time: 101))
                    sidebar.scrollWheel(with: trackpadEvent(dx: 0, phase: .ended, time: 101.200))
                    #expect(sidebar.spaceShown == (extra > 0 ? (sign < 0 ? 2 : 0) : 1))
                }
            }
        }
    }
}

@Test @MainActor
func resizingAndResettingCancelTheActiveGestureUntilTheNextBegin() {
    let spaces = (0..<3).map { SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: spaces))
    sidebar.showSpace(at: 1)
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
    container.layoutSubtreeIfNeeded()
    for resetting in [false, true] {
        sidebar.scrollWheel(with: trackpadEvent(dx: -20, phase: .began, time: 100))
        #expect(scrollDescendants(sidebar).contains { $0 is SidebarView })
        if resetting { container.resizeHandle.resetWidth() }
        else { container.resizeHandle.sidebarWidth = 500 }
        #expect(!scrollDescendants(sidebar).contains { $0 is SidebarView })
        sidebar.scrollWheel(with: trackpadEvent(dx: -500, phase: .changed, time: 100.010))
        sidebar.scrollWheel(with: trackpadEvent(dx: 0, phase: .ended, time: 100.050))
        #expect(sidebar.spaceShown == 1)
        sidebar.scrollWheel(with: trackpadEvent(dx: -2, phase: .began, time: 101))
        sidebar.scrollWheel(with: trackpadEvent(dx: 0, phase: .ended, time: 101.050))
        #expect(sidebar.spaceShown == 2)
        sidebar.showSpace(at: 1)
    }
}

@Test @MainActor
func neighborPreviewsKeepLiveContentWithoutLayerImagesAndRefuseFocus() throws {
    _ = NSApplication.shared
    let tab = Row(id: "tab", title: "Neighbor row", url: nil, depth: 0, kind: .tab, unloaded: false)
    let favorite = Row(id: "favorite", title: "Favorite", url: nil, depth: 0, kind: .tab, unloaded: false)
    let spaces = (0..<3).map {
        SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [favorite], pinned: [tab], today: [])
    }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: spaces))
    sidebar.showSpace(at: 1)
    #expect(sidebar.selectRow(id: tab.id))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    sidebar.scrollWheel(with: trackpadEvent(dx: -120, phase: .began, time: 100))
    let previews = scrollDescendants(sidebar).compactMap { $0 as? SidebarView }
    #expect(previews.count == 2)
    for preview in previews {
        let page = try #require(preview.superview)
        let viewport = try #require(page.superview)
        #expect(viewport.isDescendant(of: sidebar))
        #expect(preview.isDescendant(of: viewport))
        #expect(preview.window === window)
        #expect(!preview.isHiddenOrHasHiddenAncestor)
        #expect(preview.hitTest(.zero) == nil)
        let descendants = scrollDescendants(preview)
        let heading = try #require(descendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Space \(preview.spaceShown)" })
        #expect(!heading.isHiddenOrHasHiddenAncestor)
        let row = try #require(descendants.compactMap { $0 as? SidebarRowView }.first)
        #expect(!row.isHiddenOrHasHiddenAncestor)
        #expect(!row.acceptsFirstResponder)
        #expect(!row.canBecomeKeyView)
        #expect(!row.becomeFirstResponder())
        #expect(descendants.contains { $0 is FavoriteTile })
        for control in descendants.compactMap({ $0 as? NSControl }) {
            #expect(control.refusesFirstResponder)
        }
        var layers = [try #require(page.layer)]
        while let layer = layers.popLast() {
            #expect(layer.contents == nil)
            layers.append(contentsOf: layer.sublayers ?? [])
        }
    }
}

@Test @MainActor
func neighborPreviewsContributeNothingToTheWindowAccessibilityTree() throws {
    _ = NSApplication.shared
    let tab = Row(id: "tab", title: "Current tab", url: "https://example.com", depth: 0, kind: .tab, unloaded: false)
    let spaces = (0..<3).map { SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: $0 == 1 ? [tab] : [], today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: spaces))
    sidebar.showSpace(at: 1)
    #expect(sidebar.selectRow(id: tab.id))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    func descendants(_ element: NSAccessibilityProtocol) -> [NSAccessibilityProtocol] {
        let children = NSAccessibility.unignoredChildren(from: element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
        return children + children.flatMap { descendants($0) }
    }
    func view(_ element: NSAccessibilityProtocol) -> NSView? {
        (element as? NSView) ?? (element as? NSCell)?.controlView
    }
    let before = descendants(window)
    #expect(before.filter { view($0)?.accessibilityLabel() == "Selected tab host" }.count == 1)
    let buttons = before.filter { $0.accessibilityRole() == .button }
    #expect(buttons.count == spaces.count + 1)
    sidebar.scrollWheel(with: trackpadEvent(dx: -20, phase: .began, time: 100))
    let previews = scrollDescendants(sidebar).compactMap { $0 as? SidebarView }
    #expect(previews.count == 2)
    let during = descendants(window)
    #expect(during.filter { view($0)?.accessibilityLabel() == "Selected tab host" }.count == 1)
    #expect(during.filter { $0.accessibilityRole() == .button }.count == buttons.count)
    for element in during {
        guard let view = view(element) else { continue }
        #expect(!previews.contains { view === $0 || view.isDescendant(of: $0) })
    }
}

@MainActor
private func scrollTestWindow(spaces: Int = 3) -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let snapshot = WorkspaceSnapshot(selectedId: nil, spaces: (0..<spaces).map {
        SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil,
                      favorites: [Row(id: "favorite-\($0)", title: "Favorite", url: nil, depth: 0, kind: .tab, unloaded: false)],
                      pinned: [Row(id: "tab-\($0)", title: "Tab \($0)", url: nil, depth: 0, kind: .tab, unloaded: false)], today: [])
    })
    let sidebar = SidebarView(snapshot: snapshot)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return (window, sidebar)
}

private func blockScrollCleanup(for duration: TimeInterval) {
    Thread.sleep(forTimeInterval: duration)
}

@MainActor
private final class ScrollCleanupProbe: NSView {
    var onRemoval: (() -> Void)?
    private var attached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attached = true }
        else if attached { attached = false; onRemoval?() }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func outgoingPageStaysOutsideViewportWhileSettleCleanupIsDelayed() async throws {
    let (window, sidebar) = scrollTestWindow(spaces: 2)
    defer { window.orderOut(nil); window.contentView = nil }
    let scroll = try #require(scrollDescendants(sidebar).compactMap { $0 as? NSScrollView }.first)
    scroll.scrollWheel(with: trackpadEvent(dx: -360, phase: .began, time: 100))
    scroll.scrollWheel(with: trackpadEvent(dx: 0, phase: .ended, time: 100.020))
    window.displayIfNeeded()
    CATransaction.flush()
    let outgoing = try #require(scrollDescendants(sidebar).compactMap { $0 as? SidebarView }.first)
    let page = try #require(outgoing.superview)
    let (removals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let probe = ScrollCleanupProbe()
    probe.onRemoval = { continuation.yield(()); continuation.finish() }
    page.addSubview(probe)
    page.setFrameOrigin(NSPoint(x: 1, y: 0))
    page.setFrameOrigin(.zero)
    window.display()
    CATransaction.flush()
    #expect(page.layer?.transform.m41 == 0)
    let spring = try #require(page.layer?.animation(forKey: "space.scroll") as? CASpringAnimation)
    blockScrollCleanup(for: spring.duration * 1.25)
    window.displayIfNeeded()
    CATransaction.flush()
    #expect(page.superview != nil)
    #expect(try #require(page.layer?.presentation()).transform.m41 <= -224)
    var iterator = removals.makeAsyncIterator()
    let removed: Void? = await iterator.next()
    #expect(removed != nil)
    #expect(!scrollDescendants(sidebar).contains { $0 is SidebarView })
    #expect(sidebar.spaceShown == 1)
}

@Test @MainActor
func followPositionsSurviveWindowLayerTreeUpdates() async throws {
    let (window, sidebar) = scrollTestWindow()
    defer { window.orderOut(nil); window.contentView = nil }
    sidebar.showSpace(at: 1)
    sidebar.scrollWheel(with: trackpadEvent(dx: -80, phase: .began, time: 100))
    sidebar.layoutSubtreeIfNeeded()
    window.display()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(20))
    let previews = scrollDescendants(sidebar).compactMap { $0 as? SidebarView }
    #expect(previews.count == 2)
    for preview in previews {
        let page = try #require(preview.superview)
        let expected = CGFloat(preview.spaceShown - sidebar.spaceShown) * 240 - 40
        #expect(page.layer?.transform.m41 == expected)
        #expect(try #require(page.layer?.presentation()).transform.m41 == expected)
        let viewport = try #require(page.superview)
        let current = try #require(viewport.subviews.compactMap { $0 as? NSStackView }.first)
        #expect(current.layer?.transform.m41 == -40)
        #expect(try #require(current.layer?.presentation()).transform.m41 == -40)
    }
}

@Test @MainActor
func wheelSlidesChainAndTrackpadTakesOverThePresentedOffset() {
    var state = SpaceScrollState()
    let first = state.handle(.init(dx: -2, time: 100), index: 0, count: 3, pitch: 240)
    #expect(first == .settle(index: 1, offset: 0, switched: true))
    let paused = state.handle(.init(dx: -2, time: 100.249), index: 1, count: 3, pitch: 240, presentationOffset: 70)
    #expect(paused == .ignored)
    let chained = state.handle(.init(dx: -2, time: 100.250), index: 1, count: 3, pitch: 240, presentationOffset: 64)
    #expect(chained == .settle(index: 2, offset: 64, switched: true))
    let takeover = state.handle(.init(dx: -20, phase: .began, time: 100.260), index: 2, count: 3, pitch: 240, presentationOffset: 304)
    #expect(takeover == .follow(294))
    let continued = state.handle(.init(dx: -20, phase: .changed, time: 100.280), index: 2, count: 3, pitch: 240, presentationOffset: 0)
    #expect(continued == .follow(284))
}

@Test @MainActor
func wheelDoesNotAnimatePastTheEndsOrRestartThePause() {
    var state = SpaceScrollState()
    #expect(state.handle(.init(dx: 2, time: 100), index: 0, count: 3, pitch: 240) == .ignored)
    #expect(state.handle(.init(dx: -2, time: 100.100), index: 2, count: 3, pitch: 240, presentationOffset: 20) == .ignored)
    #expect(state.handle(.init(dx: 2, time: 100.200), index: 2, count: 3, pitch: 240, presentationOffset: 20) == .settle(index: 1, offset: 20, switched: true))
}

@MainActor
private func currentScrollColumn(_ sidebar: SidebarView) throws -> NSView {
    let header = try #require(scrollDescendants(sidebar).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Space \(sidebar.spaceShown)" })
    return try #require(header.superview?.superview)
}

@MainActor
private func installPresentedOffset(_ offset: CGFloat, on view: NSView) async throws {
    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = offset
    animation.toValue = offset
    animation.duration = 60
    view.layer?.transform = CATransform3DIdentity
    view.layer?.add(animation, forKey: "space.scroll")
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(20))
    #expect(try #require(view.layer?.presentation()).transform.m41 == offset)
    #expect(view.layer?.transform.m41 == 0)
}

@Test @MainActor
func wheelViewSlidesAndChainsFromPresentationRatherThanModel() async throws {
    let (window, sidebar) = scrollTestWindow()
    defer { window.orderOut(nil); window.contentView = nil }
    sidebar.scrollWheel(with: trackpadEvent(dx: -2, phase: nil, time: 100))
    #expect(sidebar.spaceShown == 1)
    let current = try currentScrollColumn(sidebar)
    let first = try #require(current.layer?.animation(forKey: "space.scroll") as? CASpringAnimation)
    #expect(first.fromValue as? Double == 240)
    #expect(first.toValue as? Double == 0)
    #expect(abs(first.stiffness - pow(2 * .pi / SidebarMetrics.spaceSwitchResponse, 2)) < 0.000001)
    try await installPresentedOffset(64, on: current)
    sidebar.scrollWheel(with: trackpadEvent(dx: -2, phase: nil, time: 100.250))
    #expect(sidebar.spaceShown == 2)
    let chained = try #require(try currentScrollColumn(sidebar).layer?.animation(forKey: "space.scroll") as? CASpringAnimation)
    #expect(chained.fromValue as? Double == 304)
    #expect(chained.toValue as? Double == 0)
}

@Test @MainActor
func trackpadViewTakesOverAWheelSlideAtItsPresentedOffset() async throws {
    let (window, sidebar) = scrollTestWindow()
    defer { window.orderOut(nil); window.contentView = nil }
    sidebar.scrollWheel(with: trackpadEvent(dx: -2, phase: nil, time: 100))
    let current = try currentScrollColumn(sidebar)
    window.displayIfNeeded()
    try await installPresentedOffset(64, on: current)
    sidebar.scrollWheel(with: trackpadEvent(dx: -20, phase: .began, time: 100.050))
    let followed = try currentScrollColumn(sidebar)
    #expect(followed.layer?.transform.m41 == 54)
    #expect(followed.layer?.animation(forKey: "space.scroll") == nil)
    #expect(sidebar.spaceShown == 1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(followed.layer?.transform.m41 == 54)
    #expect(scrollDescendants(sidebar).contains { $0 is SidebarView })
}

@Test @MainActor
func zeroDeltaGestureBeginsTakeOverAtTheFirstHorizontalMotion() {
    var state = SpaceScrollState()
    #expect(state.handle(.init(dx: 0, phase: .began, time: 100), index: 1, count: 3,
                         pitch: 240, presentationOffset: 100) == .vertical)
    #expect(state.handle(.init(dx: -20, phase: .changed, time: 100.020), index: 1, count: 3,
                         pitch: 240, presentationOffset: 64) == .follow(54))
}

@Test @MainActor
func trackpadTakeoverDoesNotRubberBandThePresentedOffsetTwice() {
    for (index, offset) in [(0, 30.0), (2, -30.0)] {
        var state = SpaceScrollState()
        let action = state.handle(.init(dx: 0.000001, phase: .began, time: 100), index: index, count: 3,
                                  pitch: 240, presentationOffset: offset)
        guard case .follow(let position) = action else { Issue.record("Expected a follow"); continue }
        #expect(abs(position - offset) < 0.000001)
    }
}
