import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func libraryDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + libraryDescendants($0) }
}

@Test @MainActor
func libraryButtonEscapeAndRestorePreserveUserWidthAndLastPage() throws {
    _ = NSApplication.shared
    let entry = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "closed", title: "A closed tab", url: "https://closed.example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "home", title: "Home", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [ArchiveEntry(id: entry.id, title: entry.title, url: entry.url ?? "", lifecycleChangedAt: 0)], shownSpaceId: "home", selectedId: nil, spaces: [space]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
    container.resizeHandle.sidebarWidth = 347
    container.layoutSubtreeIfNeeded()
    let button = try #require(libraryDescendants(sidebar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Library" })
    #expect(button.frame.width == 32 && button.frame.height == 32)
    #expect(abs(button.frame.midY - 25) < 0.1)
    button.performClick(nil)
    container.layoutSubtreeIfNeeded()
    #expect(sidebar.libraryOpen)
    #expect(sidebar.frame.width == 417)
    #expect(container.resizeHandle.sidebarWidth == 347)
    #expect(sidebar.libraryPage == "Archive")
    let library = try #require(libraryDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    library.appearance = NSAppearance(named: .aqua)
    let plus = try #require(libraryDescendants(sidebar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "New Space menu" })
    #expect(!sidebar.convert(library.clearArchiveButton.bounds, from: library.clearArchiveButton).intersects(plus.frame))
    let archive = try #require(libraryDescendants(library).compactMap { $0 as? LibraryRailTileButton }.first { $0.accessibilityLabel() == "Archive page" })
    #expect(archive.iconView.image != nil && archive.label.stringValue == "Archive")
    #expect(library.downloadsButton.iconView.image != nil && library.downloadsButton.label.stringValue == "Downloads")
    #expect(archive.accessibilityValue() as? String == "selected")
    #expect(archive.layer?.backgroundColor == LibraryView.lightSelectedTileFill.cgColor)
    library.showDownloads()
    #expect(archive.accessibilityValue() == nil && archive.layer?.backgroundColor == nil)
    #expect(library.downloadsButton.layer?.backgroundColor == LibraryView.lightSelectedTileFill.cgColor)
    library.showArchive()
    #expect(sidebar.libraryOpenFraction == 1)
    let fill = try #require(button.layer?.sublayers?.first { $0.backgroundColor?.alpha ?? 0 > 0 })
    button.effectiveAppearance.performAsCurrentDrawingAppearance {
        let expected = SpaceAccent.teal.withAlphaComponent(
            SpaceDockButton.fillAlpha(fraction: 1, appearance: button.effectiveAppearance)
        )
        #expect(fill.backgroundColor == expected.cgColor)
    }
    sidebar.cancelOperation(nil)
    container.layoutSubtreeIfNeeded()
    #expect(!sidebar.libraryOpen && sidebar.frame.width == 347)
    #expect(sidebar.libraryOpenFraction == 0)
    #expect(fill.backgroundColor?.alpha == 0)
    button.performClick(nil)
    button.performClick(nil)
    #expect(!sidebar.libraryOpen && sidebar.libraryPage == "Archive")
    sidebar.setLibraryOpen(true)
    var restored: String?
    sidebar.onRestore = { id in
        restored = id
        var opened = space
        opened.today = [entry]
        sidebar.applyRestore(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: id, spaces: [opened]))
    }
    let restore = try #require(libraryDescendants(sidebar).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "closed" })
    restore.performClick(nil)
    container.layoutSubtreeIfNeeded()
    #expect(restored == "closed")
    #expect(!sidebar.libraryOpen && sidebar.selectedRowID == "closed")
    #expect(sidebar.frame.width == 347 && container.resizeHandle.sidebarWidth == 347)
}

@Test @MainActor
func emptyPageShowsTheCurrentShortcutsUntilATabIsSelected() throws {
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "tab", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .default, id: "home", title: "Home", icon: nil, look: nil, favorites: [], pinned: [], today: [row])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: nil, spaces: [space]))
    let page = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: page)
    container.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
    container.layoutSubtreeIfNeeded()
    func keycaps() -> [String] {
        libraryDescendants(container).compactMap { $0 as? TooltipKeycap }
            .filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }
    #expect(page.layer?.backgroundColor != nil)
    #expect(keycaps() == ["⌘", "T", "⇧", "⌘", "L"])
    let newTab = try #require(sidebar.keyBindings.firstIndex { $0.command == "new_tab" })
    let binding = try #require(sidebar.keyBindings[newTab].key)
    var rebound = binding
    rebound.key = "y"
    sidebar.keyBindings[newTab].key = rebound
    #expect(keycaps() == ["⌘", "Y", "⇧", "⌘", "L"])
    sidebar.keyBindings[newTab].key = nil
    #expect(keycaps() == ["⇧", "⌘", "L"])
    #expect(sidebar.selectRow(id: row.id))
    container.selectionChanged()
    #expect(keycaps().isEmpty)
}

@Test @MainActor
func libraryIsTheScrollPageBeforeTheFirstSpaceAndStaysOnRelease() {
    var scrollPause = -Double.infinity
    var scroll = SpaceScrollState()
    #expect(scroll.handle(.init(dx: 300, phase: .began, time: 0), index: 0, count: 2, pitch: 240, wheelPausedUntil: &scrollPause) == .follow(150))
    #expect(scroll.handle(.init(dx: 0, phase: .ended, time: 0.2), index: 0, count: 2, pitch: 240, wheelPausedUntil: &scrollPause) == .settle(index: -1, offset: 150, switched: true))
    #expect(scroll.handle(.init(dx: -300, phase: .began, time: 1), index: -1, count: 2, pitch: 240, wheelPausedUntil: &scrollPause) == .follow(-150))
    #expect(scroll.handle(.init(dx: 0, phase: .ended, time: 1.2), index: -1, count: 2, pitch: 240, wheelPausedUntil: &scrollPause) == .settle(index: 0, offset: -150, switched: true))
}

@Test @MainActor
func wheelOpensLibraryAtFirstSpaceButCannotPassLastSpace() {
    let spaces = (0..<2).map { SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space-\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: [], today: []) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space-0", selectedId: nil, spaces: spaces))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    let event: (Int32, Double) -> NSEvent = { dx, time in
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        cg.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }
    sidebar.scrollWheel(with: event(5, 100))
    #expect(sidebar.libraryOpen && sidebar.spaceShown == 0)
    sidebar.setLibraryOpen(false)
    sidebar.showSpace(at: 1)
    sidebar.scrollWheel(with: event(-5, 101))
    #expect(!sidebar.libraryOpen && sidebar.spaceShown == 1)
}

@Test @MainActor
func sidebarScrollOpensLibraryStaysOpenAndScrollsBackToFirstSpace() async throws {
    _ = NSApplication.shared
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "home", title: "Home", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: nil, spaces: [space]))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = container
    defer { window.contentView = nil }
    container.layoutSubtreeIfNeeded()
    let event: (Int32, CGScrollPhase, Double) -> NSEvent = { dx, phase, time in
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        cg.location = CGPoint(x: 20, y: (NSScreen.screens.first?.frame.maxY ?? 0) - 350)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }
    sidebar.scrollWheel(with: event(300, .began, 100))
    sidebar.scrollWheel(with: event(0, .ended, 100.2))
    #expect(sidebar.libraryOpen)
    let library = try #require(libraryDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    #expect(library.layer?.animation(forKey: "space.scroll") is CASpringAnimation)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    #expect(sidebar.libraryOpen)
    sidebar.scrollWheel(with: event(-450, .began, 102))
    sidebar.scrollWheel(with: event(0, .ended, 102.2))
    #expect(!sidebar.libraryOpen && sidebar.spaceShown == 0)
    #expect(container.resizeHandle.sidebarWidth == SidebarMetrics.defaultWidth)
}

@Test @MainActor
func libraryRailTilesCentreTheIconAndLabelEightPointsApart() throws {
    _ = NSApplication.shared
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 417, height: 720))
    library.layoutSubtreeIfNeeded()
    let tiles = libraryDescendants(library).compactMap { $0 as? LibraryRailTileButton }
    #expect(tiles.count == 2)
    for tile in tiles {
        let icon = tile.convert(tile.iconView.bounds, from: tile.iconView)
        let label = tile.convert(tile.label.bounds, from: tile.label)
        let left = min(icon.minX, label.minX), right = max(icon.maxX, label.maxX)
        let near = min(icon.minY, label.minY), far = max(icon.maxY, label.maxY)
        #expect(tile.bounds.height == LibraryView.railTileHeight)
        #expect(icon.width == LibraryView.railTileIconSize && icon.height == LibraryView.railTileIconSize)
        #expect(abs(far - near - icon.height - label.height - LibraryView.railTileContentGap) <= 1)
        #expect(abs((near + far) / 2 - tile.bounds.midY) <= 1)
        #expect(abs((left + right) / 2 - tile.bounds.midX) <= 1)
    }
}

@Test @MainActor
func libraryRailTilePressedDimsItsFillIconAndLabel() throws {
    _ = NSApplication.shared
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 417, height: 720))
    library.appearance = NSAppearance(named: .darkAqua)
    library.showArchive()
    let tile = try #require(libraryDescendants(library).compactMap { $0 as? LibraryRailTileButton }
        .first { $0.accessibilityLabel() == "Archive page" })
    func channels(_ color: NSColor?) throws -> [CGFloat] {
        var resolved: NSColor?
        tile.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color?.usingColorSpace(.sRGB) }
        let rgb = try #require(resolved)
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
    }
    func tileFill() throws -> [CGFloat] {
        try channels(tile.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
    }
    let dim = LibraryView.railTilePressedBrightness
    // `filter: brightness()` multiplies each sRGB channel and keeps alpha.
    let half = try channels(LibraryRailTileButton.pressedColor(
        NSColor(srgbRed: 0.5, green: 0.25, blue: 0.125, alpha: 0.4)))
    #expect(abs(half[0] - 0.48) < 0.000_1 && abs(half[1] - 0.24) < 0.000_1)
    #expect(abs(half[2] - 0.12) < 0.000_1 && abs(half[3] - 0.4) < 0.000_1)
    let baseFill = try tileFill()
    let baseText = try channels(tile.label.textColor)
    #expect(baseText[0] > 0.9, "the dark appearance's text is light, so the dimming is visible")
    #expect(try channels(tile.iconView.contentTintColor) == baseText)
    tile.setPressed(true)
    let pressedFill = try tileFill()
    let pressedText = try channels(tile.label.textColor)
    for index in 0..<3 {
        #expect(abs(pressedFill[index] - baseFill[index] * dim) < 0.002)
    }
    #expect(pressedFill[3] == baseFill[3])
    for index in 0..<3 {
        #expect(abs(pressedText[index] - baseText[index] * dim) < 0.002)
    }
    #expect(try channels(tile.iconView.contentTintColor) == pressedText)
    // An unselected tile has no fill to dim; its icon and label still dim.
    library.showDownloads()
    #expect(tile.layer?.backgroundColor == nil)
    tile.setPressed(true)
    #expect(tile.layer?.backgroundColor == nil)
    #expect(abs((try channels(tile.label.textColor))[0] - baseText[0] * dim) < 0.002)
    tile.setPressed(false)
    #expect(try channels(tile.label.textColor) == baseText)
    #expect(try channels(tile.iconView.contentTintColor) == baseText)
}

@Test @MainActor
func clearArchiveButtonTracksTheWholeArchiveRatherThanSearchResults() {
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
    #expect(!library.clearArchiveButton.isEnabled)
    library.update(archive: [ArchiveEntry(id: "closed", title: "Closed", url: "https://closed.test", lifecycleChangedAt: 1)])
    library.setSearchQuery("missing")
    #expect(library.clearArchiveButton.isEnabled)
    var clears = 0
    library.onClearArchive = { clears += 1 }
    library.clearArchiveButton.performClick(nil)
    #expect(clears == 1)
    library.update(archive: [])
    #expect(!library.clearArchiveButton.isEnabled)
}
