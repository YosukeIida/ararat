import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func windowButtonsUseMeasuredCentresInEitherTitlebarCoordinateSystem() {
    for height: CGFloat in [720, 800, 1200] {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: height))
        for flipped in [false, true] {
            let titlebar: NSView = flipped ? FlippedTitlebar() : NSView()
            titlebar.frame = NSRect(x: 4, y: height - 40, width: 1092, height: 40)
            root.addSubview(titlebar)
            let frames = BrowserWindow.buttonFrames(windowHeight: height)
            #expect(frames.count == 3)
            for (frame, x) in zip(frames, [CGFloat(19.5), 42.5, 65.5]) {
                let local = titlebar.convert(frame, from: root)
                #expect(local.width == 14)
                #expect(local.height == 14)
                #expect(local.midX == x - 4)
                #expect(local.midY == (flipped ? 23.5 : 16.5))
                #expect(root.convert(local, from: titlebar) == frame)
                #expect(height - frame.maxY == 16.5)
                #expect(46 - (height - frame.minY) == 15.5)
            }
            titlebar.removeFromSuperview()
        }
    }
}

private final class FlippedTitlebar: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func measuredButtonsWindow(selected: Bool = false) -> NSWindow {
    _ = NSApplication.shared
    let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space", selectedId: selected ? "tab" : nil, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Space", icon: nil, look: nil, favorites: [], pinned: [], today: [
            Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "tab", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
        ])
    ]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = content.bounds
    container.autoresizingMask = [.width, .height]
    content.addSubview(container)
    window.contentView = content
    container.selectionChanged()
    window.layoutIfNeeded()
    return window
}

@MainActor
private func expectMeasuredButtons(_ window: NSWindow) throws {
    window.layoutIfNeeded()
    for (type, x) in zip([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton], [CGFloat(19.5), 42.5, 65.5]) {
        let button = try #require(window.standardWindowButton(type))
        let parent = try #require(button.superview)
        let frame = parent.convert(button.frame, to: nil)
        #expect(frame.width == 14)
        #expect(frame.height == 14)
        #expect(frame.midX == x)
        #expect(window.frame.height - frame.midY == 23.5)
    }
}

@Test @MainActor
func windowButtonsStayMeasuredAfterEveryNativeRetile() throws {
    let window = measuredButtonsWindow()
    defer { window.contentView = nil }
    try expectMeasuredButtons(window)
    let changes: [(String, () -> Void)] = [
        ("height", { window.setContentSize(NSSize(width: 1100, height: 800)) }),
        ("width", { window.setContentSize(NSSize(width: 1200, height: 800)) }),
        ("title", { window.title = "Selected tab" }),
        ("title visibility", { window.titleVisibility = .visible }),
        ("subtitle", { window.subtitle = "Subtitle" }),
        ("represented URL", { window.representedURL = URL(string: "https://example.com") }),
        ("style off", { window.styleMask.remove(.fullSizeContentView) }),
        ("style on", { window.styleMask.insert(.fullSizeContentView) }),
        ("key", { window.becomeKey() }),
        ("non-key", { window.resignKey() }),
        ("light", { window.appearance = NSAppearance(named: .aqua) }),
        ("dark", { window.appearance = NSAppearance(named: .darkAqua) }),
    ]
    for (name, change) in changes {
        change()
        print("BUTTON RETILE", name)
        try expectMeasuredButtons(window)
    }
}

@Test @MainActor
func sidebarInstallsButtonsOnAnOrdinaryWindow() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    window.contentView = container
    defer { window.contentView = nil }
    #expect(container.hasSidebarLights)
    #expect(container.sidebarCloseButton != nil)
    #expect(container.appKitLightsHidden)
}

@Test @MainActor
func windowButtonHitsCoverTheirFullFramesAndLeaveContentUnobstructed() throws {
    let window = measuredButtonsWindow()
    defer { window.contentView = nil }
    let content = try #require(window.contentView)
    let theme = try #require(content.superview)
    let baseline = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                            styleMask: window.styleMask, backing: .buffered, defer: false)
    baseline.titlebarAppearsTransparent = true
    baseline.titleVisibility = .hidden
    baseline.layoutIfNeeded()
    #expect(window.frame.height - window.contentLayoutRect.maxY == baseline.frame.height - baseline.contentLayoutRect.maxY)
    #expect(content.safeAreaInsets.top == baseline.contentView?.safeAreaInsets.top)
    let lights = try #require((window as? BrowserWindow)?.sidebarLights)
    for button in lights.subviews {
        let parent = try #require(button.superview)
        let frame = parent.convert(button.frame, to: nil)
        for x in [frame.minX + 0.25, frame.midX, frame.maxX - 0.25] {
            for y in [frame.minY + 0.25, frame.midY, frame.maxY - 0.25] {
                let hit = theme.hitTest(NSPoint(x: x, y: y))
                #expect(hit === button || hit?.isDescendant(of: button) == true)
            }
        }
    }
    for x: CGFloat in [100, 200, 300, 800] {
        for top: CGFloat in [28.25, 40, 47, 55.75] {
            let hit = theme.hitTest(NSPoint(x: x, y: window.frame.height - top))
            #expect(hit === content || hit?.isDescendant(of: content) == true)
        }
    }
}

@Test @MainActor
func sidebarButtonsFollowDockedHiddenAndFloatingPanelIncludingSpring() throws {
    let window = measuredButtonsWindow(selected: true)
    defer { window.contentView = nil }
    let container = try #require(window.contentView?.subviews.first as? SidebarContainerView)
    let lights = try #require((window as? BrowserWindow)?.sidebarLights)
    let panel = try #require(lights.superview)
    var now = 0.0
    var pointer = NSPoint(x: window.frame.minX + 100, y: window.frame.midY)
    container.clock = { now }
    container.pointerLocation = { pointer }
    container.applicationActive = { true }
    container.windowKey = { true }
    container.pressedButtons = { 0 }
    #expect(!lights.isHidden)
    for (button, x) in zip(lights.subviews, [CGFloat(19.5), 42.5, 65.5]) {
        let frame = button.convert(button.bounds, to: nil)
        #expect(frame.midX == x)
        #expect(window.frame.height - frame.midY == 23.5)
    }
    container.toggleSidebar()
    container.finishMotion()
    #expect(container.sidebarState == "hidden")
    #expect(lights.isHidden)
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(type))
        #expect(button.isHidden && button.alphaValue == 1)
    }
    pointer.x = window.frame.minX
    container.processPointer()
    now = 0.150
    container.processPointer()
    #expect(container.sidebarState == "floating")
    #expect(!lights.isHidden)
    for (button, x) in zip(lights.subviews, [CGFloat(19.5), 42.5, 65.5]) {
        let frame = button.convert(button.bounds, to: nil)
        #expect(frame.midX == x + 5)
        #expect(window.frame.height - frame.midY == 28.5)
    }
    let spring = try #require(panel.layer?.animation(forKey: "sidebar.position") as? CASpringAnimation)
    let from = try #require(spring.fromValue as? NSValue).pointValue
    let to = try #require(spring.toValue as? NSValue).pointValue
    let layer = try #require(panel.layer)
    let buttonLayers = try lights.subviews.map { button in
        button.wantsLayer = true
        return try #require(button.layer)
    }
    window.displayIfNeeded()
    let centres = buttonLayers.map { $0.convert(CGPoint(x: 7, y: 7), to: container.layer) }
    let originalPosition = layer.position
    let time = 0.055
    let decay = spring.damping / (2 * spring.mass)
    let frequency = sqrt(spring.stiffness / spring.mass - decay * decay)
    let progress = 1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
    layer.removeAllAnimations()
    layer.position = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
    let offset = CGPoint(x: layer.position.x - originalPosition.x, y: layer.position.y - originalPosition.y)
    #expect(abs(offset.x) > 1)
    for (buttonLayer, previous) in zip(buttonLayers, centres) {
        let centre = buttonLayer.convert(CGPoint(x: 7, y: 7), to: container.layer)
        #expect(abs(centre.x - previous.x - offset.x) < 0.01)
        #expect(abs(centre.y - previous.y - offset.y) < 0.01)
    }
    #expect(!window.isVisible)
}

@MainActor
private final class SampledOpacityLayer: CALayer {
    var sample: SampledOpacityLayer?
    override func presentation() -> Self? { sample as? Self }
}

@Test @MainActor
func floatingLightsResumeFromMidHideOpacity() throws {
    let window = measuredButtonsWindow(selected: true)
    defer { window.contentView = nil }
    let container = try #require(window.contentView?.subviews.first as? SidebarContainerView)
    let lights = try #require((window as? BrowserWindow)?.sidebarLights)
    let layer = SampledOpacityLayer()
    lights.layer = layer
    var now = 0.0
    var pointer = NSPoint(x: window.frame.minX + 100, y: window.frame.midY)
    container.clock = { now }
    container.pointerLocation = { pointer }
    container.applicationActive = { true }
    container.windowKey = { true }
    container.pressedButtons = { 0 }
    container.toggleSidebar()
    container.finishMotion()
    pointer.x = window.frame.minX
    container.processPointer()
    now = 0.150
    container.processPointer()
    container.finishMotion()
    pointer.x = window.frame.maxX + 100
    container.processPointer()
    let hide = try #require(layer.animation(forKey: "sidebar.lights") as? CABasicAnimation)
    #expect(hide.duration == 0.090)
    let sample = SampledOpacityLayer()
    sample.opacity = 0.4
    layer.sample = sample
    pointer.x = window.frame.minX
    container.processPointer()
    now = 0.300
    container.processPointer()
    #expect(container.sidebarState == "floating")
    let show = try #require(layer.animation(forKey: "sidebar.lights") as? CABasicAnimation)
    #expect(abs((show.fromValue as? Float ?? -1) - 0.4) < 0.001)
    #expect(show.toValue as? Float == 1)
    #expect(show.duration == SidebarMetrics.dockShowDuration)
    #expect(show.timingFunction == SidebarMetrics.easeOutCubic)
    #expect(layer.opacity == 1)
    container.finishMotion()
    #expect(layer.animation(forKey: "sidebar.lights") == nil)
    #expect(!window.isVisible)
}

@MainActor
private final class MiniaturizeProbe: NSWindow {
    var calls = 0
    override func miniaturize(_ sender: Any?) { calls += 1 }
}

@Test @MainActor
func hiddenNativeButtonsKeepMiniaturizeActionAvailable() throws {
    _ = NSApplication.shared
    let window = MiniaturizeProbe(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    defer { window.contentView = nil }
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(type))
        button.isHidden = true
        button.alphaValue = 1
    }
    window.performMiniaturize(nil)
    #expect(window.calls == 1)
    let lights = SidebarWindowButtons(window: window)
    let minimize = try #require(lights.subviews[1] as? NSButton)
    minimize.performClick(nil)
    #expect(window.calls == 2)
    #expect(!window.isVisible)
}

@Test @MainActor
func applicationWindowUpdatesKeepTheMeasuredButtonPositions() throws {
    let window = measuredButtonsWindow()
    defer { window.contentView = nil }
    window.title = "Updated title"
    window.update()
    for (type, x) in zip([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton], [CGFloat(19.5), 42.5, 65.5]) {
        let button = try #require(window.standardWindowButton(type))
        let parent = try #require(button.superview)
        let frame = parent.convert(button.frame, to: nil)
        #expect(frame.midX == x)
        #expect(window.frame.height - frame.midY == 23.5)
    }
}

@Test @MainActor
func themeFrameContainsNoApplicationOwnedSiblingViews() throws {
    let window = measuredButtonsWindow()
    defer { window.contentView = nil }
    let theme = try #require(window.contentView?.superview)
    #expect(!theme.subviews.contains { String(reflecting: type(of: $0)).hasPrefix("AraratUI.") })
}
