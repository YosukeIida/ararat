import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func floatingFixture() -> (NSWindow, SidebarView, SidebarContainerView, NSView) {
    _ = NSApplication.shared
    let row = Row(id: "tab", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space", selectedId: "tab", spaces: [
        SpaceSnapshot(profileName: "Default", id: "space", title: "Space", icon: nil, look: nil, favorites: [], pinned: [row], today: [])
    ]))
    let page = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: page)
    container.applicationActive = { true }
    container.windowKey = { true }
    container.pressedButtons = { 0 }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [], backing: .buffered, defer: false)
    container.pointerLocation = { NSPoint(x: window.frame.minX + 100, y: window.frame.midY) }
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    container.selectionChanged()
    return (window, sidebar, container, page)
}

@Test @MainActor
func floatingInteractionsReevaluateTheCurrentPointerOnRelease() {
    let (window, sidebar, container, _) = floatingFixture()
    defer { window.contentView = nil }
    var now = 0.0
    var point = NSPoint(x: window.frame.minX, y: window.frame.midY)
    var buttons = 0
    container.clock = { now }
    container.pointerLocation = { point }
    container.pressedButtons = { buttons }
    container.toggleSidebar()
    now = 0.150
    container.processPointer()
    #expect(container.sidebarState == "floating")
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: sidebar.newSpaceMenu)
    point.x = window.frame.maxX + 100
    container.processPointer()
    #expect(container.sidebarState == "floating")
    buttons = 4
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: sidebar.newSpaceMenu)
    #expect(container.sidebarState == "floating")
    buttons = 0
    container.processPointer()
    #expect(container.sidebarState == "hidden")
    point.x = window.frame.minX
    container.processPointer()
    now = 0.300
    container.processPointer()
    #expect(container.sidebarState == "floating")
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: sidebar.newSpaceMenu)
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: sidebar.newSpaceMenu)
    #expect(container.sidebarState == "floating")
    #expect(!window.isVisible)
}

@Test @MainActor
func inactiveHoverCannotReuseTheEarlierDwell() {
    let (window, _, container, _) = floatingFixture()
    defer { window.contentView = nil }
    var now = 0.0
    var active = true
    container.clock = { now }
    container.applicationActive = { active }
    container.pointerLocation = { NSPoint(x: window.frame.minX, y: window.frame.midY) }
    container.toggleSidebar()
    active = false
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    now = 1
    container.processPointer()
    active = true
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    #expect(container.sidebarState == "hidden")
    now = 1.149
    container.processPointer()
    #expect(container.sidebarState == "hidden")
    now = 1.150
    container.processPointer()
    #expect(container.sidebarState == "floating")
}

@Test @MainActor
func floatingAnimationReplacementKeepsTheLatestModelState() throws {
    let (window, _, container, page) = floatingFixture()
    defer { window.contentView = nil }
    let panel = try #require(container.subviews.compactMap { $0 as? NSVisualEffectView }.first)
    var now = 0.0
    var point = NSPoint(x: window.frame.minX, y: window.frame.midY)
    container.clock = { now }
    container.pointerLocation = { point }
    container.toggleSidebar()
    now = 0.150
    container.processPointer()
    point.x = window.frame.maxX + 100
    container.processPointer()
    let hide = try #require(panel.layer?.animation(forKey: "sidebar.position") as? CABasicAnimation)
    point.x = window.frame.minX
    container.processPointer()
    now = 0.300
    container.processPointer()
    #expect(panel.layer?.animation(forKey: "sidebar.position") is CASpringAnimation)
    #expect(hide.delegate == nil)
    #expect(container.sidebarState == "floating")
    #expect(panel.frame.minX == 5)
    container.toggleSidebar()
    #expect(container.sidebarState == "docked")
    #expect(page.frame.minX == 240)
    container.toggleSidebar()
    #expect(container.sidebarState == "hidden")
    container.toggleSidebar()
    panel.layer?.removeAllAnimations()
    page.layer?.removeAllAnimations()
    #expect(container.sidebarState == "docked")
    #expect(panel.frame.minX == 0)
    #expect(page.frame.minX == 240)
}

@Test @MainActor
func dockCellsAreCenteredAndTouchAtSparseAndFullCounts() {
    for count in [3, 22] {
        let dock = SpaceDockView(frame: NSRect(x: 0, y: 0, width: 157, height: 32))
        for _ in 0..<count { dock.addSubview(SpaceDockButton()) }
        dock.layout()
        let total = dock.subviews.reduce(CGFloat.zero) { $0 + $1.frame.width }
        #expect(dock.subviews.first?.frame.minX == (157 - total) / 2)
        #expect(dock.subviews.last?.frame.maxX == (157 + total) / 2)
        for (left, right) in zip(dock.subviews, dock.subviews.dropFirst()) {
            #expect(left.frame.maxX == right.frame.minX)
        }
        if count == 3 { #expect(total == 102) }
        else { #expect(total == 148) }
    }
}

@Test @MainActor
func floatingCornersExposeTheBackdropInsteadOfThePage() throws {
    let (window, _, container, page) = floatingFixture()
    defer { window.contentView = nil }
    container.layer?.backgroundColor = NSColor.red.cgColor
    page.layer?.backgroundColor = NSColor.blue.cgColor
    var now = 0.0
    container.clock = { now }
    container.pointerLocation = { NSPoint(x: window.frame.minX, y: window.frame.midY) }
    container.toggleSidebar()
    now = 0.150
    container.processPointer()
    let panel = try #require(container.subviews.compactMap { $0 as? NSVisualEffectView }.first)
    container.layer?.removeAllAnimations()
    page.layer?.removeAllAnimations()
    panel.layer?.removeAllAnimations()
    window.displayIfNeeded()
    let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
        bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    try #require(container.layer).render(in: context)
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    for point in [NSPoint(x: 244, y: 10), NSPoint(x: 244, y: 589)] {
        let offset = (Int(point.y) * 800 + Int(point.x)) * 4
        #expect(pixels[offset] > 200)
        #expect(pixels[offset + 2] < 50)
    }
    #expect(!window.isVisible)
}


@MainActor
private func maskPoints(_ path: CGPath) -> [CGPoint] {
    var points: [CGPoint] = []
    path.applyWithBlock { element in
        if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
            points.append(element.pointee.points[0])
        }
    }
    return points
}

@Test @MainActor
func floatingPageMaskTracksRevealAndLibraryWidth() throws {
    for widening in [false, true] {
        let (window, sidebar, container, page) = floatingFixture()
        defer { window.contentView = nil }
        container.layer?.backgroundColor = NSColor.red.cgColor
        page.layer?.backgroundColor = NSColor.blue.cgColor
        var now = 0.0
        container.clock = { now }
        container.pointerLocation = { NSPoint(x: window.frame.minX, y: window.frame.midY) }
        container.toggleSidebar()
        now = 0.150
        container.processPointer()
        let panel = try #require(container.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        if widening {
            panel.layer?.removeAllAnimations()
            page.layer?.removeAllAnimations()
            page.layer?.mask?.removeAllAnimations()
            sidebar.setLibraryOpen(true)
        }
        window.displayIfNeeded()
        let position = try #require(panel.layer?.animation(forKey: "sidebar.position") as? CABasicAnimation)
        let bounds = try #require(panel.layer?.animation(forKey: "sidebar.bounds") as? CABasicAnimation)
        let mask = try #require(page.layer?.mask as? CAShapeLayer)
        let animation = mask.animation(forKey: "sidebar.mask") as? CABasicAnimation
        #expect(animation != nil)
        #expect(animation?.duration == position.duration)
        #expect((animation is CASpringAnimation) == (position is CASpringAnimation))
        let fromPosition = try #require(position.fromValue as? NSValue).pointValue
        let toPosition = try #require(position.toValue as? NSValue).pointValue
        let fromBounds = try #require(bounds.fromValue as? NSValue).rectValue
        let toBounds = try #require(bounds.toValue as? NSValue).rectValue
        let modelPath = try #require(mask.path)
        let fromPath = (animation?.fromValue).map { $0 as! CGPath } ?? modelPath
        let toPath = (animation?.toValue).map { $0 as! CGPath } ?? modelPath
        let fromPoints = maskPoints(fromPath), toPoints = maskPoints(toPath)
        #expect(fromPoints.count == 8)
        #expect(toPoints.count == 8)
        guard fromPoints.count == 8 && toPoints.count == 8 else { return }
        for progress: CGFloat in [0, 0.5, 1] {
            let points = zip(fromPoints, toPoints).map { a, b in
                CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
            }
            let path = CGMutablePath()
            for start in [0, 4] {
                path.move(to: points[start])
                for index in (start + 1)..<(start + 4) { path.addLine(to: points[index]) }
                path.closeSubpath()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.layer?.removeAllAnimations()
            page.layer?.removeAllAnimations()
            mask.removeAllAnimations()
            panel.layer?.position = CGPoint(x: fromPosition.x + (toPosition.x - fromPosition.x) * progress,
                                           y: fromPosition.y + (toPosition.y - fromPosition.y) * progress)
            panel.layer?.bounds = CGRect(x: fromBounds.minX, y: fromBounds.minY,
                width: fromBounds.width + (toBounds.width - fromBounds.width) * progress,
                height: fromBounds.height + (toBounds.height - fromBounds.height) * progress)
            mask.path = path
            CATransaction.commit()
            let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            try #require(container.layer).render(in: context)
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let edge = try #require(panel.layer).frame.maxX
            let x = Int(max(page.frame.minX + 2, edge + 2))
            let offset = (300 * 800 + x) * 4
            #expect(pixels[offset] < 50, "widening \(widening), progress \(progress), x \(x)")
            #expect(pixels[offset + 2] > 200)
        }
        #expect(!window.isVisible)
    }
}
