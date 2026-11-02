import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func pullReleaseRequiresFollowedThresholdRegardlessOfVelocity() {
    for excess in [1.0, 164, 165, 180] {
        for delay in [0.01, 0.2] {
            var state = SpaceScrollState()
            _ = state.handle(.init(dx: -2 * excess, phase: .began, time: 0), index: 2, count: 3, pitch: 240)
            let release = state.handle(.init(dx: 0, phase: .ended, time: delay), index: 2, count: 3, pitch: 240)
            #expect(release == .settle(index: excess >= 165 ? 3 : 2, offset: SpaceScrollState.rubberBand(-excess), switched: excess >= 165))
        }
    }
}

@MainActor
private func pullDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + pullDescendants($0) }
}

@MainActor
private func pullEvent(_ dx: Int32, _ phase: CGScrollPhase?, _ time: Double) -> NSEvent {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: phase == nil ? .line : .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
    cg.timestamp = UInt64(time * 1_000_000_000)
    return NSEvent(cgEvent: cg)!
}

@MainActor
private func pullWindow() -> (NSWindow, SidebarView) {
    _ = NSApplication.shared
    let spaces = (0..<3).map { SpaceSnapshot(profileName: "Default", id: "s\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: [], today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s2", selectedId: nil, spaces: spaces))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return (window, sidebar)
}

@Test @MainActor
func pullHasNoCreationNeighborAndReleaseOpensWithoutSlide() throws {
    let (window, sidebar) = pullWindow()
    defer { window.contentView = nil }
    sidebar.scrollWheel(with: pullEvent(-330, .began, 100))
    #expect(!pullDescendants(sidebar).contains { $0 is CreateSpaceView })
    #expect(!sidebar.createSpaceOpen)
    sidebar.scrollWheel(with: pullEvent(0, .ended, 100.2))
    let creation = try #require(pullDescendants(sidebar).compactMap { $0 as? CreateSpaceView }.first)
    #expect(sidebar.createSpaceOpen && sidebar.spaceShown == 2)
    #expect(creation.layer?.animation(forKey: "space.scroll") == nil)
    #expect(creation.layer?.transform.m41 == 0)
    #expect(!window.isVisible)
}

@Test @MainActor
func pullIndicatorGeometryColorsAndAccessibility() throws {
    for floating in [false, true] {
        let (window, sidebar) = pullWindow()
        let container = SidebarContainerView(sidebar: sidebar, page: NSView())
        window.contentView = container
        defer { window.contentView = nil }
        window.setContentSize(NSSize(width: 1000, height: 720))
        if floating { container.toggleSidebar() }
        container.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()
        let panel = try #require(sidebar.superview)
        let view = try #require(sidebar.subviews.compactMap { $0 as? SpacePullIndicator }.first)
        #expect(container.sidebarState == (floating ? "floating" : "docked"))
        #expect(panel.frame.minX == (floating ? 5 : 0))
        #expect(panel.frame.minY == (floating ? 5 : 0))
        #expect(panel.layer?.borderWidth == (floating ? 1 : 0))
        #expect(view.frame == sidebar.bounds)
        #expect(view.layer?.masksToBounds == true)
        for (excess, leftFromEdge) in [(0.0, 0.0), (40, -16), (105, -42), (120, -42)] {
            view.update(excess: excess)
            let center = view.convert(view.circle.position, to: sidebar)
            #expect(abs(center.x - 15 - sidebar.bounds.maxX - CGFloat(leftFromEdge)) < 0.001)
            #expect(center.y == sidebar.bounds.midY)
            if excess >= 105 {
                #expect(abs(sidebar.bounds.maxX - center.x - 27) < 0.001)
                let panelCenter = view.convert(view.ring.position, to: panel)
                let ringBounds = NSRect(x: panelCenter.x - 18, y: panelCenter.y - 18, width: 36, height: 36)
                let border = panel.layer?.borderWidth ?? 0
                let interior = panel.bounds.insetBy(dx: border, dy: border)
                #expect(interior.contains(ringBounds))
            }
        }
        #expect(!window.isVisible)
    }
    let view = SpacePullIndicator(frame: NSRect(x: 0, y: 0, width: 240, height: 720))
    for (excess, fraction) in [(75.0, 0.0), (118.5, 0.5), (162, 1)] {
        view.update(excess: excess)
        #expect(abs(view.ring.strokeEnd - CGFloat(fraction)) < 0.001)
    }
    for excess in [164.0, 165, 164] {
        view.update(excess: excess)
        #expect(view.circle.fillColor == (excess == 165 ? NSColor.white : NSColor.controlAccentColor).cgColor)
        #expect(view.plus.strokeColor == (excess == 165 ? NSColor.controlAccentColor : NSColor.white).cgColor)
    }
    #expect(!view.isAccessibilityElement())
    #expect(view.isAccessibilityHidden())
    #expect(view.accessibilityChildren()?.isEmpty != false)
    #expect(view.hitTest(.zero) == nil)
}

@Test @MainActor
func wheelPullOpensCreationIgnoresWheelAndPreservesPause() throws {
    let (window, sidebar) = pullWindow()
    defer { window.contentView = nil }
    var now = 0.0
    sidebar.pullClock = { now }
    var switches = 0
    sidebar.onShowSpace = { _ in switches += 1 }
    sidebar.scrollWheel(with: pullEvent(-2, nil, 100))
    #expect(!sidebar.createSpaceOpen)
    let indicator = try #require(sidebar.subviews.compactMap { $0 as? SpacePullIndicator }.first)
    now = 0.1
    sidebar.stepPull()
    let sample = switchPullSample(at: now)
    #expect(abs(indicator.excess - sample.excess) < 0.000001)
    #expect(!sidebar.createSpaceOpen)
    sidebar.scrollWheel(with: pullEvent(20, nil, 101))
    #expect(abs(indicator.excess - sample.excess) < 0.000001 && !sidebar.createSpaceOpen)
    now = sample.duration
    sidebar.stepPull()
    #expect(sidebar.createSpaceOpen)
    #expect(sidebar.spaceShown == 2 && switches == 0)
    sidebar.scrollWheel(with: pullEvent(20, nil, 100.249))
    #expect(sidebar.createSpaceOpen)
    sidebar.scrollWheel(with: pullEvent(20, nil, 100.250))
    #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 2)
    #expect(!window.isVisible)
}

@Test @MainActor
func trackpadTakesOverWheelPullAtCurrentOffset() throws {
    let (window, sidebar) = pullWindow()
    defer { window.contentView = nil }
    var now = 0.0
    sidebar.pullClock = { now }
    sidebar.scrollWheel(with: pullEvent(-2, nil, 100))
    let indicator = try #require(sidebar.subviews.compactMap { $0 as? SpacePullIndicator }.first)
    now = 0.1
    sidebar.stepPull()
    let sample = switchPullSample(at: now)
    #expect(abs(indicator.excess - sample.excess) < 0.000001)
    sidebar.scrollWheel(with: pullEvent(-2, .began, 100.1))
    #expect(abs(indicator.excess - (sample.excess + 1)) < 0.000001)
    now = sample.duration
    sidebar.stepPull()
    #expect(!sidebar.createSpaceOpen)
    #expect(abs(indicator.excess - (sample.excess + 1)) < 0.000001)
    sidebar.scrollWheel(with: pullEvent(0, .cancelled, 100.2))
    now += 1
    sidebar.stepPull()
    #expect(indicator.isHidden)
    #expect(!sidebar.createSpaceOpen && sidebar.spaceShown == 2)
}

@MainActor
private func switchPullSample(at time: Double) -> (excess: Double, duration: Double) {
    let omega = 2 * Double.pi / SidebarMetrics.spaceSwitchResponse
    let damping = Double(SidebarMetrics.spaceSwitchDamping)
    let decay = damping * omega
    let frequency = omega * sqrt(1 - damping * damping)
    let progress = 1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
    let spring = CASpringAnimation()
    spring.mass = 1
    spring.stiffness = omega * omega
    spring.damping = 2 * decay
    return (165 * progress, spring.settlingDuration)
}

@Test @MainActor
func wheelPullRespectsPauseFromPreviousSpaceSwitch() {
    let (window, sidebar) = pullWindow()
    defer { window.contentView = nil }
    sidebar.showSpace(at: 1)
    sidebar.scrollWheel(with: pullEvent(-2, nil, 100))
    #expect(sidebar.spaceShown == 2)
    sidebar.scrollWheel(with: pullEvent(-2, nil, 100.249))
    #expect(!sidebar.createSpaceOpen)
    #expect(sidebar.subviews.compactMap { $0 as? SpacePullIndicator }.first?.isHidden == true)
}

@Test @MainActor
func pullCapturesStayOffScreenAndNeverShowCreationBeforeRelease() async throws {
    let (window, sidebar) = pullWindow()
    defer { window.contentView = nil }
    let indicator = try #require(sidebar.subviews.compactMap { $0 as? SpacePullIndicator }.first)
    let directory = ProcessInfo.processInfo.environment["ARARAT_PULL_CAPTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func capture(_ name: String) throws {
        guard let directory else { return }
        window.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 720,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(sidebar.bounds)
        sidebar.layer?.render(in: context)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        #expect(!window.isVisible)
    }
    var previous = 0
    for excess in [60, 120, 165] {
        sidebar.scrollWheel(with: pullEvent(Int32(-2 * (excess - previous)), previous == 0 ? .began : .changed, 100))
        #expect(abs(indicator.excess - Double(excess)) < 0.000001)
        #expect(!pullDescendants(sidebar).contains { $0 is CreateSpaceView })
        #expect(!sidebar.createSpaceOpen)
        try capture("pull-\(excess)")
        previous = excess
    }
    sidebar.scrollWheel(with: pullEvent(0, .ended, 100.2))
    #expect(sidebar.createSpaceOpen)
    try capture("release-0")
    if !indicator.isHidden {
        let initial = indicator.circle.position.x
        try await waitUntil { indicator.circle.position.x > initial || indicator.isHidden }
        try capture("release-exiting")
    }
    try await waitUntil { indicator.isHidden }
    #expect(indicator.layer?.isHidden == true)
    try capture("release-complete")
    #expect(sidebar.createSpaceOpen)
}
