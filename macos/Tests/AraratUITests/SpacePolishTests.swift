import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func polishViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(polishViews) }

@MainActor
private func polishMouse(_ type: NSEvent.EventType, _ view: NSView, inside: Bool = true) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: inside ? 5 : -5, y: 5), to: nil),
                      modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}

@MainActor
private func polishScroll(_ dx: Int32, _ phase: CGScrollPhase?, _ time: Double, dy: Int32 = 0) -> NSEvent {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: phase == nil ? .line : .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
    cg.timestamp = UInt64(time * 1_000_000_000)
    return NSEvent(cgEvent: cg)!
}

@MainActor
private func polishWindow(count: Int = 3, floating: Bool = false, rowCount: Int = 1) -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let spaces = (0..<count).map { index in
        let row = Row(id: "r\(index)", title: "Row \(index)", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
        let pins = (0..<rowCount).map { Row(id: "p\(index)-\($0)", title: "Pin \(index)-\($0)", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) }
        return SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "s\(index)", title: "Space \(index)", icon: nil, look: nil,
                             favorites: [row], pinned: pins, today: [])
    }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s0", selectedId: nil, spaces: spaces))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = container
    if floating { container.toggleSidebar() }
    container.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return (window, sidebar)
}

@Test @MainActor
func tooltipCapturePreservesAccessibilityHelp() {
    let tooltip = SidebarTooltip()
    for capture in [true, false] {
        let button = NSButton()
        button.toolTip = "Delete Permanently"
        if capture { tooltip.capture(in: button) } else { _ = tooltip.target(at: button) }
        #expect(button.toolTip == nil)
        #expect(button.accessibilityHelp() == "Delete Permanently")
        button.setAccessibilityHelp("Existing help")
        button.toolTip = "New tooltip"
        tooltip.capture(in: button)
        #expect(button.accessibilityHelp() == "Existing help")
    }
}

@Test @MainActor
func nonKeyRowReleaseUsesEventCoordinates() throws {
    let (window, sidebar) = polishWindow()
    defer { window.contentView = nil }
    let row = try #require(polishViews(sidebar).compactMap { $0 as? SidebarRowView }.first)
    row.pointerLocation = { nil }
    var selections = 0
    sidebar.onSelect = { _ in selections += 1 }
    #expect(!window.isKeyWindow)
    row.mouseDown(with: polishMouse(.leftMouseDown, row))
    row.mouseDragged(with: polishMouse(.leftMouseDragged, row))
    row.mouseUp(with: polishMouse(.leftMouseUp, row))
    #expect(selections == 1)
    row.mouseDown(with: polishMouse(.leftMouseDown, row))
    row.mouseUp(with: polishMouse(.leftMouseUp, row, inside: false))
    #expect(selections == 1)
}

@Test @MainActor
func dockWidthsTouchAndKeepTheSelectedCell() throws {
    for count in [1, 3, 12, 16, 22] {
        let (window, sidebar) = polishWindow(count: count)
        defer { window.contentView = nil }
        let dock = try #require(polishViews(sidebar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Space 0" }?.superview)
        dock.layoutSubtreeIfNeeded()
        let available = sidebar.bounds.width - 83
        #expect(dock.bounds.width == available)
        let widths = SpaceDockView.cellWidths(count: count, selected: 0, width: available)
        #expect(dock.subviews.map(\.frame.width) == widths)
        #expect(widths.allSatisfy { $0 <= 34 && $0 * 2 == floor($0 * 2) })
        #expect(widths.reduce(0, +) <= dock.bounds.width)
        if dock.bounds.width / CGFloat(count) < 22 { #expect(widths[0] == 22) }
        let last = try #require(dock.subviews.last)
        for x in stride(from: (dock.subviews.first?.frame.minX ?? 0) + 0.25, to: last.frame.maxX, by: 0.5) {
            #expect(dock.hitTest(dock.convert(NSPoint(x: x, y: 5), to: dock.superview)) is SpaceDockButton)
        }
        #expect(!polishViews(sidebar).contains { ($0 as? NSScrollView)?.documentView === dock })
        if count == 22 {
            sidebar.showSpace(at: count - 1)
            dock.layoutSubtreeIfNeeded()
            #expect(dock.subviews.map(\.frame.width) == SpaceDockView.cellWidths(count: count, selected: count - 1, width: available))
            #expect(dock.subviews.last?.frame.width == 22)
            #expect(dock.subviews.first?.frame.width == 6)
        }
    }
}

@Test @MainActor
func latestDockClickCancelsSwipeAndWheelAndAcceptsShakyClick() async throws {
    for wheel in [false, true] {
        let (window, sidebar) = polishWindow()
        defer { window.contentView = nil }
        sidebar.scrollWheel(with: polishScroll(wheel ? -5 : -80, wheel ? nil : .began, 100))
        if !wheel { sidebar.scrollWheel(with: polishScroll(0, .ended, 100.02)) }
        let dock = try #require(polishViews(sidebar).compactMap { $0 as? SpaceDockView }.last)
        let button = try #require(dock.subviews.last as? SpaceDockButton)
        #expect(button.bounds.contains(button.convert(polishMouse(.leftMouseUp, button).locationInWindow, from: nil)), "bounds \(button.bounds), dock \(dock.frame)")
        #expect(!button.mouseDownCanMoveWindow)
        button.mouseDown(with: polishMouse(.leftMouseDown, button))
        button.mouseDragged(with: polishMouse(.leftMouseDragged, button))
        button.mouseUp(with: polishMouse(.leftMouseUp, button))
        #expect(sidebar.spaceShown == 2)
        #expect(polishViews(sidebar).allSatisfy { $0.layer?.animation(forKey: "space.scroll") == nil })
        let other = try #require(dock.subviews.first as? SpaceDockButton)
        other.mouseDown(with: polishMouse(.leftMouseDown, other))
        other.mouseUp(with: polishMouse(.leftMouseUp, other, inside: false))
        for _ in 0..<4 { await Task.yield() }
        #expect(sidebar.spaceShown == 2)
        #expect(!window.isVisible)
    }
}

@MainActor
private func polishCounts(_ sidebar: SidebarView) -> [Int] {
    let views = polishViews(sidebar)
    func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }
    let backing = sidebar.layer.map(layers) ?? []
    let timers = Mirror(reflecting: sidebar).children.compactMap { $0.value as? Timer }.filter(\.isValid)
    return [views.count, backing.count, views.reduce(0) { $0 + $1.trackingAreas.count },
            backing.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }, timers.count]
}

@MainActor
private func finishPolishScroll(_ sidebar: SidebarView, switching: () -> Void = {}) async throws {
    CATransaction.begin()
    switching()
    CATransaction.setDisableActions(true)
    for view in polishViews(sidebar) { view.layer?.removeAnimation(forKey: "space.scroll") }
    CATransaction.commit()
    CATransaction.flush()
    try await waitUntil { !polishViews(sidebar).contains { $0 is SidebarView && $0 !== sidebar } }
}

@Test @MainActor
func fiftySwitchesKeepResourcesBoundedAndFloatingInputWorking() async throws {
    for floating in [false, true] {
        let (window, sidebar) = polishWindow(count: 2, floating: floating)
        defer { window.contentView = nil }
        window.setContentSize(NSSize(width: 1000, height: 300))
        window.contentView?.layoutSubtreeIfNeeded()
        var baseline: [Int] = []
        for iteration in 0..<50 {
            let direction: Int32 = iteration.isMultiple(of: 2) ? -5 : 5
            weak var preview: SidebarView?
            weak var previewList: SidebarScrollView?
            try await finishPolishScroll(sidebar) {
                sidebar.scrollWheel(with: polishScroll(direction, nil, 100 + Double(iteration)))
                preview = polishViews(sidebar).compactMap { $0 as? SidebarView }.first { $0 !== sidebar }
                previewList = preview.flatMap { polishViews($0).compactMap { $0 as? SidebarScrollView }.first }
            }
            #expect(preview == nil && previewList == nil)
            for row in polishViews(sidebar).compactMap({ $0 as? SidebarRowView }) { row.updateTrackingAreas() }
            let counts = polishCounts(sidebar)
            if iteration == 0 { baseline = counts } else { #expect(counts == baseline) }
            #expect(sidebar.spaceShown == (iteration.isMultiple(of: 2) ? 1 : 0))
        }
        sidebar.scrollWheel(with: polishScroll(-40, .began, 200))
        sidebar.scrollWheel(with: polishScroll(0, .ended, 200.02))
        #expect(sidebar.spaceShown == 1)
        try await finishPolishScroll(sidebar)
        for row in polishViews(sidebar).compactMap({ $0 as? SidebarRowView }) { row.updateTrackingAreas() }
        #expect(polishCounts(sidebar) == baseline)
        #expect(!window.isVisible)
    }
}

@Test @MainActor
func verticalGestureImmediatelyAfterSpaceSwipeScrollsTheList() throws {
    _ = NSApplication.shared
    let rows = (0..<40).map { Row(id: "r\($0)", title: "Row \($0)", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) }
    let spaces = (0..<2).map { SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "s\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: [], today: rows) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s0", selectedId: nil, spaces: spaces))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 500), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    let list = try #require(polishViews(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    list.scrollWheel(with: polishScroll(-40, .began, 100))
    list.scrollWheel(with: polishScroll(0, .ended, 100.02))
    #expect(sidebar.spaceShown == 1)
    #expect(list.onScroll?(polishScroll(0, .began, 100.03, dy: -30)) == false)
    #expect(list.onScroll?(polishScroll(0, .changed, 100.04, dy: -30)) == false)
}

@MainActor
private func polishPixels(_ layer: CALayer) throws -> [UInt8] {
    let width = Int(layer.bounds.width), height = Int(layer.bounds.height)
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    layer.render(in: context)
    return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
}

@Test @MainActor
func sampledSpaceFramesKeepEachPagesHeadingPinsAndRowsTogether() async throws {
    let (window, sidebar) = polishWindow(rowCount: 24)
    defer { window.contentView = nil }
    let viewport = try #require(polishViews(sidebar).first { view in
        view.subviews.contains { $0 is NSStackView } && view.layer?.masksToBounds == true && view !== sidebar
    })
    let current = try #require(viewport.subviews.compactMap { $0 as? NSStackView }.first)
    let list = try #require(polishViews(current).compactMap { $0 as? SidebarScrollView }.first)
    var references: [Int: [UInt8]] = [:]
    for index in 0..<3 {
        sidebar.showSpace(at: index)
        list.move(to: index == 0 ? 120 : 0)
        window.displayIfNeeded()
        CATransaction.flush()
        references[index] = try polishPixels(try #require(current.layer))
    }
    let width = Int(current.bounds.width), height = Int(current.bounds.height)
    let referenceImages = try references.mapValues { pixels in
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    sidebar.showSpace(at: 0)
    for gesture in 0..<3 {
        let eventTime = 100 + Double(gesture)
        if gesture == 2 {
            sidebar.layer?.speed = 0
            sidebar.layer?.timeOffset = 1
            sidebar.scrollWheel(with: polishScroll(-5, nil, eventTime))
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = 64
            animation.toValue = 64
            animation.duration = 60
            current.layer?.add(animation, forKey: "space.scroll")
            CATransaction.flush()
            try await waitUntil { current.layer?.presentation()?.transform.m41 == 64 }
            #expect(current.layer?.transform.m41 == 0)
            sidebar.scrollWheel(with: polishScroll(-40, .began, eventTime + 0.02))
            #expect(current.layer?.transform.m41 == 44)
            #expect(current.layer?.animation(forKey: "space.scroll") == nil)
            sidebar.scrollWheel(with: polishScroll(0, .ended, eventTime + 0.04))
        } else {
            sidebar.scrollWheel(with: polishScroll(-160, .began, eventTime))
            if gesture == 1 { sidebar.scrollWheel(with: polishScroll(80, .changed, eventTime + 0.2)) }
            sidebar.scrollWheel(with: polishScroll(0, .ended, eventTime + (gesture == 1 ? 0.22 : 0.02)))
        }
        window.displayIfNeeded()
        CATransaction.flush()
        let pages: [(NSView, Int)] = [(current, sidebar.spaceShown)] + viewport.subviews.compactMap { page in
            guard let preview = page.subviews.first as? SidebarView else { return nil }
            return (page, preview.spaceShown)
        }
        let saved = try pages.map { (page, index) in
            (page, index, try #require(page.layer).transform, page.layer?.animation(forKey: "space.scroll") as? CASpringAnimation)
        }
        for step in stride(from: 0, through: 60, by: 4) {
            let time = Double(step) / 60
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let expected = CALayer()
            expected.bounds = viewport.bounds
            expected.masksToBounds = true
            expected.isGeometryFlipped = viewport.layer?.isGeometryFlipped ?? false
            for (page, index, transform, spring) in saved {
                let from = (spring?.fromValue as? Double) ?? transform.m41
                let to = (spring?.toValue as? Double) ?? transform.m41
                let omega = spring.map { sqrt($0.stiffness) } ?? 1
                let decay = (spring?.damping ?? 0) / 2
                let frequency = sqrt(max(0.0001, omega * omega - decay * decay))
                let remaining = exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
                let position = (to + (from - to) * remaining).rounded()
                page.layer?.transform = CATransform3DMakeTranslation(position, 0, 0)
                let image = CALayer()
                image.frame = page.frame
                image.contents = referenceImages[index]
                image.transform = CATransform3DMakeTranslation(position, 0, 0)
                expected.addSublayer(image)
            }
            let actual = try polishPixels(try #require(viewport.layer))
            let reference = try polishPixels(expected)
            CATransaction.commit()
            let matches = actual == reference
            #expect(matches, "sample \(step), gesture \(gesture)")
            guard matches else { return }
        }
        for (page, _, transform, _) in saved { page.layer?.transform = transform }
        try await finishPolishScroll(sidebar)
        let landed = try polishPixels(try #require(viewport.layer))
        let matches = landed == references[sidebar.spaceShown]
        #expect(matches, "landed gesture \(gesture), space \(sidebar.spaceShown)")
        #expect(viewport.subviews.count == 1)
        #expect(current.layer?.transform.m41 == 0)
    }
    #expect(!window.isVisible)
}

@Test @MainActor
func scrolledPinsKeepTheirPositionWhenLiveAndPreviewPagesExchange() throws {
    _ = NSApplication.shared
    let rows = (0..<40).map { Row(id: "r\($0)", title: "Pin \($0)", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) }
    let spaces = (0..<2).map { SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "s\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: rows, today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s0", selectedId: nil, spaces: spaces))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 500), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    let live = try #require(polishViews(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    live.move(to: 200)
    sidebar.scrollWheel(with: polishScroll(-160, .began, 100))
    let incoming = try #require(polishViews(sidebar).compactMap { $0 as? SidebarView }.first { $0 !== sidebar })
    let incomingList = try #require(polishViews(incoming).compactMap { $0 as? SidebarScrollView }.first)
    let incomingY = incomingList.contentView.bounds.minY
    sidebar.scrollWheel(with: polishScroll(0, .ended, 100.02))
    let outgoing = try #require(polishViews(sidebar).compactMap { $0 as? SidebarView }.first { $0 !== sidebar })
    let outgoingList = try #require(polishViews(outgoing).compactMap { $0 as? SidebarScrollView }.first)
    #expect(outgoingList.contentView.bounds.minY == 200)
    #expect(live.contentView.bounds.minY == incomingY)
}

@Test @MainActor
func spaceSwipeStopsAnEarlierVerticalSelectionReveal() throws {
    let (window, sidebar) = polishWindow(rowCount: 40)
    defer { window.contentView = nil }
    let list = try #require(polishViews(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    var now = 0.0
    list.clock = { now }
    list.reduceMotion = { false }
    #expect(sidebar.selectRow(id: "p0-39"))
    now = 0.1
    list.stepReveal()
    let origin = list.contentView.bounds.minY
    #expect(origin > 0)
    sidebar.scrollWheel(with: polishScroll(-160, .began, 100))
    now = 0.15
    list.stepReveal()
    #expect(list.contentView.bounds.minY == origin)
    sidebar.scrollWheel(with: polishScroll(0, .ended, 100.02))
    let landed = list.contentView.bounds.minY
    now = 1
    list.stepReveal()
    #expect(list.contentView.bounds.minY == landed)
}
