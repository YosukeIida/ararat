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
private func measuredButtonsWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = content.bounds
    container.autoresizingMask = [.width, .height]
    content.addSubview(container)
    window.contentView = content
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
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(type))
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
