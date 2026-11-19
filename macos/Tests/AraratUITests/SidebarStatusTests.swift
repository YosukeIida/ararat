import AppKit
@testable import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func sidebarRowReportsLoadingAndAudioAndSpeakerDoesNotSelect() {
    _ = NSApplication.shared
    func row(_ kind: RowKind) -> Row {
        Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "item", title: "Item", url: nil, depth: 0, kind: kind, unloaded: false, lastSelectedAt: nil)
    }
    func state(_ loading: Bool, _ audible: Bool, _ muted: Bool) -> EngineAdapter.RowState {
        EngineAdapter.RowState(loading: loading, audible: audible, muted: muted, canGoBack: false, canGoForward: false)
    }
    var selections = 0
    var mutes: [Bool] = []
    let view = SidebarRowView(row: row(.tab), selected: false) { _ in selections += 1 }
    view.onMute = { _, value in mutes.append(value) }
    view.status = state(true, true, false)
    #expect(view.loadingVisible)
    #expect(view.audioLabel == "Mute Tab")
    #expect((view.accessibilityValue() as? String)?.contains("Loading") == true)
    #expect((view.accessibilityValue() as? String)?.contains("Playing audio") == true)
    #expect(view.accessibilityCustomActions()?.contains { $0.name == "Mute Tab" } == true)
    view.pressAudioForCheck()
    #expect(mutes == [true] && selections == 0)
    view.status = state(false, false, true)
    #expect(!view.loadingVisible && view.audioLabel == "Unmute Tab")
    #expect((view.accessibilityValue() as? String)?.contains("Muted") == true)
    view.pressAudioForCheck()
    #expect(mutes == [true, false] && selections == 0)
    for kind in [RowKind.folder, .split] {
        view.update(row: row(kind), selected: false)
        view.status = state(true, true, false)
        #expect(!view.loadingVisible && view.audioLabel == nil)
    }
    let favorite = FavoriteTile(row: row(.tab)) { _ in }
    #expect(favorite.glyphLabel.stringValue == "I")
    #expect(!favorite.subviews.contains { $0 is NSProgressIndicator })
    view.update(row: row(.tab), selected: false)
    view.crashed = true
    #expect(!view.loadingVisible)
}

@Test @MainActor
func favoriteTileDrawsSharedFaviconAndLiveMarks() throws {
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "item",
                  title: "Item", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let space = SpaceSnapshot(pinnedCount: 1, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "",
                              favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .default,
                              id: "work", title: "Work", icon: nil, look: nil, favorites: [row], pinned: [row], today: [])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    let views = descendants(sidebar)
    let tile = try #require(views.compactMap { $0 as? FavoriteTile }.first)
    let rowView = try #require(views.compactMap { $0 as? SidebarRowView }.first)
    let rowIcon = try #require(rowView.subviews.compactMap { $0 as? NSImageView }.first)
    let favicon = NSImage(size: NSSize(width: 16, height: 16))
    #expect(!tile.glyphBox.isHidden && tile.glyphLabel.stringValue == "I")
    #expect(tile.faviconView.isHidden && tile.audioMark.isHidden && tile.unreadDot.isHidden)
    sidebar.favicons[row.id] = favicon
    #expect(tile.faviconView.image === favicon && rowIcon.image === favicon)
    #expect(tile.glyphBox.isHidden && !tile.faviconView.isHidden)

    sidebar.rowStates[row.id] = .init(loading: true, audible: true, muted: false, canGoBack: false, canGoForward: false)
    sidebar.unreadItems.insert(row.id)
    sidebar.favicons.removeAll()
    #expect(rowView.loadingVisible)
    #expect(tile.faviconView.image === favicon && !tile.faviconView.isHidden)
    #expect(!tile.audioMark.isHidden && !tile.unreadDot.isHidden)
    #expect(tile.accessibilityLabel() == "Item" && tile.accessibilityTitle() == "Item")
    #expect(tile.accessibilityValue() as? String == "Unread, Playing audio")
    #expect(tile.glyphBox.frame.size == NSSize(width: 20, height: 20))
    #expect(tile.faviconView.frame == tile.glyphBox.frame.insetBy(dx: 2, dy: 2))
    #expect(tile.audioMark.frame.maxX == tile.bounds.maxX - 5)
    #expect(abs(tile.bounds.maxX - tile.unreadDot.frame.maxX - 7.5) <= 0.5)
    let audioBottom = tile.isFlipped ? tile.bounds.maxY - tile.audioMark.frame.maxY : tile.audioMark.frame.minY
    let dotTop = tile.isFlipped ? tile.unreadDot.frame.minY : tile.bounds.maxY - tile.unreadDot.frame.maxY
    #expect(audioBottom == 4 && abs(dotTop - 6.5) <= 0.5)

    let playing = tile.audioMark.image
    sidebar.rowStates[row.id] = .init(loading: false, audible: true, muted: true, canGoBack: false, canGoForward: false)
    #expect(!tile.audioMark.isHidden && tile.audioMark.image != nil && tile.audioMark.image !== playing)
    #expect(tile.accessibilityValue() as? String == "Unread, Muted")
    #expect(tile.faviconView.isHidden && !tile.glyphBox.isHidden)
    sidebar.rowStates.removeAll()
    #expect(tile.accessibilityValue() as? String == "Unread")
    sidebar.unreadItems.removeAll()
    #expect(tile.audioMark.isHidden && tile.unreadDot.isHidden)
    #expect(tile.accessibilityValue() == nil)
}

@Test @MainActor
func faviconDrawingSelectsRetinaPixelsAndDoesNotEnlargeTheOneTimesBitmap() throws {
    func bitmap(_ pixels: Int) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: pixels * 4, bitsPerPixel: 32))
    }
    func representation(_ pixels: Int, color: NSColor) throws -> NSBitmapImageRep {
        let rep = try bitmap(pixels)
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return rep
    }
    let icon = SidebarIconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    let image = NSImage()
    image.addRepresentation(try representation(16, color: .red))
    let retina = try representation(32, color: .green)
    image.addRepresentation(retina)
    image.size = icon.bounds.size
    icon.setIcon(favicon: image)

    func draw(scale: Int) throws -> NSBitmapImageRep {
        let output = try bitmap(16 * scale)
        let context = try #require(NSGraphicsContext(bitmapImageRep: output))
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 16 * scale, height: 16 * scale))
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        icon.draw(icon.bounds)
        return output
    }
    let standard = try draw(scale: 1)
    #expect((standard.colorAt(x: 8, y: 8)?.redComponent ?? 0) > 0.9)
    let highDensity = try draw(scale: 2)
    #expect((highDensity.colorAt(x: 2, y: 2)?.greenComponent ?? 0) > 0.9)

    image.removeRepresentation(retina)
    let withoutRetina = try draw(scale: 2)
    #expect((withoutRetina.colorAt(x: 8, y: 8)?.redComponent ?? 0) > 0.9)
    #expect((withoutRetina.colorAt(x: 7, y: 16)?.alphaComponent ?? 1) == 0)
    #expect((withoutRetina.colorAt(x: 24, y: 16)?.alphaComponent ?? 1) == 0)
}
