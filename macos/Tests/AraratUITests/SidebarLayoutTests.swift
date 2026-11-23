import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@Test @MainActor
func dockCheckUsesTheOwningSidebarWithANestedPreview() {
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [])
    let sidebar = SidebarView(snapshot: snapshot)
    let rootDock = sidebar.dockCheckView
    let preview = SidebarView(snapshot: snapshot)
    let page = NSView()
    page.addSubview(preview)
    sidebar.addSubview(page, positioned: .below, relativeTo: sidebar.subviews.first)

    #expect(sidebar.window == nil)
    #expect(descendants(of: sidebar).compactMap { $0 as? SpaceDockView }.first === preview.dockCheckView)
    #expect(sidebar.dockCheckView === rootDock)
    #expect(sidebar.dockCheckView !== preview.dockCheckView)
    page.removeFromSuperview()
    #expect(sidebar.dockCheckView === rootDock)
}

@Test @MainActor
func favoritesUseColumnsThatFit() {
    let favorites = (0..<5).map {
        Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "fav-\($0)", title: "Favorite", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: favorites, pinned: [favorites[0]], today: [])
    ])
    for (width, columns) in [(240.0, 4), (228, 4), (227, 3), (164, 2)] {
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
func fewerFavoritesThanColumnsShareTheWholeWidth() {
    for count in 1...3 {
        let favorites = (0..<count).map {
            Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "fav-\($0)", title: "Favorite", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
        }
        let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [
            SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: favorites, pinned: [], today: [])
        ])
        let sidebar = SidebarView(snapshot: snapshot)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
        sidebar.layoutSubtreeIfNeeded()
        let tiles = descendants(of: sidebar).compactMap { $0 as? FavoriteTile }
        #expect(tiles.count == count)
        let last = sidebar.convert(tiles[count - 1].bounds, from: tiles[count - 1])
        #expect(abs(last.maxX - 232) <= 0.5)
        #expect(abs(last.width - (224 - Double(count - 1) * 8) / Double(count)) <= 0.5)
    }
}

@Test @MainActor
func spaceNameCapTopIsTwentyTwoPointsBelowFavorites() {
    let favorite = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "favorite", title: "Mail", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil, favorites: [favorite], pinned: [], today: [])
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
func focusedURLFollowsItsItemWhileSelectionChanges() {
    let a = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false, id: "a", title: "A", url: "https://a.example/saved", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let b = Row(folderHasTabs: false, parentId: "today", siblingIndex: 1, collapsed: false, id: "b", title: "B", url: "https://b.example/saved", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 2, profileKey: "default", pinnedId: "pinned", todayId: "today", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [a, b])
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "space", selectedId: "a", spaces: [space])
    let sidebar = SidebarView(snapshot: snapshot)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("split-url-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    sidebar.pasteboard = pasteboard
    sidebar.focusedPane = ("a", "https://live-a.example/path")
    sidebar.update(snapshot: snapshot)
    #expect(sidebar.urlHostForCheck == "live-a.example")
    #expect(sidebar.selectRow(id: "b"))
    #expect(sidebar.urlHostForCheck == "b.example")
    sidebar.checkClickCopyLink()
    #expect(pasteboard.string(forType: .string) == b.url)
}

@Test @MainActor
func selectedHostTracksVisibleSpace() {
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "tab", title: "Spec", url: "https://docs.example.com/spec", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [row], today: []),
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "home", title: "Home", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    ]))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    #expect(sidebar.selectRow(id: "tab"))
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    let host = descendants(of: sidebar).compactMap { $0 as? NSTextField }.first { $0.stringValue == "docs.example.com" }!
    var field: NSView = host
    while !(field is URLFieldBackgroundButton) { field = field.superview! }
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
        let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "row", title: "Title", url: nil, depth: 0, kind: kind, unloaded: false, lastSelectedAt: nil)
        let view = SidebarRowView(row: row, selected: false, action: { _ in })
        let icon = view.subviews.compactMap { $0 as? NSImageView }.first!
        #expect(icon.imageScaling == .scaleNone)
        if kind == .folder {
            #expect(icon.image?.size == NSSize(width: 16, height: 16))
            #expect(icon.image?.isTemplate == true)
        } else {
            #expect(icon.image?.symbolConfiguration == NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        }
    }
}

@Test @MainActor
func splitSegmentsSelectTheirPane() {
    let split = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false, id: "split", title: "", url: nil, depth: 0, kind: .split, unloaded: false, lastSelectedAt: nil)
    let members = ["a", "b", "c"].map { id in
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 0, collapsed: false, id: id, title: id, url: "https://\(id).example", depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    var chosen: String?
    let view = SidebarRowView(row: split, selected: true) { chosen = $0.id }
    view.frame = NSRect(x: 0, y: 0, width: 224, height: 41)
    view.updateSegments(members, active: "b")
    view.layoutSubtreeIfNeeded()
    let buttons = descendants(of: view).compactMap { $0 as? SplitSegmentButton }
    #expect(buttons.map(\.paneTitle) == ["a", "b", "c"])
    buttons[2].performClick(nil)
    #expect(chosen == "c")
    #expect(buttons[1].accessibilityLabel() == "Pane 2 of 3: b")
    #expect(buttons[1].isAccessibilitySelected())
    #expect(!buttons[0].isAccessibilitySelected())
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space", selectedId: "b", spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "pinned", todayId: "today", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [split] + members)
    ]))
    let rows = descendants(of: sidebar).compactMap { $0 as? SidebarRowView }
    #expect(rows.map { $0.row.id } == ["split"])
    let drawn = descendants(of: sidebar).compactMap { $0 as? SplitSegmentButton }
    #expect(drawn.map(\.pane.id) == ["a", "b", "c"])
    // The focused pane is the workspace's selected row, whoever asked for the draw.
    #expect(drawn.map(\.active) == [false, true, false])
}

@Test @MainActor
func splitSegmentsUseSharedFaviconsAndFallBackToTheGlobe() throws {
    let split = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false, id: "split", title: "",
                    url: nil, depth: 0, kind: .split, unloaded: false, lastSelectedAt: nil)
    let members = ["site", "blank"].map { id in
        Row(folderHasTabs: false, parentId: split.id, siblingIndex: 0, collapsed: false, id: id, title: id == "site" ? "Example" : "",
            url: id == "site" ? "https://news.example.com/" : nil, depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "pinned", todayId: "today",
                              favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .default,
                              id: "space", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [split] + members)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: "site", spaces: [space]))
    let segments = descendants(of: sidebar).compactMap { $0 as? SplitSegmentButton }
    let site = try #require(segments.first { $0.pane.id == "site" })
    let blank = try #require(segments.first { $0.pane.id == "blank" })
    let globe = SidebarRowView.symbol(for: .tab)
    #expect(site.iconView.image?.symbolConfiguration == globe.symbolConfiguration)
    #expect(blank.iconView.image?.symbolConfiguration == globe.symbolConfiguration)
    #expect(site.iconView.subviews.isEmpty)

    let favicon = NSImage(size: NSSize(width: 16, height: 16))
    sidebar.favicons["site"] = favicon
    #expect(site.iconView.image === favicon)
    #expect(descendants(of: sidebar).contains { $0 === site })
    sidebar.favicons.removeAll()
    #expect(site.iconView.image?.symbolConfiguration == globe.symbolConfiguration)
}

// The U20 board's split row: one segment per pane from the row's own left inset to its right
// inset, nothing of the row's own behind them, and the focused pane in the row's selected fill.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua]) @MainActor
func splitRowDrawsASegmentPerPane(appearance: NSAppearance.Name) throws {
    let split = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false, id: "split", title: "", url: nil, depth: 0, kind: .split, unloaded: false, lastSelectedAt: nil)
    let members = ["a", "b"].map { id in
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 0, collapsed: false, id: id, title: id, url: "https://\(id).example", depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    let view = SidebarRowView(row: split, selected: true, action: { _ in })
    view.appearance = NSAppearance(named: appearance)
    view.frame = NSRect(x: 0, y: 0, width: 224, height: 41)
    view.updateSegments(members, active: "a")
    view.layoutSubtreeIfNeeded()
    // No row-level glyph, fill or title: the segments are the row.
    let icon = view.subviews.compactMap { $0 as? NSImageView }.first!
    let title = view.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Split" }!
    let rowFill = view.subviews[0]
    #expect(icon.isHidden)
    #expect(title.isHidden)
    #expect(rowFill.isHidden)
    let stack = view.subviews.compactMap { $0 as? NSStackView }.first!
    #expect(!stack.isHidden)
    let segments = stack.arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
    #expect(segments.count == 2)
    let first = view.convert(segments[0].bounds, from: segments[0])
    let second = view.convert(segments[1].bounds, from: segments[1])
    #expect(abs(first.minX) < 0.01 && abs(first.maxX - 111) < 0.01)
    #expect(abs(second.minX - 113) < 0.01 && abs(second.maxX - 224) < 0.01)
    #expect(first.height == SidebarMetrics.rowFillHeight && second.height == SidebarMetrics.rowFillHeight)
    #expect(abs(first.midY - view.bounds.midY) <= 0.5)
    // The row radius on the outer ends, 4 pt inside.
    #expect(segments[0].leadingRadius == 11 && segments[0].trailingRadius == 4)
    #expect(segments[1].leadingRadius == 4 && segments[1].trailingRadius == 11)
    for segment in segments {
        let path = segment.fill.path!.boundingBox
        #expect(abs(path.width - segment.bounds.width) < 0.01 && abs(path.height - segment.bounds.height) < 0.01)
    }
    // The glyph 16 pt at 10 pt and the title 13 pt at 32 pt from the segment's left, both centred.
    let glyph = view.convert(segments[0].iconView.alignmentRect(forFrame: segments[0].iconView.frame), from: segments[0])
    let label = view.convert(segments[0].titleField.alignmentRect(forFrame: segments[0].titleField.frame), from: segments[0])
    #expect(abs(glyph.minX - 10) < 0.01 && abs(glyph.width - 16) < 0.01 && abs(glyph.height - 16) < 0.01)
    #expect(abs(glyph.midY - first.midY) <= 0.5)
    #expect(abs(label.minX - 32) < 0.01)
    #expect(segments[0].titleField.font?.pointSize == 13)
    #expect(segments[0].titleField.lineBreakMode == .byTruncatingTail)
    #expect(segments[0].titleField.maximumNumberOfLines == 1)
    // The focused pane takes the row's selected fill, the other the row's hover fill.
    let tabRow = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "tab", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let selectedRow = SidebarRowView(row: tabRow, selected: true, action: { _ in })
    selectedRow.appearance = view.appearance
    let inactiveAlpha: CGFloat = appearance == .aqua ? 0.06 : 0.08
    let alpha: (CGColor?) -> CGFloat = { colour in colour.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? -1 }
    let selectedFill = try #require(selectedRow.subviews[0].layer?.backgroundColor)
    #expect(abs(selectedFill.alpha - (appearance == .aqua ? 1 : SidebarMetrics.rowSelectedFillAlphaDark)) < 0.001)
    #expect(segments[0].fill.fillColor == selectedFill)
    #expect(abs(alpha(segments[1].fill.fillColor) - inactiveAlpha) < 0.001)
    // The focus moves with the workspace's selection.
    view.updateSegments(members, active: "b")
    view.layoutSubtreeIfNeeded()
    let again = view.subviews.compactMap { $0 as? NSStackView }.first!.arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
    #expect(again[1].fill.fillColor == selectedFill)
    #expect(abs(alpha(again[0].fill.fillColor) - inactiveAlpha) < 0.001)
}

@Test @MainActor
func splitSegmentsRoundTheirOuterEndsOnly() {
    let split = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false, id: "split", title: "", url: nil, depth: 0, kind: .split, unloaded: false, lastSelectedAt: nil)
    let fixture = { (ids: [String]) in ids.map { id in
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 0, collapsed: false, id: id, title: id, url: "https://\(id).example", depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
    } }
    let radii = { (ids: [String]) in
        let view = SidebarRowView(row: split, selected: true, action: { _ in })
        view.frame = NSRect(x: 0, y: 0, width: 224, height: 41)
        view.updateSegments(fixture(ids), active: ids.first)
        view.layoutSubtreeIfNeeded()
        return view.subviews.compactMap { $0 as? NSStackView }.first!.arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
            .map { [$0.leadingRadius, $0.trailingRadius] }
    }
    #expect(radii(["a", "b", "c"]) == [[11, 4], [4, 4], [4, 11]])
    // A lone pane is the whole row, so both of its ends take the row radius.
    #expect(radii(["a"]) == [[11, 11]])
    // A day's panes read as their host; a pane with neither title nor URL keeps Untitled.
    let view = SidebarRowView(row: split, selected: true, action: { _ in })
    view.frame = NSRect(x: 0, y: 0, width: 224, height: 41)
    let unnamed = [
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 0, collapsed: false, id: "a", title: "", url: "https://docs.example.com/start", depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil),
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 1, collapsed: false, id: "b", title: "", url: nil, depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil),
    ]
    view.updateSegments(unnamed, active: nil)
    view.layoutSubtreeIfNeeded()
    let drawn = view.subviews.compactMap { $0 as? NSStackView }.first!.arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
    #expect(drawn.map(\.paneTitle) == ["docs.example.com", "Untitled"])
    #expect(drawn.allSatisfy { !$0.active })
}

@Test @MainActor
func splitSegmentsKeepTheUnloadedAndCrashedLook() {
    let split = Row(folderHasTabs: false, parentId: "today", siblingIndex: 0, collapsed: false, id: "split", title: "", url: nil, depth: 0, kind: .split, unloaded: false, lastSelectedAt: nil)
    let members = ["a", "b"].map { id in
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 0, collapsed: false, id: id, title: id, url: "https://\(id).example", depth: 1, kind: .tab, unloaded: id == "a", lastSelectedAt: nil)
    }
    let view = SidebarRowView(row: split, selected: false, action: { _ in })
    view.frame = NSRect(x: 0, y: 0, width: 224, height: 41)
    view.updateSegments(members, active: "b", crashed: ["b"])
    view.layoutSubtreeIfNeeded()
    let drawn = view.subviews.compactMap { $0 as? NSStackView }.first!.arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
    #expect(drawn.map(\.alphaValue) == [SidebarMetrics.unloadedOpacity, SidebarMetrics.unloadedOpacity])
    #expect(drawn[1].iconView.image?.accessibilityDescription == "Crashed")
}

@Test @MainActor
func rowsKeepPitchIndentAndSplitPlaceholder() {
    for title in ["", "First\nSecond"] {
        let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "split", title: title, url: nil, depth: 1, kind: .split, unloaded: false, lastSelectedAt: nil)
        let view = SidebarRowView(row: row, selected: true, action: { _ in })
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

@Test @MainActor
func nestedFillsIndentTheirLeftEdgeOnly() {
    let rows = (0...2).map {
        Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "row-\($0)", title: "Title", url: nil, depth: UInt32($0), kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: [], pinned: rows, today: [])
    ]))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    for (depth, row) in descendants(of: sidebar).compactMap({ $0 as? SidebarRowView }).enumerated() {
        let fill = row.subviews[0]
        let frame = sidebar.convert(fill.bounds, from: fill)
        #expect(frame.minX == 8 + CGFloat(depth) * 16)
        #expect(frame.maxX == 232)
    }
}

@Test @MainActor
func sidebarWidthClampsAndResets() {
    let sidebar = NSView()
    let handle = SidebarResizeHandle(widthConstraint: sidebar.widthAnchor.constraint(equalToConstant: 240))
    let cases: [(CGFloat, CGFloat)] = [(-10, 164), (163, 164), (164, 164), (320, 320), (500, 500), (501, 500)]
    for (requested, expected) in cases {
        handle.sidebarWidth = requested
        #expect(handle.sidebarWidth == expected)
    }
    handle.resetWidth()
    #expect(handle.sidebarWidth == 240)
}

@Test @MainActor
func sidebarDragPreservesTheGrabOffset() {
    let sidebar = NSView()
    let handle = SidebarResizeHandle(widthConstraint: sidebar.widthAnchor.constraint(equalToConstant: 240))
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 238, y: 300), modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 318, y: 300), modifierFlags: [], timestamp: 1,
                                  windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    handle.mouseDown(with: down)
    handle.mouseDragged(with: drag)
    #expect(handle.sidebarWidth == 320)
}

@Test @MainActor
func rowFocusSurvivesWidthChanges() {
    _ = NSApplication.shared
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "tab", title: "Title", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: [row], pinned: [row], today: [])
    ]))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720), styleMask: [], backing: .buffered, defer: false)
    let content = NSView()
    window.contentView = content
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(sidebar)
    let width = sidebar.widthAnchor.constraint(equalToConstant: 240)
    NSLayoutConstraint.activate([
        sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        sidebar.topAnchor.constraint(equalTo: content.topAnchor),
        sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        width,
    ])
    let handle = SidebarResizeHandle(widthConstraint: width)
    content.addSubview(handle)
    content.layoutSubtreeIfNeeded()
    for focused in [descendants(of: sidebar).first { $0 is SidebarRowView }!, descendants(of: sidebar).first { $0 is FavoriteTile }!] {
        #expect(window.makeFirstResponder(focused))
        for value in [164.0, 500, 200, 240] {
            handle.sidebarWidth = value
            #expect(abs(sidebar.frame.width - value) < 0.01)
            #expect(window.firstResponder === focused)
        }
    }
}

@MainActor
private func urlFieldSidebar(live: String?, width: CGFloat = 240, select: Bool = true) -> SidebarView {
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "url-row", title: "Page", url: "https://saved.example/", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "pinned", todayId: "today", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [row])
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "space", selectedId: select ? "url-row" : nil, spaces: [space])
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    sidebar.widthAnchor.constraint(equalToConstant: width).isActive = true
    sidebar.heightAnchor.constraint(equalToConstant: 720).isActive = true
    sidebar.layoutSubtreeIfNeeded()
    if select, let live { sidebar.focusedPane = ("url-row", live) }
    sidebar.update(snapshot: snapshot)
    sidebar.layoutSubtreeIfNeeded()
    return sidebar
}

@Test @MainActor
func urlFieldContentRuleCoversEveryURLFamily() {
    #expect(URLFieldContent(url: "https://a.example/x", hasTab: true).text == "a.example")
    #expect(URLFieldContent(url: "file:///Users/yosuke/Notes/spec.md", hasTab: true).text == "spec.md")
    #expect(URLFieldContent(url: "data:text/html,<title>x</title>", hasTab: true).text == "data:")
    #expect(URLFieldContent(url: "about:blank", hasTab: true).showsPlaceholder)
    #expect(URLFieldContent(url: "about:blank", hasTab: true).canCopy)
    #expect(URLFieldContent(url: "about:preferences", hasTab: true).showsGear)
    #expect(URLFieldContent(url: "chrome://newtab/", hasTab: true).showsPlaceholder)
    #expect(URLFieldContent(url: "chrome://settings/", hasTab: true).text == "chrome://settings/")
    #expect(URLFieldContent(url: "chrome://settings/", hasTab: true).showsGear)
    #expect(URLFieldContent(url: "view-source:https://a.example/", hasTab: true).showsGear)
    // S5: userinfo cannot spoof the host the field shows.
    #expect(URLFieldContent(url: "https://google.com@evil.example/", hasTab: true).text == "evil.example")
    #expect(URLFieldContent(url: "https://user:pw@real.example:8443/", hasTab: true).text == "real.example")
    #expect(URLFieldContent(url: "data:text/html,<title>x</title>", hasTab: true).accessibilityValue == "data:")
    #expect(URLFieldContent(url: "about:blank", hasTab: true).accessibilityValue == URLFieldContent.placeholderText)
    #expect(URLFieldContent(url: "chrome://settings/", hasTab: true).accessibilityValue == "chrome://settings/")
    #expect(URLFieldContent(url: nil, hasTab: true).showsPlaceholder)
    #expect(!URLFieldContent(url: nil, hasTab: true).hidesButtons)
    // S2: no URL, nothing to copy even with a tab.
    #expect(!URLFieldContent(url: nil, hasTab: true).canCopy)
    #expect(URLFieldContent(url: nil, hasTab: false).hidesButtons)
    #expect(!URLFieldContent(url: nil, hasTab: false).canCopy)
}

@Test @MainActor
func urlFieldShowsEachFamilyInTheView() {
    let host = urlFieldSidebar(live: "https://docs.example.com/spec")
    #expect(host.urlHostForCheck == "docs.example.com")
    #expect(!host.urlFieldShowsPlaceholder)
    #expect(!host.urlFieldShowsGear)
    #expect(host.urlFieldCopyLinkVisible && host.urlFieldSiteControlsVisible)
    #expect(host.urlFieldCopyLinkEnabled)

    let file = urlFieldSidebar(live: "file:///Users/yosuke/Notes/spec.md")
    #expect(file.urlHostForCheck == "spec.md")

    let data = urlFieldSidebar(live: "data:text/html,<title>x</title>")
    #expect(data.urlHostForCheck == "data:")
    #expect(!data.urlFieldShowsPlaceholder)

    for blank in ["about:blank", "chrome://newtab/"] {
        let view = urlFieldSidebar(live: blank)
        #expect(view.urlFieldShowsPlaceholder)
        #expect(view.urlFieldCopyLinkVisible && view.urlFieldSiteControlsVisible)
        #expect(view.urlFieldCopyLinkEnabled)
    }

    let settings = urlFieldSidebar(live: "chrome://settings/")
    #expect(settings.urlFieldShowsGear)
    #expect(settings.urlHostForCheck == "chrome://settings/")

    // A failed navigation keeps its failed URL, so the host is still the site's.
    let failed = urlFieldSidebar(live: "http://localhost:9/unreachable")
    #expect(failed.urlHostForCheck == "localhost")

    let none = urlFieldSidebar(live: nil, select: false)
    #expect(none.urlFieldShowsPlaceholder)
    #expect(!none.urlFieldCopyLinkVisible)
    #expect(!none.urlFieldSiteControlsVisible)
    #expect(!none.urlFieldCopyLinkEnabled)
    #expect(none.urlFieldPlaceholderText == "Search or enter URL")
}

@Test @MainActor
func longHostKeepsItsEndAtBothWidths() {
    let url = "https://averyveryveryverylongsubdomainname.docs.example.com/path"
    for width in [240.0, 164] {
        let sidebar = urlFieldSidebar(live: url, width: width)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.urlHostForCheck == "averyveryveryverylongsubdomainname.docs.example.com")
        let label = sidebar.checkHostLabelFrame
        let clip = sidebar.checkHostClipFrame
        #expect(label.minX < clip.minX)
        #expect(abs(label.maxX - clip.maxX) <= 0.5)
        #expect(sidebar.urlFieldHostHasLeadingFade)
    }
    let short = urlFieldSidebar(live: "https://a.example/", width: 164)
    short.layoutSubtreeIfNeeded()
    short.layoutSubtreeIfNeeded()
    #expect(abs(short.checkHostLabelFrame.minX - short.checkHostClipFrame.minX) <= 0.5)
    #expect(!short.urlFieldHostHasLeadingFade)
    // D6 applies to the host only: a long file name or internal URL keeps its start. Its tail is
    // now cut by the field's own tail truncation inside the text area (an ellipsis, U25a2), not
    // by the clip container, which cut it with no ellipsis.
    for other in ["file:///Users/yosuke/Notes/a-very-long-file-name-for-the-url-field-check.md",
                  "chrome://settings/a-very-long-internal-path-for-the-url-field-check"] {
        let view = urlFieldSidebar(live: other, width: 240)
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.checkHostLabelFrame.minX - view.checkHostClipFrame.minX) <= 0.5)
        #expect(abs(view.checkHostLabelFrame.maxX - view.checkHostClipFrame.maxX) <= 0.5)
        #expect(!view.urlFieldHostHasLeadingFade)
    }
}

@Test @MainActor
func urlFieldAndButtonsKeepTheBoardGeometryAndStates() {
    let sidebar = urlFieldSidebar(live: "https://a.example/")
    #expect(sidebar.urlField.layer?.cornerRadius == 11)
    #expect(sidebar.urlField.frame.height == 36)
    let copy = sidebar.urlFieldCopyButton
    let site = sidebar.urlFieldSiteControlsButton
    #expect(copy.frame.width == 24)
    #expect(copy.frame.height == 24)
    #expect(copy.layer?.cornerRadius == 6 && site.layer?.cornerRadius == 6)
    #expect(copy.checkBackgroundAlpha == 0)
    copy.isHovered = true
    #expect(copy.checkBackgroundAlpha == 0.07)
    copy.isPressed = true
    #expect(copy.checkBackgroundAlpha == 0.14)
    copy.isHovered = false
    copy.isPressed = false
    copy.showsCopied = true
    #expect(copy.checkImageIsTick())
    copy.showsCopied = false
    #expect(!copy.checkImageIsTick())
}


@Test @MainActor
func placeholderTruncatesWithAnEllipsisAtTheNarrowWidth() {
    let sidebar = urlFieldSidebar(live: "about:blank", width: 164)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.urlFieldShowsPlaceholder)
    let label = sidebar.checkHostLabelFrame
    let clip = sidebar.checkHostClipFrame
    // "Search or enter URL" is wider than the text area at 164, so the label is clamped to it and
    // the field's tail truncation turns the cut into an ellipsis. An intrinsic-width frame drew
    // "Search or e" with no ellipsis (U25a2).
    #expect(sidebar.urlFieldPlaceholderLineBreakMode == .byTruncatingTail)
    #expect(sidebar.checkHostLabelIntrinsicWidth > clip.width + 0.5)
    #expect(abs(label.width - clip.width) <= 0.5)
    #expect(label.minX >= clip.minX - 0.5 && label.maxX <= clip.maxX + 0.5)
    #expect(!sidebar.urlFieldHostHasLeadingFade)
    // D6 still holds for a host at the same width: it keeps its width, sits at the trailing edge
    // and fades its start.
    let long = urlFieldSidebar(live: "https://averyveryveryverylongsubdomainname.docs.example.com/path", width: 164)
    long.layoutSubtreeIfNeeded()
    long.layoutSubtreeIfNeeded()
    #expect(long.urlFieldHostHasLeadingFade)
    #expect(abs(long.checkHostLabelFrame.maxX - long.checkHostClipFrame.maxX) <= 0.5)
    #expect(long.checkHostLabelFrame.minX < long.checkHostClipFrame.minX)
}

@Test @MainActor
func urlFieldButtonsTakeKeyboardFocusOnlyWithFullKeyboardAccess() {
    _ = NSApplication.shared
    let previous = URLFieldButton.fullKeyboardAccess
    defer { URLFieldButton.fullKeyboardAccess = previous }
    URLFieldButton.fullKeyboardAccess = { false }
    let copy = URLFieldButton(role: .copyLink)
    let site = URLFieldButton(role: .siteControls)
    #expect(!copy.acceptsFirstResponder && !site.acceptsFirstResponder)
    URLFieldButton.fullKeyboardAccess = { true }
    #expect(copy.acceptsFirstResponder && site.acceptsFirstResponder)
    // With Full Keyboard Access on the button can take focus and draws the board's ring there;
    // leaving it takes the ring away again. The mouse-down and disabled-button rules are
    // urlFieldButtonsFollowTheKeyboardFocusRule.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(copy)
    #expect(window.makeFirstResponder(copy))
    #expect(copy.showsFocusRing)
    _ = window.makeFirstResponder(nil)
    #expect(!copy.showsFocusRing)
}

@Test @MainActor
func urlFieldButtonsFollowTheKeyboardFocusRule() {
    // F1: with Full Keyboard Access on, a mouse down still refuses focus, so a click cannot take
    // it from the page (AppKit can make the hit view first responder before `mouseDown` runs).
    #expect(!URLFieldButton.keyboardFocusAllowed(fullKeyboardAccess: true, isEnabled: true,
                                                 refusesFirstResponder: false, currentEvent: .leftMouseDown))
    // Tab arrives as a key event: the keyboard path keeps the focus and its ring.
    #expect(URLFieldButton.keyboardFocusAllowed(fullKeyboardAccess: true, isEnabled: true,
                                                refusesFirstResponder: false, currentEvent: .keyDown))
    #expect(URLFieldButton.keyboardFocusAllowed(fullKeyboardAccess: true, isEnabled: true,
                                                refusesFirstResponder: false, currentEvent: nil))
    #expect(!URLFieldButton.keyboardFocusAllowed(fullKeyboardAccess: false, isEnabled: true,
                                                 refusesFirstResponder: false, currentEvent: .keyDown))
    // F3: a disabled Copy Link and the scroll-preview copies (which refuse the responder) are not
    // key-view stops.
    #expect(!URLFieldButton.keyboardFocusAllowed(fullKeyboardAccess: true, isEnabled: false,
                                                 refusesFirstResponder: false, currentEvent: .keyDown))
    #expect(!URLFieldButton.keyboardFocusAllowed(fullKeyboardAccess: true, isEnabled: true,
                                                 refusesFirstResponder: true, currentEvent: .keyDown))
}

@Test @MainActor
func fieldTextInsetAndGlyphStepFollowTheStepRule() {
    let plain = urlFieldSidebar(live: "https://a.example/")
    plain.layoutSubtreeIfNeeded()
    let plainField = plain.convert(plain.urlField.bounds, from: plain.urlField)
    #expect(abs(plain.checkHostClipFrame.minX - plainField.minX - 8) <= 0.5)
    let gear = urlFieldSidebar(live: "chrome://settings/")
    gear.layoutSubtreeIfNeeded()
    let gearField = gear.convert(gear.urlField.bounds, from: gear.urlField)
    #expect(abs(gear.checkHostClipFrame.minX - gearField.minX - 32) <= 0.5)
    let privateWindow = urlFieldSidebar(live: "https://a.example/")
    privateWindow.privateWindow = true
    privateWindow.layoutSubtreeIfNeeded()
    let privateField = privateWindow.convert(privateWindow.urlField.bounds, from: privateWindow.urlField)
    #expect(abs(privateWindow.checkHostClipFrame.minX - privateField.minX - 32) <= 0.5)
}

@Test @MainActor
func hostLeadingFadeUsesTheUnroundedCellWidth() throws {
    let host = NSTextField(labelWithString: "127.0.0.1")
    host.font = .systemFont(ofSize: 13)
    let placeholder = NSTextField(labelWithString: "")
    placeholder.isHidden = true
    let clip = URLFieldTextClipView(host: host, placeholder: placeholder)
    clip.fadesStart = true

    let cellWidth = try #require(host.cell).cellSize.width
    let width = cellWidth + 0.1
    try #require(width < ceil(cellWidth))
    clip.setFrameSize(NSSize(width: width, height: URLFieldTextClipView.height))
    #expect(!clip.checkHasFade)
    #expect(host.frame.minX == 0)

    host.stringValue = "averylongsubdomain.example.com"
    clip.needsLayout = true
    clip.layoutSubtreeIfNeeded()
    #expect(clip.checkHasFade)
    #expect(host.frame.minX < 0)
}

@Test @MainActor
func hostLabelsDrawTheirFullTextAtBothSidebarWidths() throws {
    let hosts = ["127.0.0.1", "[::1]", "localhost", "intranet",
                 "averyveryveryverylongsubdomainname.docs.example.com"]
    for width: CGFloat in [240, 164] {
        for host in hosts {
            let sidebar = urlFieldSidebar(live: "http://\(host):8080/path", width: width)
            let clip = try #require(sidebar.urlField.subviews.compactMap { $0 as? URLFieldTextClipView }.first)
            let label = clip.host
            #expect(label.stringValue == host)
            #expect(sidebar.checkURLFieldAccessibilityValue == host)

            let overflows = host == hosts.last
            #expect(sidebar.urlFieldHostHasLeadingFade == overflows)
            #expect(sidebar.checkHostLabelFits == !overflows)
            if overflows {
                #expect(label.frame.minX < 0)
                #expect(abs(label.frame.maxX - clip.bounds.maxX) <= 0.5)
            } else {
                #expect(label.frame.minX == 0)
                #expect(label.frame.maxX <= clip.bounds.maxX)
            }

            let bounds = label.bounds
            let actual = try #require(label.bitmapImageRepForCachingDisplay(in: bounds))
            label.cacheDisplay(in: bounds, to: actual)
            label.frame.size.width += 20
            defer { label.frame.size.width = bounds.width }
            let reference = try #require(label.bitmapImageRepForCachingDisplay(in: bounds))
            label.cacheDisplay(in: bounds, to: reference)
            let byteCount = actual.bytesPerRow * actual.pixelsHigh
            let actualPixels = Data(bytes: try #require(actual.bitmapData), count: byteCount)
            let referencePixels = Data(bytes: try #require(reference.bitmapData), count: byteCount)
            #expect(actualPixels == referencePixels, "\(host) at sidebar width \(width)")
        }
    }
}
