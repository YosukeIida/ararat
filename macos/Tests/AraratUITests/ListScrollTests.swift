import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func listDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + listDescendants($0) }
}

private func listRow(_ id: String) -> Row {
    Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: id, title: "Tab \(id)", url: "https://example.com/\(id)", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
}

private func listSnapshot(_ count: Int = 45, selected: String? = "t0") -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: selected, spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil,
                      favorites: [listRow("favorite")], pinned: [listRow("pin")], today: (0..<count).map { listRow("t\($0)") }),
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "home", title: "Home", icon: nil, look: nil,
                      favorites: [], pinned: [], today: [listRow("home-tab")])
    ])
}

@MainActor
private func listWindow(_ snapshot: WorkspaceSnapshot = listSnapshot()) -> (NSWindow, SidebarView, NSScrollView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    let sidebar = SidebarView(snapshot: snapshot)
    window.contentView = sidebar
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let scroll = listDescendants(sidebar).compactMap { $0 as? NSScrollView }.first { $0.documentView?.subviews.contains { $0 is NSStackView } == true }!
    return (window, sidebar, scroll)
}

@MainActor
private func frame(_ id: String, in sidebar: SidebarView) throws -> NSRect {
    let row = try #require(listDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == id })
    return try #require(row.enclosingScrollView?.documentView).convert(row.bounds, from: row)
}

@MainActor
private func position(_ y: CGFloat, _ scroll: NSScrollView) {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
}

@Test @MainActor
func listRevealUsesNearestEdgeAndDoesNotMoveVisibleRows() async throws {
    let (window, sidebar, scroll) = listWindow()
    defer { window.contentView = nil }
    position(800, scroll)
    let top = try frame("t3", in: sidebar).minY
    #expect(sidebar.selectRow(id: "t3"))
    try await waitUntil { abs(scroll.contentView.bounds.minY - top) < 0.1 }
    let below = try frame("t36", in: sidebar).maxY - scroll.contentView.bounds.height
    #expect(sidebar.selectRow(id: "t36"))
    try await waitUntil { abs(scroll.contentView.bounds.minY - below) < 0.1 }
    let origin = scroll.contentView.bounds.origin
    #expect(sidebar.selectRow(id: "t35"))
    #expect(scroll.contentView.bounds.origin == origin)
}

@Test @MainActor
func listRevealsSelectionRestoreAndSpaceLandingButNotBackgroundChanges() async throws {
    var snapshot = listSnapshot()
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    snapshot.selectedId = "t40"
    sidebar.applySelection(snapshot: snapshot)
    let selectedFrame = try frame("t40", in: sidebar)
    try await waitUntil { scroll.contentView.bounds.contains(selectedFrame) }
    sidebar.showSpace(at: 1)
    sidebar.showSpace(at: 0)
    let landedFrame = try frame("t40", in: sidebar)
    try await waitUntil { scroll.contentView.bounds.contains(landedFrame) }
    sidebar.setLibraryOpen(true)
    snapshot.selectedId = "t1"
    sidebar.applyRestore(snapshot: snapshot)
    let restoredTop = try frame("t1", in: sidebar).minY
    try await waitUntil { abs(scroll.contentView.bounds.minY - restoredTop) < 0.1 }
    position(800, scroll)
    let backgroundOrigin = scroll.contentView.bounds.origin
    (scroll as? SidebarScrollView)?.reduceMotion = { true }
    sidebar.applySelection(snapshot: snapshot)
    #expect(scroll.contentView.bounds.origin == backgroundOrigin)
    sidebar.updateSelection(id: "closed-folder-child")
    #expect(scroll.contentView.bounds.origin == backgroundOrigin)
}

@Test @MainActor
func listKeepsVisibleRowsFixedAcrossInsertAndCloseAbove() throws {
    var snapshot = listSnapshot()
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    position(800, scroll)
    let before = try frame("t22", in: sidebar).minY - scroll.contentView.bounds.minY
    snapshot.spaces[0].today.insert(listRow("inserted"), at: 0)
    sidebar.update(snapshot: snapshot)
    #expect(abs(try frame("t22", in: sidebar).minY - scroll.contentView.bounds.minY - before) < 0.1)
    let beforeClose = try frame("t22", in: sidebar).minY - scroll.contentView.bounds.minY
    snapshot.spaces[0].today.removeFirst()
    sidebar.applyClose(id: "inserted", snapshot: snapshot)
    #expect(abs(try frame("t22", in: sidebar).minY - scroll.contentView.bounds.minY - beforeClose) < 0.1)
}

@Test @MainActor
func listHairlinesFollowEdgesAppearanceAndNonScrollingContent() throws {
    for count in [2, 45] {
        let (window, sidebar, scroll) = listWindow(listSnapshot(count))
        defer { window.contentView = nil }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            sidebar.appearance = NSAppearance(named: name)
            scroll.viewDidChangeEffectiveAppearance()
            let top = try #require(scroll.layer?.sublayers?.first { $0.name == "list.top" })
            let bottom = try #require(scroll.layer?.sublayers?.first { $0.name == "list.bottom" })
            let maximum = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
            for y in [CGFloat(0), maximum / 2, maximum] {
                position(y, scroll)
                #expect(top.opacity == (y > 0 ? 1 : 0))
                #expect(bottom.opacity == (y < maximum ? 1 : 0))
                #expect(top.bounds.height == 1 && bottom.bounds.height == 1)
                #expect(abs(top.backgroundColor!.alpha - (name == .aqua ? 0.05 : 0.07)) < 0.00001)
            }
        }
    }
}

@Test @MainActor
func listPinnedScrollsWhileFavoritesAndHeaderStayFixed() throws {
    let (window, sidebar, scroll) = listWindow()
    defer { window.contentView = nil }
    let tile = try #require(listDescendants(sidebar).first { $0 is FavoriteTile })
    let header = try #require(listDescendants(sidebar).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Work" })
    let fixed = [tile, header].map { sidebar.convert($0.bounds, from: $0) }
    let pin = try #require(listDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "pin" })
    let before = sidebar.convert(pin.bounds, from: pin)
    position(400, scroll)
    #expect([tile, header].map { sidebar.convert($0.bounds, from: $0) } == fixed)
    #expect(abs(sidebar.convert(pin.bounds, from: pin).minY - before.minY - 400) < 0.1)
}

@Test @MainActor
func listCaptures() throws {
    guard let directory = ProcessInfo.processInfo.environment["ARARAT_LIST_CAPTURES"] else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let (window, sidebar, scroll) = listWindow()
    defer { window.contentView = nil }
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        sidebar.appearance = NSAppearance(named: name)
        scroll.viewDidChangeEffectiveAppearance()
        let maximum = scroll.documentView!.frame.height - scroll.contentView.bounds.height
        for (label, y) in [("top", CGFloat(0)), ("middle", maximum / 2), ("bottom", maximum)] {
            position(y, scroll)
            for line in scroll.layer?.sublayers ?? [] where line.name?.hasPrefix("list.") == true { line.removeAllAnimations() }
            window.displayIfNeeded()
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 720, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
            context.setFillColor((name == .aqua ? NSColor.white : NSColor.black).cgColor)
            context.fill(sidebar.bounds)
            sidebar.layer?.render(in: context)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name.rawValue)-\(label).png"))
            #expect(!window.isVisible)
        }
    }
}

@MainActor
private func listEvent(dx: Int32, dy: Int32, phase: CGScrollPhase) -> NSEvent {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    cg.timestamp = 100_000_000_000
    return NSEvent(cgEvent: cg)!
}

@Test @MainActor
func listScrollerWaitsForVerticalIntentAndKeepsSystemStyle() throws {
    let (window, sidebar, scroll) = listWindow()
    defer { window.contentView = nil }
    let style = scroll.scrollerStyle
    scroll.scrollWheel(with: listEvent(dx: 0, dy: 0, phase: .mayBegin))
    if style == .overlay { #expect(!scroll.hasVerticalScroller) }
    scroll.scrollWheel(with: listEvent(dx: -20, dy: 0, phase: .began))
    if style == .overlay { #expect(!scroll.hasVerticalScroller) }
    #expect(scroll.scrollerStyle == style)
    scroll.scrollWheel(with: listEvent(dx: 0, dy: 0, phase: .ended))
    scroll.scrollWheel(with: listEvent(dx: 0, dy: -20, phase: .began))
    #expect(scroll.hasVerticalScroller)
    #expect(scroll.scrollerStyle == style)
    sidebar.showSpace(at: 0)
    scroll.scrollerStyle = .legacy
    scroll.scrollWheel(with: listEvent(dx: -20, dy: 0, phase: .began))
    #expect(scroll.hasVerticalScroller && scroll.scrollerStyle == .legacy)
}

@Test @MainActor
func listRevealUsesPointTwentyTwoSecondsEaseOutAndReduceMotionJumps() throws {
    var snapshot = listSnapshot()
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    let list = try #require(scroll as? SidebarScrollView)
    var time = 10.0
    list.clock = { time }
    list.reduceMotion = { false }
    let target = try frame("t40", in: sidebar).maxY - scroll.contentView.bounds.height
    #expect(sidebar.selectRow(id: "t40"))
    #expect(scroll.contentView.bounds.minY == 0)
    time += 0.11
    list.stepReveal()
    #expect(abs(scroll.contentView.bounds.minY - target * 0.875) <= 1)
    snapshot.selectedId = "t40"
    sidebar.applySelection(snapshot: snapshot)
    time += 0.111
    list.stepReveal()
    #expect(abs(scroll.contentView.bounds.minY - target) < 0.1)
    list.reduceMotion = { true }
    #expect(sidebar.selectRow(id: "t0"))
    #expect(abs(scroll.contentView.bounds.minY - (try frame("t0", in: sidebar).minY)) < 0.1)
    time += 1
    list.stepReveal()
    #expect(abs(scroll.contentView.bounds.minY - (try frame("t0", in: sidebar).minY)) < 0.1)
}

@Test @MainActor
func listKeyboardSelectionAndCreatedTabRevealWithoutOrderingWindow() throws {
    var snapshot = listSnapshot()
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    let list = try #require(scroll as? SidebarScrollView)
    list.reduceMotion = { true }
    let row = try #require(listDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "t40" })
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    row.keyDown(with: key)
    #expect(sidebar.selectedRowID == "t40")
    #expect(scroll.contentView.bounds.contains(try frame("t40", in: sidebar)))
    snapshot.spaces[0].today.insert(listRow("new-tab"), at: 0)
    snapshot.selectedId = "new-tab"
    sidebar.applySelection(snapshot: snapshot)
    #expect(scroll.contentView.bounds.contains(try frame("new-tab", in: sidebar)))
    sidebar.showCreateSpace()
    snapshot.spaces.append(SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "created", title: "Created", icon: nil, look: nil, favorites: [], pinned: [], today: []))
    snapshot.shownSpaceId = "created"
    snapshot.selectedId = nil
    sidebar.applyCreatedSpace(snapshot: snapshot)
    #expect(sidebar.spaceShown == 2 && !sidebar.createSpaceOpen)
    #expect(!window.isVisible)
}

@Test @MainActor
func listDoesNotRevealASelectedChildOmittedByACollapsedFolder() throws {
    var snapshot = listSnapshot()
    snapshot.spaces[0].pinned.append(Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "folder", title: "Closed", url: nil, depth: 0, kind: .folder, unloaded: false, lastSelectedAt: nil))
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    let list = try #require(scroll as? SidebarScrollView)
    list.reduceMotion = { true }
    position(800, scroll)
    let origin = scroll.contentView.bounds.origin
    snapshot.selectedId = "hidden-child"
    sidebar.applySelection(snapshot: snapshot)
    #expect(sidebar.selectedRowID == "hidden-child")
    #expect(!sidebar.selectRow(id: "hidden-child"))
    #expect(scroll.contentView.bounds.origin == origin)
    sidebar.showSpace(at: 1)
    sidebar.showSpace(at: 0)
    let landedOrigin = scroll.contentView.bounds.origin
    list.stepReveal()
    #expect(scroll.contentView.bounds.origin == landedOrigin)
}

@MainActor
private final class NativeListScrollProbe: SidebarScrollView {
    var phases: [NSEvent.Phase] = []
    override func scrollNatively(with event: NSEvent) {
        phases.append(event.phase)
        super.scrollNatively(with: event)
    }
}

@Test @MainActor
func listNativeScrollReceivesGestureStartsAndCancellationInOrder() {
    let scroll = NativeListScrollProbe(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
    scroll.hasVerticalScroller = true
    scroll.onScroll = { abs($0.scrollingDeltaX) > abs($0.scrollingDeltaY) }
    for phase: CGScrollPhase in [.mayBegin, .began, .changed, .ended] {
        scroll.scrollWheel(with: listEvent(dx: 0, dy: phase == .changed ? -10 : 0, phase: phase))
    }
    #expect(scroll.phases == [.mayBegin, .began, .changed, .ended])
    scroll.phases.removeAll()
    for phase: CGScrollPhase in [.mayBegin, .cancelled] {
        scroll.scrollWheel(with: listEvent(dx: 0, dy: 0, phase: phase))
    }
    #expect(scroll.phases == [.mayBegin, .cancelled])
    scroll.phases.removeAll()
    scroll.scrollWheel(with: listEvent(dx: -20, dy: 0, phase: .began))
    #expect(scroll.phases.isEmpty)
    if scroll.scrollerStyle == .overlay { #expect(!scroll.hasVerticalScroller) }
}

@Test @MainActor
func listInsertAtTopKeepsNewUnselectedRowVisible() throws {
    var snapshot = listSnapshot()
    snapshot.spaces[0].pinned = []
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    #expect(scroll.contentView.bounds.minY == 0)
    snapshot.spaces[0].today.insert(listRow("background-tab"), at: 0)
    sidebar.applySelection(snapshot: snapshot)
    #expect(scroll.contentView.bounds.minY == 0)
    #expect(scroll.contentView.bounds.contains(try frame("background-tab", in: sidebar)))
}

@Test @MainActor
func listArchiveDeletePublishDoesNotRevealUnchangedSelection() throws {
    var snapshot = listSnapshot()
    snapshot.archive = [ArchiveEntry(id: "archived", title: "Archived", url: "https://example.com/archived", lifecycleChangedAt: 1)]
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    let list = try #require(scroll as? SidebarScrollView)
    list.reduceMotion = { true }
    position(800, scroll)
    let origin = scroll.contentView.bounds.origin
    sidebar.setLibraryOpen(true)
    sidebar.onArchiveDelete = { [weak sidebar] id in
        snapshot.archive.removeAll { $0.id == id }
        sidebar?.applySelection(snapshot: snapshot)
    }
    sidebar.onArchiveDelete?("archived")
    sidebar.setLibraryOpen(false)
    #expect(snapshot.archive.isEmpty)
    #expect(scroll.contentView.bounds.origin == origin)
}

@Test @MainActor
func listExplicitSelectRevealsAnUnchangedSelection() throws {
    let snapshot = listSnapshot()
    let (window, sidebar, scroll) = listWindow(snapshot)
    defer { window.contentView = nil }
    let list = try #require(scroll as? SidebarScrollView)
    list.reduceMotion = { true }
    position(800, scroll)
    sidebar.applySelection(snapshot: snapshot)
    #expect(scroll.contentView.bounds.minY == 800)
    sidebar.revealSelection()
    #expect(scroll.contentView.bounds.contains(try frame("t0", in: sidebar)))
}
