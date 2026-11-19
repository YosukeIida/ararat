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
    panel.appearance = NSAppearance(named: .aqua)
    panel.updateLook(nil, nil, fraction: 0)
    panel.layoutSubtreeIfNeeded()
    return panel
}

@Test @MainActor
func unthemedDarkSidebarDrawsTheMeasuredBackdrop() throws {
    let panel = lookPanel()
    panel.appearance = NSAppearance(named: .darkAqua)
    #expect(!panel.coating.isHidden)
    expectRGB(try pixel(panel.gradient), 22.0 / 255, 15.0 / 255, 31.0 / 255)
    panel.active = false
    #expect(!panel.coating.isHidden)
    panel.appearance = NSAppearance(named: .aqua)
    #expect(panel.coating.isHidden)
}

@Test @MainActor
func autoLookUpdatesSidebarControlsAndSelectionOffscreen() throws {
    let panel = lookPanel()
    let row = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false, id: "tab",
                  title: "Test", url: "https://example.com", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "pinned",
                              todayId: "today", favoritesId: nil, archiveAfter: .hours12, profileName: "Default",
                              profile: .`default`, id: "space", title: "Space", icon: nil, look: nil,
                              favorites: [], pinned: [], today: [row])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
    panel.addSubview(sidebar)
    func descendants(_ root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants)
    }
    let views = descendants(sidebar)
    let title = try #require(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Test" })
    let placeholder = try #require(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == URLFieldContent.placeholderText })
    let clear = try #require(views.compactMap { $0 as? SidebarClearButton }.first)
    let dock = try #require(views.compactMap { $0 as? SpaceDockButton }.first)
    let rowView = try #require(views.compactMap { $0 as? SidebarRowView }.first { $0.row.id == row.id })
    let fill = try #require(rowView.subviews.first?.layer)
    rowView.update(row: row, selected: true)
    for (system, look, expected) in [
        (NSAppearance.Name.aqua, solidLook(0, 0.106, 0.349), NSAppearance.Name.darkAqua),
        (.darkAqua, solidLook(1, 0.96, 0.90), .aqua),
        (.aqua, solidLook(0, 0.106, 0.349, opacity: 0.1), .aqua),
    ] {
        panel.appearance = NSAppearance(named: system)
        panel.systemAppearance = { NSAppearance(named: system)! }
        panel.updateLook(look, look, fraction: 0)
        let labels: [(NSView, NSColor?)] = [(title, title.textColor), (placeholder, placeholder.textColor),
                                            (clear, clear.contentTintColor), (dock, dock.checkGlyphColor)]
        for (view, color) in labels {
            #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            var resolved: NSColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color?.usingColorSpace(.sRGB) }
            let red = try #require(resolved).redComponent
            #expect(expected == .darkAqua ? red > 0.5 : red < 0.5)
        }
        let selected = expected == .darkAqua ? SidebarMetrics.rowSelectedFillDark : SidebarMetrics.rowSelectedFillLight
        #expect(fill.backgroundColor == selected.cgColor)
        #expect(dock.checkFill?.alphaComponent == (expected == .darkAqua ? 0.10 : 0.55))
    }
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
func glassWithZeroOpacityUnderReducedTransparencyKeepsGrain() throws {
    let panel = lookPanel()
    let look = solidLook(1, 0, 0, opacity: 0, grain: 0.5, glass: true)
    panel.reduceTransparency = { true }
    panel.updateLook(look, look, fraction: 0)
    #expect(!panel.vibrancy.isHidden)
    #expect(panel.gradient.backgroundColor?.alpha == 0)
    #expect(abs(panel.grain.opacity - 0.5) < 0.001)
}

@Test @MainActor
func unthemedLightSidebarKeepsLegacyVibrancyAndPixels() throws {
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
        legacy.appearance = panel.appearance
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
    #expect(abs(panel.grain.opacity - 0.7) < 0.001)
    let other = lookPanel()
    other.updateLook(look, look, fraction: 0)
    #expect(try pixel(panel.grain) == pixel(other.grain))
    // U24b: the tile is 120 pt, so the same speck sits 120 pt on.
    panel.grain.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
    #expect(try pixel(panel.grain, x: 3, y: 4, size: 240) == pixel(panel.grain, x: 123, y: 124, size: 240))
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
    #expect(abs(panel.grain.opacity - 0.5) < 0.001)
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
func lookSamplingStopsWhenTrackpadInterruptsSettle() async throws {
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
    try await waitUntil { sidebar.lookSampling != nil }
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
func grainFollowsTheWindowsScaleAndKeepsOnePointTwoPointCells() throws {
    let panel = lookPanel()
    // One representation per scale, 120 pt large: 120 px at 1x, 240 px at 2x, so a cell stays 1.2 pt.
    for (scale, side) in [(1.0, 120), (2.0, 240)] {
        let rep = try #require(LookGrainTile.tile(pointSize: 120, scale: scale).representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == side && rep.pixelsHigh == side)
        #expect(rep.size == NSSize(width: 120, height: 120))
        #expect(LookGrainTile.pixels(pointSize: 120, scale: scale) == side)
    }
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

@Test @MainActor
func grainTileHasTheMocksAlphaStatistics() throws {
    for scale in [1.0, 2.0] {
        let side = LookGrainTile.pixels(pointSize: 120, scale: scale)
        let rep = try #require(LookGrainTile.tile(pointSize: 120, scale: scale).representations.first as? NSBitmapImageRep)
        let bytes = try #require(rep.bitmapData)
        var alphas: [Double] = []
        var transparent = 0
        var white = true
        for index in 0..<(side * side) {
            let alpha = Double(bytes[index * 4 + 3]) / 255
            alphas.append(alpha)
            if alpha == 0 { transparent += 1 }
            if alpha > 0, bytes[index * 4] != 255 || bytes[index * 4 + 1] != 255 || bytes[index * 4 + 2] != 255 { white = false }
        }
        let mean = alphas.reduce(0, +) / Double(alphas.count)
        let deviation = (alphas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(alphas.count)).squareRoot()
        // The mock's feColorMatrix on a field with mean 0.5 and sd 0.1143: 1.4·0.5 − 0.35 = 0.35.
        #expect(abs(mean - 0.35) < 0.02)
        #expect(abs(deviation - 0.16) < 0.02)
        #expect(white)
        #expect(Double(transparent) / Double(alphas.count) <= 0.04)
    }
    // The same seed draws the same tile in every run.
    let firstRep = try #require(LookGrainTile.tile(pointSize: 120, scale: 2).representations.first as? NSBitmapImageRep)
    let secondRep = try #require(LookGrainTile.tile(pointSize: 120, scale: 2).representations.first as? NSBitmapImageRep)
    let first = try #require(firstRep.bitmapData)
    let second = try #require(secondRep.bitmapData)
    #expect(Data(bytes: first, count: 240 * 240 * 4) == Data(bytes: second, count: 240 * 240 * 4))
}

@Test @MainActor
func grainTileWrapsWithoutASeam() throws {
    let side = 120
    let values = LookGrainTile.field(pointSize: 120, scale: 1)
    func line(_ offset: Int, byColumn: Bool) -> [Double] {
        (0..<side).map { step in byColumn ? values[step * side + offset] : values[offset * side + step] }
    }
    func difference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
    }
    for byColumn in [true, false] {
        let seam = difference(line(side - 1, byColumn: byColumn), line(0, byColumn: byColumn))
        let inner = (1..<side).map { difference(line($0 - 1, byColumn: byColumn), line($0, byColumn: byColumn)) }.sorted()
        let median = inner[inner.count / 2]
        // The last row or column continues into the first: the tile repeats with no visible edge.
        #expect(seam <= median * 2)
    }
}

@Test @MainActor
func drawnGrainMatchesTheMocksRule() throws {
    // `L′ + 0.35·g·(1 − L′)` for the mean and `0.16·g·(1 − L′)` for the sd, with the mock's white
    // specks: the colour shows through at 100 % and nothing ever darkens.
    func drawn(_ grain: Double) throws -> (mean: Double, deviation: Double, chroma: Double) {
        let panel = SidebarPanelView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        panel.reduceTransparency = { false }
        panel.systemAppearance = { NSAppearance(named: .aqua)! }
        var look = solidLook(0, 27.0 / 255, 89.0 / 255)
        look.grain = grain
        panel.updateLook(look, look, fraction: 0)
        panel.layoutSubtreeIfNeeded()
        return try drawnStatistics(try #require(panel.coating.layer), size: 200)
    }
    let base = try drawn(0)
    #expect(abs(base.mean - (27.0 + 89.0) / 3 / 255) < 0.004)
    #expect(base.deviation < 0.002)
    #expect(abs(base.chroma - 89.0 / 255) < 0.004)
    var previous = base.mean
    for grain in [0.05, 0.5, 1.0] {
        let stats = try drawn(grain)
        let expectedMean = base.mean + 0.35 * grain * (1 - base.mean)
        let expectedDeviation = 0.16 * grain * (1 - base.mean)
        #expect(abs(stats.mean - expectedMean) < 0.006)
        #expect(abs(stats.deviation - expectedDeviation) < 0.1 * expectedDeviation)
        #expect(stats.mean >= previous)
        previous = stats.mean
    }
    #expect(try drawn(1).chroma >= 0.55 * base.chroma)
}

@Test @MainActor
func grainZeroDrawsNothingAndOpacityFollowsTheLook() throws {
    let panel = SidebarPanelView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    panel.reduceTransparency = { false }
    panel.systemAppearance = { NSAppearance(named: .aqua)! }
    for grain in [0.0, 0.05, 0.5, 1.0] {
        var look = solidLook(0, 27.0 / 255, 89.0 / 255)
        look.grain = grain
        panel.updateLook(look, look, fraction: 0)
        panel.layoutSubtreeIfNeeded()
        #expect(abs(panel.grain.opacity - Float(grain)) < 0.0001)
        if grain == 0 {
            let plain = try drawnStatistics(try #require(panel.coating.layer), size: 200)
            let expected = (27.0 + 89.0) / 3 / 255
            #expect(abs(plain.mean - expected) < 0.004)
            #expect(plain.deviation < 0.002)
        }
    }
}

@MainActor
private func drawnStatistics(_ layer: CALayer, size: Int) throws -> (mean: Double, deviation: Double, chroma: Double) {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4, bitsPerPixel: 32))
    let context = try #require(CGContext(data: bitmap.bitmapData, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    layer.render(in: context)
    let bytes = try #require(bitmap.bitmapData)
    var values: [Double] = []
    var reds = 0.0, greens = 0.0, blues = 0.0
    for index in 0..<(size * size) {
        let red = Double(bytes[index * 4]) / 255, green = Double(bytes[index * 4 + 1]) / 255, blue = Double(bytes[index * 4 + 2]) / 255
        reds += red; greens += green; blues += blue
        values.append((red + green + blue) / 3)
    }
    let count = Double(size * size)
    let mean = values.reduce(0, +) / count
    let deviation = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count).squareRoot()
    let channels = [reds / count, greens / count, blues / count]
    return (mean, deviation, channels.max()! - channels.min()!)
}

@Test @MainActor
func lookCheckRenderingReadsTheSidebarAndOverridesReduceTransparency() throws {
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "s", title: "Space", icon: nil, look: solidLook(1, 0, 0, opacity: 0, grain: 0.5, glass: true), favorites: [], pinned: [], today: [])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "s", selectedId: nil, spaces: [space]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    sidebar.refreshLook()
    let reduced = container.lookCheckRendering(reduced: true)
    #expect(reduced.vibrancy && !reduced.glass && abs(reduced.grain - 0.5) < 0.001 && reduced.alpha == 0)
    #expect(reduced.color?.alphaComponent == 0)
    let normal = container.lookCheckRendering(reduced: false)
    if #available(macOS 26.0, *) { #expect(normal.glass && !normal.vibrancy) }
    // The grain check waits on the colour it asked for, so the rendering reports it.
    let probe = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "p", title: "Space", icon: nil, look: solidLook(0, 27.0 / 255, 89.0 / 255), favorites: [], pinned: [], today: [])
    let probeSidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "p", selectedId: nil, spaces: [probe]))
    let probeContainer = SidebarContainerView(sidebar: probeSidebar, page: NSView())
    probeSidebar.refreshLook()
    let drawing = probeContainer.lookCheckRendering(reduced: false)
    let color = try #require(drawing.color)
    #expect(abs(color.redComponent - 0) < 0.01)
    #expect(abs(color.greenComponent - 27.0 / 255) < 0.01)
    #expect(abs(color.blueComponent - 89.0 / 255) < 0.01)
    #expect(color.alphaComponent == 1)
}
