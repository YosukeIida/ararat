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
        let progressBackdrop = try #require(SidebarPanelView.backdrop(behind: progress, overlaidBy: progress.libraryFill.backgroundColor))
        #expect(progress.ring.strokeColor == SpaceAccent.visible(accent, on: progressBackdrop).cgColor)
        for button in buttons {
            let ring = try #require(button.layer?.sublayers?.first { $0.borderWidth == 3 })
            let fill = button === sidebar.urlField ? nil : sidebar.urlField.layer?.backgroundColor
            let backdrop = try #require(SidebarPanelView.backdrop(behind: button, overlaidBy: fill))
            #expect(!ring.isHidden)
            #expect(ring.borderColor == SpaceAccent.visible(accent.withAlphaComponent(0.55), on: backdrop).cgColor)
        }
        pull.update(excess: 100)
        let pullBackdrop = try #require(SidebarPanelView.backdrop(behind: pull))
        #expect(pull.circle.fillColor == SpaceAccent.visible(accent, on: pullBackdrop).cgColor)
        pull.update(excess: SidebarMetrics.spaceCreateThreshold)
        #expect(pull.plus.strokeColor == SpaceAccent.visible(accent, on: .white).cgColor)
        pull.update(excess: 0)
        let row = try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first)
        sidebar.unreadItems = [row.row.id]
        #expect(row.unreadDotVisible)
        let dot = try #require(row.subviews.first { $0.layer?.cornerRadius == SidebarMetrics.unreadDotSize / 2 })
        let dotBackdrop = try #require(SidebarPanelView.backdrop(behind: dot, overlaidBy: row.subviews.first?.layer?.backgroundColor))
        #expect(dot.layer?.backgroundColor == SpaceAccent.visible(accent, on: dotBackdrop).cgColor)
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

@Test @MainActor
func sidebarAccentPartsHaveThreeToOneContrastOnTheLook() throws {
    _ = NSApplication.shared
    let editorColor = LookEditorModel.defaultLook.colors[0]
    let hue = NSColor(deviceRed: editorColor.red, green: editorColor.green, blue: editorColor.blue, alpha: 1).hueComponent
    let first = space("contrast", look: nil)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: first.id, selectedId: nil, spaces: [first]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    let panel = try #require(sidebar.superview as? SidebarPanelView)
    let row = try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first)
    let dot = try #require(row.subviews.first { $0.layer?.cornerRadius == SidebarMetrics.unreadDotSize / 2 })
    let pull = try #require(descendants(sidebar).compactMap { $0 as? SpacePullIndicator }.first)
    let progress = sidebar.libraryButton
    let buttons: [NSButton] = [sidebar.urlField, sidebar.urlFieldCopyButton, sidebar.urlFieldSiteControlsButton]
    sidebar.unreadItems = [row.row.id]
    progress.progress = .fraction(0.25)

    for (name, mode, opacity) in [
        ("editor-default-light", Appearance.light, 0.45),
        ("editor-default-dark", .dark, 0.45),
        ("opaque", .dark, 1.0),
    ] {
        let appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)!
        container.appearance = appearance
        panel.systemAppearance = { appearance }
        sidebar.previewLook(spaceID: first.id, look: Look(colors: [editorColor], opacity: opacity, grain: 0, glass: false, appearance: mode))
        pull.update(excess: 100)
        let fieldFill = try #require(sidebar.urlField.checkFill)
        let fieldBackdrop = panel.rowBackdrop(behind: sidebar.urlField)
        var samples: [(String, CGColor?, NSColor)] = [
            ("unread", dot.layer?.backgroundColor, panel.rowBackdrop(behind: dot)),
            ("pull", pull.circle.fillColor, panel.rowBackdrop(behind: pull)),
            ("downloads", progress.ring.strokeColor, panel.rowBackdrop(behind: progress)),
        ]
        for (index, button) in buttons.enumerated() {
            let ring = try #require(button.layer?.sublayers?.first { $0.borderWidth == 3 })
            let backdrop = index == 0 ? fieldBackdrop :
                SidebarPanelView.mix(fieldFill, fieldFill, fraction: 0, base: panel.rowBackdrop(behind: button))
            samples.append(("focus-\(index)", ring.borderColor, backdrop))
        }

        for (part, color, backdrop) in samples {
            let foreground = try #require(color.flatMap(NSColor.init(cgColor:)))
            let measured = contrast(foreground, over: backdrop)
            let quantized = contrast(foreground, over: backdrop, quantized: true)
            let ratio = String(format: "%.3f", measured)
            let quantizedRatio = String(format: "%.3f", quantized)
            print("mockfix-d-3 \(name) \(part): \(ratio) (8-bit \(quantizedRatio))")
            #expect(measured >= 3, "\(name) \(part)")
            #expect(quantized >= 3, "\(name) \(part), 8-bit")
            let rgb = try #require(foreground.usingColorSpace(.sRGB))
            let hsv = NSColor(deviceRed: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1)
            if hsv.saturationComponent == 0 {
                #expect(hsv.brightnessComponent == 0 || hsv.brightnessComponent == 1)
                #expect(rgb.alphaComponent == 1)
            } else {
                #expect(abs(hsv.hueComponent - hue) < 0.0001, "\(name) \(part)")
            }
        }
        sidebar.updateSelection(id: row.row.id)
        let selectedFill = try #require(row.subviews.first?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        let selectedBackdrop = SidebarPanelView.mix(selectedFill, selectedFill, fraction: 0, base: panel.rowBackdrop(behind: dot))
        let selectedDot = try #require(dot.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(contrast(selectedDot, over: selectedBackdrop) >= 3)
        sidebar.updateSelection(id: nil)
        pull.update(excess: 0)
    }
}

@Test @MainActor
func unselectedSidebarRowsKeepReadableForegrounds() throws {
    _ = NSApplication.shared
    func row(_ title: String, parent: String, kind: RowKind = .tab, depth: UInt32 = 0, unloaded: Bool = false) -> Row {
        Row(folderHasTabs: title != "Empty Folder", parentId: parent, siblingIndex: 0, collapsed: false,
            id: title, title: title, url: nil, depth: depth,
            kind: kind, unloaded: unloaded, lastSelectedAt: nil)
    }
    var first = space("rowcontrast", look: nil)
    first.today = [row("Today", parent: "today"), row("Dimmed", parent: "today", unloaded: true),
                   row("Split", parent: "today", kind: .split), row("Pane", parent: "Split", depth: 1, unloaded: true)]
    first.pinned = [row("Pinned", parent: "pinned"), row("Folder", parent: "pinned", kind: .folder),
                    row("Nested", parent: "Folder", depth: 1), row("Empty Folder", parent: "pinned", kind: .folder),
                    row("No tabs", parent: "Empty Folder", kind: .noTabs, depth: 1)]
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: first.id, selectedId: nil, spaces: [first]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let panel = try #require(sidebar.superview as? SidebarPanelView)
    let views = descendants(sidebar)
    let rows = views.compactMap { $0 as? SidebarRowView }.filter { $0.row.kind != .split }
    #expect(Set(rows.map(\.row.id)) == ["Today", "Dimmed", "Pinned", "Folder", "Nested", "Empty Folder"])
    let segment = try #require(views.compactMap { $0 as? SplitSegmentButton }.first)
    let empty = try #require(views.compactMap { $0 as? SidebarNoTabsRow }.first)
    let emptyLabel = try #require(empty.subviews.first as? NSTextField)

    let editorColor = LookEditorModel.defaultLook.colors[0]
    let brightest = LookEditorModel.fieldColor(x: 1.0 / 6, y: 0)
    for (name, mode, color, opacity) in [
        ("brightest-dark", Appearance.dark, brightest, 1.0),
        ("editor-default-light", .light, editorColor, 0.45),
        ("editor-default-dark", .dark, editorColor, 0.45),
    ] {
        let appearance = try #require(NSAppearance(named: mode == .dark ? .darkAqua : .aqua))
        container.appearance = appearance
        panel.systemAppearance = { appearance }
        sidebar.previewLook(spaceID: first.id, look: Look(colors: [color], opacity: opacity, grain: 0, glass: false, appearance: mode))
        container.layoutSubtreeIfNeeded()
        let segmentFill = try #require(segment.fill.fillColor.flatMap(NSColor.init(cgColor:)))
        let effectiveFill = segmentFill.withAlphaComponent(segmentFill.alphaComponent * CGFloat(segment.fill.opacity))
        let segmentBackdrop = try #require(SidebarPanelView.backdrop(behind: segment, overlaidBy: effectiveFill.cgColor))
        let emptyBackdrop = try #require(SidebarPanelView.backdrop(behind: empty))
        appearance.performAsCurrentDrawingAppearance {
            let paneTitle = segment.titleField.textColor!.usingColorSpace(.sRGB)!
            let paneIcon = segment.iconView.contentTintColor!.usingColorSpace(.sRGB)!
            let emptyTitle = emptyLabel.textColor!.usingColorSpace(.sRGB)!
            #expect(contrast(paneTitle.withAlphaComponent(paneTitle.alphaComponent * segment.titleField.alphaValue), over: segmentBackdrop, quantized: true) >= 4.5)
            #expect(contrast(paneIcon.withAlphaComponent(paneIcon.alphaComponent * segment.iconView.alphaValue), over: segmentBackdrop, quantized: true) >= 4.5)
            #expect(contrast(emptyTitle.withAlphaComponent(emptyTitle.alphaComponent * emptyLabel.alphaValue), over: emptyBackdrop, quantized: true) >= 4.5)
        }
        for row in rows {
            let title = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == row.row.title })
            let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
            if row.row.kind == .tab {
                row.status = EngineAdapter.RowState(loading: false, audible: true, muted: false, canGoBack: false, canGoForward: false)
            }
            let audio = row.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden && $0.accessibilityLabel() == "Mute Tab" }
            if row.row.kind == .tab { #expect(audio != nil) }
            for hovered in [false, true] {
                row.pointerLocation = { hovered ? row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil) : nil }
                row.refreshHover()
                #expect(row.hovered == hovered)
                let backdrop = try #require(SidebarPanelView.backdrop(behind: row, overlaidBy: row.subviews.first?.layer?.backgroundColor))
                let baseOpacity = row.row.unloaded ? SidebarMetrics.unloadedOpacity : 1
                if row.row.unloaded { #expect(title.alphaValue < 1) }
                let state = hovered ? "hovered" : "plain"
                appearance.performAsCurrentDrawingAppearance {
                    @MainActor func check(_ part: String, _ color: NSColor, _ opacity: CGFloat, preferred: NSColor, preferredOpacity: CGFloat) {
                        let resolved = color.usingColorSpace(.sRGB)!
                        let baseline = preferred.usingColorSpace(.sRGB)!
                        let ratio = contrast(resolved.withAlphaComponent(resolved.alphaComponent * opacity), over: backdrop, quantized: true)
                        let original = contrast(baseline.withAlphaComponent(baseline.alphaComponent * preferredOpacity), over: backdrop, quantized: true)
                        print("rowcontrast \(name) \(row.row.id) \(state) \(part): \(String(format: "%.3f -> %.3f", original, ratio))")
                        #expect(ratio >= 4.5, "\(name) \(row.row.id) \(state) \(part)")
                        if original >= 4.5 {
                            #expect(resolved == baseline)
                            #expect(opacity == preferredOpacity)
                        }
                    }
                    check("title", title.textColor!, title.alphaValue, preferred: .labelColor, preferredOpacity: baseOpacity)
                    check("icon", icon.contentTintColor!, icon.alphaValue, preferred: .secondaryLabelColor, preferredOpacity: baseOpacity)
                    if let audio {
                        check("audio", audio.contentTintColor ?? .labelColor, 1, preferred: .labelColor, preferredOpacity: 1)
                    }
                }
            }
            row.pointerLocation = nil
            row.refreshHover()
        }
    }
}

@Test @MainActor
func sidebarAccentOnlyUsesOpaqueFallbackWhenItsAlphaCannotReachThreeToOne() {
    let base = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    #expect(SpaceAccent.visible(SpaceAccent.teal, on: .white) == SpaceAccent.teal)
    #expect(SpaceAccent.visible(SpaceAccent.teal.withAlphaComponent(0.01), on: base) == .black)
}

@MainActor
private func contrast(_ color: NSColor, over backdrop: NSColor, quantized: Bool = false) -> CGFloat {
    func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ channel: CGFloat) -> CGFloat {
            let value = quantized ? (channel * 255).rounded() / 255 : channel
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
    let foreground = luminance(SidebarPanelView.mix(color, color, fraction: 0, base: backdrop))
    let background = luminance(backdrop)
    return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
}
