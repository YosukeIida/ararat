import AppKit
import Testing
@testable import AraratUI
@testable import AraratKit

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
}

private func look(_ color: LookColor) -> Look {
    Look(colors: [color], opacity: 1, grain: 0, glass: false, appearance: .dark)
}

private func space(_ id: String, look: Look?) -> SpaceSnapshot {
    let row = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false,
                  id: id + "-tab", title: "Title", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    return SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "pinned",
                         todayId: "today", favoritesId: nil, archiveAfter: .hours12, profileName: "Default",
                         profile: .`default`, id: id, title: id, icon: nil, look: look, favorites: [], pinned: [], today: [row])
}

@Test @MainActor
func windowAccentFollowsLookPreviewSpaceSwitchAndPrivateMode() throws {
    _ = NSApplication.shared
    let first = space("first", look: look(LookEditorModel.fieldColor(x: 0.73, y: 0.75)))
    let second = space("second", look: nil)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: first.id, selectedId: nil, spaces: [first, second]))
    let card = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: card)
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("db.sqlite").path, windowID: "accent", card: card)
    defer { adapter.shutdown() }
    container.onSpaceAccentChanged = { [weak adapter] in adapter?.updateSplitFocusAccent($0) }
    let splitRing = adapter.splitFocusRing
    splitRing.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
    let progress = sidebar.libraryButton
    progress.progress = .fraction(0.25)
    let pull = try #require(descendants(sidebar).compactMap { $0 as? SpacePullIndicator }.first)
    let buttons: [NSButton] = [sidebar.urlField, sidebar.urlFieldCopyButton, sidebar.urlFieldSiteControlsButton]
    for button in buttons {
        if let field = button as? URLFieldBackgroundButton { field.showsFocusRing = true }
        (button as? URLFieldButton)?.showsFocusRing = true
    }
    container.showPaneDrop(PaneDropHalf(side: .left, rect: NSRect(x: 0, y: 0, width: 100, height: 100)))
    let drop = try #require(descendants(container).compactMap { $0 as? PaneDropIndicator }.first)

    func check(_ accent: NSColor) throws {
        #expect(progress.ring.strokeColor == accent.cgColor)
        for button in buttons {
            let ring = try #require(button.layer?.sublayers?.first { $0.borderWidth == 3 })
            #expect(!ring.isHidden)
            #expect(ring.borderColor == accent.withAlphaComponent(0.55).cgColor)
        }
        pull.update(excess: 100)
        #expect(pull.circle.fillColor == accent.cgColor)
        pull.update(excess: SidebarMetrics.spaceCreateThreshold)
        #expect(pull.plus.strokeColor == accent.cgColor)
        pull.update(excess: 0)
        let row = try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first)
        sidebar.unreadItems = [row.row.id]
        #expect(row.unreadDotVisible)
        let dot = try #require(row.subviews.first { $0.layer?.cornerRadius == SidebarMetrics.unreadDotSize / 2 })
        #expect(dot.layer?.backgroundColor == accent.cgColor)
        let dropLayer = try #require(drop.subviews.first?.layer)
        #expect(dropLayer.borderColor == accent.withAlphaComponent(0.9).cgColor)
        #expect(dropLayer.backgroundColor == accent.withAlphaComponent(0.08).cgColor)
        try expectPixel(of: splitRing, at: (1, 16), matches: accent)
    }

    try check(SpaceAccent.resolve(first.look))
    let edited = look(LookEditorModel.fieldColor(x: 0.21, y: 0.25))
    sidebar.previewLook(spaceID: first.id, look: edited)
    try check(SpaceAccent.resolve(edited))
    sidebar.showSpaceWithoutNotification(id: second.id)
    try check(SpaceAccent.teal)
    sidebar.showSpaceWithoutNotification(id: first.id)
    try check(SpaceAccent.resolve(edited))
    sidebar.previewLook(spaceID: first.id, look: first.look, active: false)
    try check(SpaceAccent.resolve(first.look))
    var changed = first
    changed.look = edited
    sidebar.applySelection(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: first.id, selectedId: nil, spaces: [changed, second]))
    try check(SpaceAccent.resolve(edited))
    sidebar.privateWindow = true
    try check(SpaceAccent.privateColor)
}

@Test @MainActor
func selectedRowTitleUsesTheCompositeContrast() throws {
    _ = NSApplication.shared
    let brightest = look(LookEditorModel.fieldColor(x: 1.0 / 6, y: 0))
    let middle = look(LookColor(red: 0.43, green: 0.43, blue: 0.43, x: 0, y: 0.57))
    let first = space("first", look: nil)
    let selectedID = try #require(first.today.first?.id)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: first.id, selectedId: selectedID, spaces: [first]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.appearance = NSAppearance(named: .darkAqua)
    let row = try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first)
    let title = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Title" })
    let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
    for (look, backdrop, shouldBeWhite) in [(nil, SidebarPanelView.defaultDarkBackground, true),
        (middle, SidebarPanelView.sample(middle, at: 0.5), false),
        (brightest, SidebarPanelView.sample(brightest, at: 0.5), false)] {
        sidebar.previewLook(spaceID: first.id, look: look)
        let fill = try #require(row.subviews.first?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        let composite = SidebarPanelView.mix(fill, fill, fraction: 0, base: backdrop)
        func luminance(_ color: NSColor) throws -> CGFloat {
            var resolved: NSColor?
            row.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            let rgb = try #require(resolved)
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let background = try luminance(composite)
        for label in [title.textColor, icon.contentTintColor] {
            let foreground = try luminance(try #require(label))
            #expect(shouldBeWhite ? foreground == 1 : foreground == 0)
            let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
            #expect(contrast >= 4.5)
        }
    }
}

@Test @MainActor
func lookSwatchDrawsTheSpaceColorOrTheBoardFallback() throws {
    _ = NSApplication.shared
    let first = space("first", look: nil)
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: first.id, selectedId: nil, spaces: [first])
    let adapter = WorkspaceAdapter(windowID: "accent-swatch")
    let settings = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                                 keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    let swatch = LookPopoverAnchor(settings: settings, space: first)
    try expectPixel(of: swatch, at: (15, 15), matches: SpaceAccent.teal)
    swatch.space.look = look(LookEditorModel.fieldColor(x: 0.6, y: 0.3))
    try expectPixel(of: swatch, at: (15, 15), matches: SpaceAccent.resolve(swatch.space.look))
    swatch.space.look?.colors = []
    try expectPixel(of: swatch, at: (15, 15), matches: SpaceAccent.teal)
}

@MainActor
private func expectPixel(of view: NSView, at point: (Int, Int), matches color: NSColor) throws {
    let bounds = view.bounds
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width),
        pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    view.draw(bounds)
    let pixel = try #require(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
    #expect(pixel.alphaComponent > 0.99)
    #expect(abs(pixel.redComponent - color.redComponent) < 0.015)
    #expect(abs(pixel.greenComponent - color.greenComponent) < 0.015)
    #expect(abs(pixel.blueComponent - color.blueComponent) < 0.015)
}
