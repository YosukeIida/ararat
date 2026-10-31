import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@Test @MainActor
func favoritesUseFourTwoOrOneColumns() {
    let favorites = (0..<5).map {
        Row(id: "fav-\($0)", title: "Favorite", url: nil, depth: 0, kind: .tab)
    }
    let snapshot = WorkspaceSnapshot(spaces: [
        SpaceSnapshot(id: "space", title: "Work", icon: nil, favorites: favorites, pinned: [favorites[0]], today: [])
    ])
    for (width, columns) in [(240.0, 4), (228, 4), (227, 2), (118, 2), (117, 1)] {
        let sidebar = SidebarView(snapshot: snapshot)
        let rowBeforeLayout = descendants(of: sidebar).first { $0 is SidebarRowView }!
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 720)
        sidebar.layoutSubtreeIfNeeded()
        #expect(descendants(of: sidebar).first { $0 is SidebarRowView } === rowBeforeLayout)
        sidebar.layoutSubtreeIfNeeded()
        let tiles = descendants(of: sidebar).compactMap { $0 as? FavoriteTile }
        #expect(tiles.count == 5)
        let first = sidebar.convert(tiles[0].bounds, from: tiles[0])
        let nextLine = sidebar.convert(tiles[columns].bounds, from: tiles[columns])
        #expect(abs(first.minX - 8) < 0.01)
        #expect(abs(first.width - (width - 16 - Double(columns - 1) * 8) / Double(columns)) <= 0.5)
        #expect(first.height == 47)
        #expect(sidebar.bounds.height - first.maxY == 90)
        #expect(abs(first.minY - nextLine.minY - 55) < 0.01)
        #expect(tiles[0].layer?.cornerCurve == .continuous)
        #expect(tiles[0].layer?.cornerRadius == 11)
    }
}

@Test @MainActor
func spaceNameCapTopIsTwentyTwoPointsBelowFavorites() {
    let favorite = Row(id: "favorite", title: "Mail", url: nil, depth: 0, kind: .tab)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(spaces: [
        SpaceSnapshot(id: "work", title: "Work", icon: nil, favorites: [favorite], pinned: [], today: [])
    ]))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    let views = descendants(of: sidebar)
    let tile = views.first { $0 is FavoriteTile }!
    let header = views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Work" }!
    let tileFrame = sidebar.convert(tile.bounds, from: tile)
    let textFrame = sidebar.convert(header.alignmentRect(forFrame: header.frame), from: header.superview)
    let capTop = textFrame.maxY - header.firstBaselineOffsetFromTop + header.font!.capHeight
    #expect(textFrame.minX == 16)
    #expect(abs(tileFrame.minY - capTop - 22) <= 0.5)
}

@Test @MainActor
func selectedHostTracksVisibleSpace() {
    let row = Row(id: "tab", title: "Spec", url: "https://docs.example.com/spec", depth: 0, kind: .tab)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(spaces: [
        SpaceSnapshot(id: "work", title: "Work", icon: nil, favorites: [], pinned: [row], today: []),
        SpaceSnapshot(id: "home", title: "Home", icon: nil, favorites: [], pinned: [], today: [])
    ]))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    #expect(sidebar.selectRow(id: "tab"))
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    let host = descendants(of: sidebar).compactMap { $0 as? NSTextField }.first { $0.stringValue == "docs.example.com" }!
    let field = host.superview!
    let frame = sidebar.convert(field.bounds, from: field)
    #expect(frame.minX == 8)
    #expect(frame.width == 224)
    #expect(frame.height == 36)
    #expect(sidebar.bounds.height - frame.maxY == 46)
    #expect(!host.isEditable)
    sidebar.showSpace(at: 1)
    #expect(host.stringValue.isEmpty)
}

@Test @MainActor
func rowIconsDrawSixteenPointSymbolsWithoutScaling() {
    for kind in [RowKind.tab, .folder, .split] {
        let row = Row(id: "row", title: "Title", url: nil, depth: 0, kind: kind)
        let view = SidebarRowView(row: row, selected: false, action: {})
        let icon = view.subviews.compactMap { $0 as? NSImageView }.first!
        #expect(icon.imageScaling == .scaleNone)
        #expect(icon.image?.symbolConfiguration == NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
    }
}

@Test @MainActor
func rowsKeepPitchIndentAndSplitPlaceholder() {
    for title in ["", "First\nSecond"] {
        let row = Row(id: "split", title: title, url: nil, depth: 1, kind: .split)
        let view = SidebarRowView(row: row, selected: true, action: {})
        view.frame = NSRect(x: 0, y: 0, width: 224, height: 41)
        view.layoutSubtreeIfNeeded()
        let label = view.subviews.compactMap { $0 as? NSTextField }.first!
        let icon = view.subviews.compactMap { $0 as? NSImageView }.first!
        let fill = view.subviews[0]
        #expect(label.stringValue == (title.isEmpty ? "Split" : title))
        #expect(view.frame.height == 41)
        #expect(fill.frame.height == 36)
        #expect(abs(fill.frame.midY - view.bounds.midY) <= 0.5)
        let iconRect = icon.alignmentRect(forFrame: icon.frame)
        let titleRect = label.alignmentRect(forFrame: label.frame)
        #expect(abs(iconRect.minX + 8 - 34) < 0.01)
        #expect(abs(titleRect.minX + 8 - 60) < 0.01)
        #expect(abs(iconRect.width - 16) < 0.01)
        #expect(abs(iconRect.height - 16) < 0.01)
    }
}
