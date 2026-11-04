import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func solidLook(_ red: Double, _ green: Double, _ blue: Double, opacity: Double = 1,
                       grain: Double = 0, glass: Bool = false, appearance: Appearance = .auto) -> Look {
    Look(colors: [LookColor(red: red, green: green, blue: blue, x: 0.5, y: 0.5)],
         opacity: opacity, grain: grain, glass: glass, appearance: appearance)
}

@MainActor
private func lookPanel() -> SidebarPanelView {
    _ = NSApplication.shared
    let panel = SidebarPanelView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    panel.reduceTransparency = { false }
    panel.systemAppearance = { NSAppearance(named: .aqua)! }
    panel.updateLook(nil, nil, fraction: 0)
    panel.layoutSubtreeIfNeeded()
    return panel
}

@MainActor
private func pixel(_ layer: CALayer, over background: NSColor = .white, x: Int = 32, y: Int = 32, size: Int = 64) throws -> NSColor {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4, bitsPerPixel: 32))
    let context = try #require(CGContext(data: bitmap.bitmapData, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    layer.render(in: context)
    let bytes = try #require(bitmap.bitmapData) + y * size * 4 + x * 4
    return NSColor(srgbRed: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255, alpha: 1)
}

@MainActor
private func expectRGB(_ color: NSColor, _ red: Double, _ green: Double, _ blue: Double) {
    #expect(abs(color.redComponent - red) < 0.015)
    #expect(abs(color.greenComponent - green) < 0.015)
    #expect(abs(color.blueComponent - blue) < 0.015)
}

@Test @MainActor
func lookOpacityComposesOverKnownBackdrop() throws {
    let panel = lookPanel()
    for opacity in [0.0, 0.25, 0.5, 1] {
        let look = solidLook(1, 0, 0, opacity: opacity)
        panel.updateLook(look, look, fraction: 0)
        expectRGB(try pixel(panel.gradient), 1, 1 - opacity, 1 - opacity)
    }
}

@Test @MainActor
func lookCrossfadeUsesPremultipliedColorAtHalfPage() throws {
    let panel = lookPanel()
    panel.updateLook(solidLook(1, 0, 0), solidLook(0, 0, 1), fraction: 0.5)
    expectRGB(try pixel(panel.gradient), 0.5, 0, 0.5)
    panel.updateLook(solidLook(1, 0, 0, opacity: 0.2), solidLook(0, 0, 1, opacity: 0.8), fraction: 0.5)
    expectRGB(try pixel(panel.gradient), 0.6, 0.5, 0.9)
}

@Test @MainActor
func lookReduceTransparencyKeepsNativeFallbackAndStoredOpacity() throws {
    let panel = lookPanel()
    let look = solidLook(1, 0, 0, opacity: 0.25, glass: true)
    panel.reduceTransparency = { true }
    panel.updateLook(look, look, fraction: 0)
    #expect(!panel.vibrancy.isHidden)
    if #available(macOS 26.0, *) { #expect(panel.subviews.compactMap { $0 as? NSGlassEffectView }.allSatisfy { $0.isHidden }) }
    expectRGB(try pixel(panel.gradient, over: .black), 0.25, 0, 0)
    expectRGB(try pixel(panel.gradient, over: .white), 1, 0.75, 0.75)
    let firstColor = try #require(panel.gradient.backgroundColor)
    #expect(firstColor.alpha == 0.25)
    panel.reduceTransparency = { false }
    panel.updateLook(look, look, fraction: 0)
    if #available(macOS 26.0, *) {
        #expect(panel.vibrancy.isHidden)
        #expect(panel.subviews.compactMap { $0 as? NSGlassEffectView }.contains { !$0.isHidden })
    } else { #expect(!panel.vibrancy.isHidden) }
}

@Test @MainActor
func noLookKeepsLegacyVibrancyAndPixels() throws {
    for reduced in [false, true] {
        let panel = lookPanel()
        panel.reduceTransparency = { reduced }
        panel.updateLook(nil, nil, fraction: 0)
        #expect(panel.coating.isHidden)
        #expect(!panel.vibrancy.isHidden)
        #expect(panel.vibrancy.material == .sidebar)
        #expect(panel.vibrancy.blendingMode == .behindWindow)
        #expect(panel.vibrancy.appearance == nil)
        let legacy = NSVisualEffectView(frame: panel.bounds)
        legacy.material = .sidebar
        legacy.blendingMode = .behindWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 64), styleMask: [], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        root.addSubview(panel)
        legacy.frame.origin.x = 64
        root.addSubview(legacy)
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let a = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        let b = try #require(legacy.bitmapImageRepForCachingDisplay(in: legacy.bounds))
        panel.cacheDisplay(in: panel.bounds, to: a)
        legacy.cacheDisplay(in: legacy.bounds, to: b)
        #expect(a.representation(using: .png, properties: [:]) == b.representation(using: .png, properties: [:]))
        #expect(!window.isVisible)
    }
}

@Test @MainActor
func lookTextThresholdAndForcedModes() {
    #expect(SidebarPanelView.usesLightText(NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)))
    #expect(!SidebarPanelView.usesLightText(NSColor(srgbRed: 0.47, green: 0.47, blue: 0.47, alpha: 1)))
    let panel = lookPanel()
    let content = NSView()
    panel.addSubview(content)
    for (look, expected) in [
        (solidLook(0, 0, 0), NSAppearance.Name.darkAqua),
        (solidLook(1, 1, 1), .aqua),
        (solidLook(0, 0, 0, appearance: .light), .aqua),
        (solidLook(1, 1, 1, appearance: .dark), .darkAqua),
        (solidLook(0, 0, 0, opacity: 0), .aqua),
    ] {
        panel.updateLook(look, look, fraction: 0)
        #expect(content.appearance?.name == expected)
    }
    panel.updateLook(nil, nil, fraction: 0)
    #expect(content.appearance == nil)
}

@Test @MainActor
func lookGradientHasVerticalEqualStopsAndDeterministicGrain() throws {
    let panel = lookPanel()
    var look = solidLook(1, 0, 0, grain: 0.7)
    look.colors += [LookColor(red: 0, green: 1, blue: 0, x: 0, y: 0), LookColor(red: 0, green: 0, blue: 1, x: 1, y: 1)]
    panel.updateLook(look, look, fraction: 0)
    #expect(panel.gradient.startPoint == CGPoint(x: 0.5, y: 1))
    #expect(panel.gradient.endPoint == CGPoint(x: 0.5, y: 0))
    #expect(panel.gradient.locations == [0, 0.5, 1])
    #expect(abs(panel.grain.opacity - 0.07) < 0.001)
    let other = lookPanel()
    other.updateLook(look, look, fraction: 0)
    #expect(try pixel(panel.grain) == pixel(other.grain))
    panel.grain.frame = CGRect(x: 0, y: 0, width: 128, height: 128)
    #expect(try pixel(panel.grain, x: 3, y: 4, size: 128) == pixel(panel.grain, x: 67, y: 68, size: 128))
    #expect(try pixel(panel.grain, x: 3, y: 4, size: 128) != pixel(panel.grain, x: 4, y: 4, size: 128))
    expectRGB(SidebarPanelView.sample(look, at: 0), 1, 0, 0)
    expectRGB(SidebarPanelView.sample(look, at: 0.5), 0, 1, 0)
    expectRGB(SidebarPanelView.sample(look, at: 1), 0, 0, 1)
}

@Test @MainActor
func sidebarLookTracksPagesAndVirtualNeighbors() {
    let first = solidLook(1, 0, 0), last = solidLook(0, 0, 1)
    let spaces = [first, last].enumerated().map { index, look in
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "s\(index)", title: "Space", icon: nil, look: look, favorites: [], pinned: [], today: [])
    }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s0", selectedId: nil, spaces: spaces))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    var from: Look?, to: Look?, fraction = -1.0
    sidebar.onLookChanged = { from = $0; to = $1; fraction = $2 }
    sidebar.refreshLook(offset: -120)
    #expect(from == first && to == last && fraction == 0.5)
    sidebar.refreshLook()
    #expect(from == first && to == first && fraction == 0)
    sidebar.setLibraryOpen(true)
    sidebar.refreshLook(offset: -120)
    #expect(from == first && to == first && fraction == 0.5)
    sidebar.setLibraryOpen(false)
    sidebar.showSpace(at: 1)
    sidebar.setCreateSpaceOpen(true)
    sidebar.refreshLook(offset: 120)
    #expect(from == last && to == last && fraction == 0.5)
    sidebar.setCreateSpaceOpen(false)
    sidebar.setLibraryOpen(true)
    sidebar.setLibraryOpen(false, scrolling: true)
    sidebar.showSpace(at: 0)
    sidebar.refreshLook(offset: 120)
    #expect(from == last && to == first && fraction == 0.5)
    sidebar.finishScrollPresentation()
}

@Test @MainActor
func lookSwitchesEffectsAndAppearanceAtHalfPage() {
    let panel = lookPanel()
    let content = NSView()
    panel.addSubview(content)
    let first = solidLook(1, 1, 1, appearance: .light)
    let last = solidLook(0, 0, 0, grain: 1, glass: true, appearance: .dark)
    panel.updateLook(first, last, fraction: 0.49)
    #expect(!panel.vibrancy.isHidden)
    #expect(content.appearance?.name == .aqua)
    panel.updateLook(first, last, fraction: 0.5)
    #expect(content.appearance?.name == .darkAqua)
    #expect(abs(panel.grain.opacity - 0.05) < 0.001)
    if #available(macOS 26.0, *) {
        #expect(panel.vibrancy.isHidden)
        #expect(panel.subviews.compactMap { $0 as? NSGlassEffectView }.contains { !$0.isHidden })
    }
    panel.reduceTransparency = { true }
    panel.updateLook(first, last, fraction: 0.5)
    #expect(!panel.vibrancy.isHidden)
    panel.updateLook(nil, nil, fraction: 0)
    #expect(!panel.vibrancy.isHidden && panel.coating.isHidden)
    #expect(content.appearance == nil)
}

@Test @MainActor
func lookSamplingStopsWhenTrackpadInterruptsSettle() throws {
    _ = NSApplication.shared
    let spaces = (0..<2).map { index in
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "s\(index)", title: "Space", icon: nil,
                      look: solidLook(Double(index), 0, 0), favorites: [], pinned: [], today: [])
    }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s0", selectedId: nil, spaces: spaces))
    sidebar.onLookChanged = { _, _, _ in }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    defer { sidebar.finishScrollPresentation(); window.contentView = nil }
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    func event(_ dx: Int32, phase: CGScrollPhase?, time: Double) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cg.timestamp = UInt64(time * 1_000_000_000)
        return try #require(NSEvent(cgEvent: cg))
    }
    sidebar.scrollWheel(with: try event(-100, phase: nil, time: 100))
    #expect(sidebar.spaceShown == 1)
    _ = try #require(sidebar.lookSampling)
    sidebar.scrollWheel(with: try event(20, phase: .began, time: 100.01))
    #expect(sidebar.lookSampling == nil)
    #expect(!window.isVisible)
}

@MainActor
private final class LookScaleWindow: NSWindow {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
}

@Test @MainActor
func grainUsesTwoPixelsPerPointAtScaleTwoAndFollowsScaleChanges() throws {
    let panel = lookPanel()
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 512, bitsPerPixel: 32))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    context.cgContext.scaleBy(x: 2, y: 2)
    let representation = try #require(SidebarPanelView.noise.bestRepresentation(for: panel.bounds, context: context, hints: nil))
    #expect(representation.pixelsWide == 128)
    #expect(representation.pixelsHigh == 128)
    #expect(representation.size == NSSize(width: 64, height: 64))
    let window = LookScaleWindow(contentRect: panel.bounds, styleMask: [], backing: .buffered, defer: false)
    defer { window.contentView = nil }
    window.contentView = panel
    panel.viewDidChangeBackingProperties()
    #expect(panel.grain.contentsScale == 1)
    window.scale = 2
    panel.viewDidChangeBackingProperties()
    #expect(panel.grain.contentsScale == 2)
    window.scale = 1
    panel.viewDidChangeBackingProperties()
    #expect(panel.grain.contentsScale == 1)
    #expect(!window.isVisible)
}
