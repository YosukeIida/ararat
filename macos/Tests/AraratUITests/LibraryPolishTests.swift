import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
}

@MainActor
private func fixture() -> (NSWindow, SidebarView, SidebarContainerView, NSView) {
    _ = NSApplication.shared
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "tab", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: "tab", spaces: [
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "home", title: "Home", icon: nil, look: nil, favorites: [], pinned: [], today: [row])
    ]))
    let page = NSView()
    let container = SidebarContainerView(sidebar: sidebar, page: page)
    container.applicationActive = { true }
    container.windowKey = { true }
    container.pressedButtons = { 0 }
    container.pointerLocation = { NSPoint(x: 2000, y: 300) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    container.selectionChanged()
    return (window, sidebar, container, page)
}

@Test @MainActor
func fullscreenSidebarRemainsReachableWithoutSelection() {
    let (window, sidebar, container, _) = fixture()
    defer { window.contentView = nil }
    container.windowFullscreen = true
    #expect(container.sidebarState == "hidden")
    sidebar.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    container.selectionChanged()
    #expect(container.sidebarState == "floating")
    container.windowFullscreen = false
    container.windowFullscreen = true
    container.processPointer()
    #expect(container.sidebarState == "floating")
}

@Test @MainActor
func libraryOpeningFocusesSearchOnceAfterButtonMotion() throws {
    let (window, sidebar, container, page) = fixture()
    defer { window.contentView = nil }
    window.makeFirstResponder(sidebar)
    sidebar.toggleLibrary()
    let search = try #require(descendants(sidebar).compactMap { $0 as? NSSearchField }.first)
    #expect(search.currentEditor() == nil)
    container.finishMotion()
    #expect(search.currentEditor() === window.firstResponder)
    window.makeFirstResponder(sidebar)
    container.finishMotion()
    #expect(window.firstResponder === sidebar)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 800, y: 300), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    page.mouseDown(with: event)
    #expect(sidebar.libraryOpen)
    #expect(!window.isVisible)
}

@Test @MainActor
func hiddenSidebarStaysVisibleUntilLibraryCloses() {
    let (window, sidebar, container, _) = fixture()
    defer { window.contentView = nil }
    container.toggleSidebar()
    #expect(container.sidebarState == "hidden")
    sidebar.toggleLibrary()
    #expect(container.sidebarState == "docked")
    container.processPointer()
    #expect(container.sidebarState == "docked")
    sidebar.cancelOperation(nil)
    #expect(container.sidebarState == "hidden")
    #expect(!window.isVisible)
}

@Test @MainActor
func closingLibraryBeforeLandingKeepsTheCurrentResponder() {
    let (window, sidebar, container, _) = fixture()
    defer { window.contentView = nil }
    window.makeFirstResponder(sidebar)
    sidebar.toggleLibrary()
    sidebar.cancelOperation(nil)
    container.finishMotion()
    sidebar.finishScrollPresentation()
    #expect(!sidebar.libraryOpen && window.firstResponder === sidebar)
}

@Test @MainActor
func archiveEmptyMessagesAreCenteredInTheListArea() throws {
    let (window, sidebar, container, _) = fixture()
    defer { window.contentView = nil }
    sidebar.toggleLibrary()
    container.layoutSubtreeIfNeeded()
    let library = try #require(descendants(sidebar).compactMap { $0 as? LibraryView }.first)
    let label = try #require(descendants(library).compactMap { $0 as? NSTextField }.first { $0.stringValue == "No archived tabs" })
    let scroll = try #require(descendants(library).compactMap { $0 as? NSScrollView }.first)
    #expect(label.alignment == .center && label.textColor == .secondaryLabelColor)
    let rect = label.convert(label.bounds, to: library)
    let listRect = scroll.convert(scroll.bounds, to: library)
    #expect(abs(rect.midX - listRect.midX) <= 0.5)
    #expect(abs(rect.midY - listRect.midY) <= 0.5)
    _ = sidebar.searchArchive("missing")
    #expect(label.stringValue == "No matching tabs")
}

@Test @MainActor
func pageMaskExistsOnlyWhileFloatingOrTransitioningFromFloating() {
    let (window, _, container, page) = fixture()
    defer { window.contentView = nil }
    #expect(page.layer?.mask == nil)
    container.toggleSidebar()
    container.finishMotion()
    #expect(page.layer?.mask == nil)
    var now = 0.0
    container.clock = { now }
    container.pointerLocation = { NSPoint(x: 0, y: 300) }
    container.processPointer()
    now = SidebarMetrics.revealDwell
    container.processPointer()
    #expect(container.sidebarState == "floating" && page.layer?.mask != nil)
    container.finishMotion()
    #expect(page.layer?.mask != nil)
    container.toggleSidebar()
    #expect(container.sidebarState == "docked" && page.layer?.mask != nil)
    container.finishMotion()
    #expect(page.layer?.mask == nil)
    container.toggleSidebar()
    now += SidebarMetrics.revealDwell
    container.processPointer()
    #expect(container.sidebarState == "floating" && page.layer?.mask != nil)
    container.pointerLocation = { NSPoint(x: 2000, y: 300) }
    container.processPointer()
    #expect(page.layer?.mask != nil)
    container.finishMotion()
    #expect(container.sidebarState == "hidden" && page.layer?.mask == nil)
}

@Test @MainActor
func librarySearchWaitsForSwipeLandingAndIgnoresSpringBack() throws {
    let (window, sidebar, container, _) = fixture()
    defer { window.contentView = nil }
    window.makeFirstResponder(sidebar)
    let event: (Int32, CGScrollPhase?, Double) -> NSEvent = { dx, phase, time in
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        cg.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }
    sidebar.scrollWheel(with: event(20, .began, 100))
    #expect(window.firstResponder === sidebar)
    sidebar.scrollWheel(with: event(0, .ended, 101))
    sidebar.finishScrollPresentation()
    #expect(!sidebar.libraryOpen && window.firstResponder === sidebar)
    sidebar.scrollWheel(with: event(400, .began, 102))
    #expect(window.firstResponder === sidebar)
    sidebar.scrollWheel(with: event(0, .ended, 103))
    #expect(sidebar.libraryOpen && window.firstResponder === sidebar)
    let search = try #require(descendants(sidebar).compactMap { $0 as? NSSearchField }.first)
    container.finishMotion(scrolling: true)
    #expect(search.currentEditor() == nil)
    sidebar.finishScrollPresentation()
    #expect(search.currentEditor() === window.firstResponder)
    sidebar.setLibraryOpen(false)
    window.makeFirstResponder(sidebar)
    sidebar.scrollWheel(with: event(5, nil, 105))
    #expect(sidebar.libraryOpen && window.firstResponder === sidebar)
    container.finishMotion(scrolling: true)
    #expect(search.currentEditor() == nil)
    sidebar.finishScrollPresentation()
    #expect(search.currentEditor() === window.firstResponder)
}


@Test @MainActor
func restoringIntoFolderRevealsOnlyExpandedRows() throws {
    for collapsed in [false, true] {
        let (window, sidebar, container, _) = fixture()
        defer { window.contentView = nil }
        let rows = (0..<50).map { Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "row-\($0)", title: "Row", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) }
        let folder = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "folder", title: "Folder", url: nil, depth: 0, kind: .folder, unloaded: false, lastSelectedAt: nil)
        let restored = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "restored", title: "Restored", url: nil, depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
        let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "home", title: "Home", icon: nil, look: nil, favorites: [], pinned: [], today: rows + [folder] + (collapsed ? [] : [restored]))
        let scroll = try #require(descendants(sidebar).compactMap { $0 as? SidebarScrollView }.first)
        var now = 0.0
        scroll.clock = { now }
        sidebar.setLibraryOpen(true)
        sidebar.applyRestore(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: "restored", spaces: [space]))
        container.layoutSubtreeIfNeeded()
        now = 1
        scroll.stepReveal()
        if collapsed {
            #expect(scroll.contentView.bounds.minY == 0)
            #expect(!descendants(sidebar).compactMap { $0 as? SidebarRowView }.contains { $0.row.id == "restored" })
        } else {
            let row = try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "restored" })
            #expect(scroll.documentView!.convert(row.bounds, from: row).maxY <= scroll.contentView.bounds.maxY + 0.1)
        }
        #expect(!sidebar.libraryOpen && sidebar.selectedRowID == "restored")
    }
}

@Test @MainActor
func explicitSidebarToggleOverridesTemporaryLibraryReveal() {
    for toggles in [1, 2] {
        let (window, sidebar, container, _) = fixture()
        defer { window.contentView = nil }
        container.toggleSidebar()
        sidebar.toggleLibrary()
        for _ in 0..<toggles { container.toggleSidebar() }
        let chosen = container.sidebarState
        sidebar.cancelOperation(nil)
        #expect(container.sidebarState == chosen)
    }
}

@Test @MainActor
func collapseDragOverridesTemporaryLibraryReveal() {
    let (window, sidebar, container, _) = fixture()
    defer { window.contentView = nil }
    container.toggleSidebar()
    sidebar.toggleLibrary()
    #expect(container.resizeHandle.onDrag?(0) == true)
    #expect(container.sidebarState == "hidden")
    sidebar.cancelOperation(nil)
    #expect(container.sidebarState == "hidden")
}

@Test @MainActor
func floatingLibraryHoldsPointerDismissalButHidesOnDeactivationAndKeyLoss() {
    for losesKey in [false, true] {
        let (window, sidebar, container, _) = fixture()
        defer { window.contentView = nil }
        var now = 0.0
        var active = true
        var key = true
        container.clock = { now }
        container.applicationActive = { active }
        container.windowKey = { key }
        container.pointerLocation = { NSPoint(x: 0, y: 300) }
        container.toggleSidebar()
        now = SidebarMetrics.revealDwell
        container.processPointer()
        #expect(container.sidebarState == "floating")
        sidebar.toggleLibrary()
        container.pointerLocation = { NSPoint(x: 2000, y: 300) }
        container.processPointer()
        #expect(container.sidebarState == "floating")
        if losesKey { key = false } else { active = false }
        NotificationCenter.default.post(name: losesKey ? NSWindow.didResignKeyNotification : NSApplication.didResignActiveNotification,
                                        object: losesKey ? window : NSApp)
        #expect(container.sidebarState == "hidden")
        #expect(sidebar.libraryOpen)
    }
}

@Test @MainActor
func libraryOpeningTakesResponderFromThePageBeforeSearchLands() throws {
    let (window, sidebar, container, page) = fixture()
    defer { window.contentView = nil }
    let field = NSTextField(string: "Page")
    page.addSubview(field)
    window.makeFirstResponder(field)
    sidebar.toggleLibrary()
    let responder = try #require(window.firstResponder as? SidebarView)
    #expect(responder === sidebar)
    let search = try #require(descendants(sidebar).compactMap { $0 as? NSSearchField }.first)
    #expect(search.currentEditor() == nil)
    #expect(NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: responder, from: nil))
    #expect(!sidebar.libraryOpen)
    container.finishMotion()
    #expect(search.currentEditor() == nil)
}

@Test @MainActor
func calendarDayNotificationFromBackgroundRebuildsArchiveOnMainThread() async throws {
    _ = NSApplication.shared
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 417, height: 720), now: {
        #expect(Thread.isMainThread)
        return now
    }, calendar: calendar)
    library.update(archive: [ArchiveEntry(id: "day", title: "Tab", url: "https://example.com",
                                         lifecycleChangedAt: UInt64(now.timeIntervalSince1970 * 1000))])
    let revision = library.listRevision
    now = calendar.date(byAdding: .day, value: 1, to: now)!
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            continuation.resume()
        }
    }
    try await waitUntil { library.listRevision > revision }
    let heading = try #require(library.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    #expect(descendants(heading).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Yesterday" })
}

@Test @MainActor
func plusMenuSuppressesTooltipsAndRestartsIdleOnClose() throws {
    let (window, sidebar, _, _) = fixture()
    defer { window.contentView = nil }
    let plus = try #require(descendants(sidebar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "New Space menu" })
    var now = 0.0
    sidebar.tooltip.clock = { now }
    let point = NSPoint(x: 10, y: 10)
    sidebar.tooltip.update(target: plus, point: point)
    now = 1.6
    sidebar.tooltip.update(target: plus, point: point)
    #expect(sidebar.tooltip.text == "New Space")
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: sidebar.newSpaceMenu)
    #expect(sidebar.tooltip.text == nil)
    now = 10
    sidebar.tooltip.update(target: plus, point: point)
    #expect(sidebar.tooltip.text == nil && sidebar.tooltip.idleTimer == nil)
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: sidebar.newSpaceMenu)
    sidebar.tooltip.update(target: plus, point: point)
    now = 11.5
    sidebar.tooltip.update(target: plus, point: point)
    #expect(sidebar.tooltip.text == nil)
    now = 11.6
    sidebar.tooltip.update(target: plus, point: point)
    #expect(sidebar.tooltip.text == "New Space")
}
