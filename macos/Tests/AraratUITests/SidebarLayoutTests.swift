import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
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
    let buttons = descendants(of: view).compactMap { $0 as? NSButton }.filter { ["a", "b", "c"].contains($0.title) }
    #expect(buttons.map(\.title) == ["a", "b", "c"])
    buttons[2].performClick(nil)
    #expect(chosen == "c")
    let icon = view.subviews.compactMap { $0 as? NSImageView }.first!
    #expect(!icon.isHidden)
    for button in buttons {
        let fill = button.layer?.sublayers?.first { $0.name == "split-segment-fill" }
        #expect(fill != nil)
        if let frame = fill?.frame {
            #expect(frame.minX == 4 && frame.maxX == button.bounds.maxX - 4)
            #expect(frame.minY == 4 && frame.maxY == button.bounds.maxY - 4)
            #expect(view.convert(frame, from: button).minX > view.convert(icon.bounds, from: icon).maxX)
        }
    }
    #expect(buttons[1].layer?.sublayers?.first { $0.name == "split-segment-fill" }?.backgroundColor != buttons[0].layer?.sublayers?.first { $0.name == "split-segment-fill" }?.backgroundColor)
    #expect(buttons[1].accessibilityLabel() == "Pane 2 of 3: b")
    #expect(buttons[1].isAccessibilitySelected())
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space", selectedId: "b", spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "pinned", todayId: "today", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "space", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [split] + members)
    ]))
    let rows = descendants(of: sidebar).compactMap { $0 as? SidebarRowView }
    #expect(rows.map { $0.row.id } == ["split"])
    #expect(descendants(of: sidebar).compactMap { $0 as? NSButton }.filter { ["a", "b", "c"].contains($0.title) }.count == 3)
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
    // D6 applies to the host only: a long file name or internal URL keeps its start.
    for other in ["file:///Users/yosuke/Notes/a-very-long-file-name-for-the-url-field-check.md",
                  "chrome://settings/a-very-long-internal-path-for-the-url-field-check"] {
        let view = urlFieldSidebar(live: other, width: 240)
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.checkHostLabelFrame.minX - view.checkHostClipFrame.minX) <= 0.5)
        #expect(view.checkHostLabelFrame.maxX > view.checkHostClipFrame.maxX)
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
