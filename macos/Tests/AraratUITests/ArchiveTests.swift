import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func archiveDescendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + archiveDescendants($0) } }

@MainActor
private func archiveCells(_ library: LibraryView) -> [ArchiveRowView] {
    library.layoutSubtreeIfNeeded()
    library.table.displayIfNeeded()
    let range = library.table.rows(in: library.table.visibleRect)
    if range.location != NSNotFound {
        for row in range.location..<(range.location + range.length) { _ = library.table.view(atColumn: 0, row: row, makeIfNecessary: true) }
    }
    return (0..<library.table.numberOfRows).compactMap { library.table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? ArchiveRowView }
}

@MainActor
private func focusedArchiveRow(_ window: NSWindow) -> ArchiveRowView? {
    var view = window.firstResponder as? NSView
    while let current = view { if let row = current as? ArchiveRowView { return row }; view = current.superview }
    return nil
}

@Test @MainActor
func archiveSearchFieldHasTheMeasuredHeight() throws {
    _ = NSApplication.shared
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 417, height: 720))
    library.update(archive: [])
    library.layoutSubtreeIfNeeded()
    let search = try #require(archiveDescendants(library).compactMap { $0 as? NSSearchField }.first)
    #expect(search.frame.height == 36)
}

private func archiveDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

private func archiveEntry(_ id: String, _ title: String, _ url: String, _ time: String) -> ArchiveEntry {
    ArchiveEntry(id: id, title: title, url: url, lifecycleChangedAt: UInt64(archiveDate(time).timeIntervalSince1970 * 1000))
}

@Test @MainActor
func archiveFiltersTitleAndURLAndGroupsByTheInjectedLocalCalendarAcrossMidnight() throws {
    _ = NSApplication.shared
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    var now = archiveDate("2026-11-02T00:05:00+09:00")
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 417, height: 720), now: { now }, calendar: calendar)
    let items = [
        archiveEntry("c", "Sketch", "https://canvas.example.net/drafts", "2026-10-31T12:00:00+09:00"),
        archiveEntry("b", "Meeting", "https://chat.example.com/REPORTS", "2026-11-01T23:59:00+09:00"),
        archiveEntry("a", "Quarterly Report", "https://docs.example.com/notes", "2026-11-02T00:01:00+09:00"),
        archiveEntry("d", "Budget", "https://finance.example.com/Q4", "2026-11-02T00:02:00+09:00"),
    ]
    library.update(archive: items)
    library.layoutSubtreeIfNeeded()
    let headings = { _ = archiveCells(library); return archiveDescendants(library).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "archive-day-heading" && !$0.isHiddenOrHasHiddenAncestor }.sorted { library.table.row(for: $0) < library.table.row(for: $1) }.map(\.stringValue) }
    #expect(headings() == ["Today", "Yesterday", "Oct 31, 2026"])
    let rows = archiveCells(library)
    #expect(rows.map { $0.entry.id } == ["d", "a", "b", "c"])
    #expect(rows.allSatisfy { $0.frame.height == 56 })
    #expect(abs(library.convert(rows[1].bounds, from: rows[1]).minY - library.convert(rows[0].bounds, from: rows[0]).minY - 56) < 0.1)
    #expect(archiveDescendants(rows[1]).compactMap { $0 as? NSTextField }.map(\.stringValue).contains("docs.example.com/notes"))
    let search = try #require(archiveDescendants(library).compactMap { $0 as? NSSearchField }.first)
    search.stringValue = "rEpOrT"
    library.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(library.filteredEntries.map(\.id) == ["a", "b"])
    library.setSearchQuery("CHAT.EXAMPLE")
    #expect(library.filteredEntries.map(\.id) == ["b"])
    library.setSearchQuery("QUARTERLY")
    #expect(library.filteredEntries.map(\.id) == ["a"])
    library.setSearchQuery("missing")
    #expect(library.filteredEntries.isEmpty)
    library.setSearchQuery("")
    now = archiveDate("2026-11-03T00:05:00+09:00")
    library.update(archive: items)
    #expect(headings() == ["Yesterday", "Nov 1, 2026", "Oct 31, 2026"])
    #expect(library.tableView(library.table, isGroupRow: 0))
    #expect(!library.tableView(library.table, shouldSelectRow: 0))
    now = archiveDate("2026-11-04T00:05:00+09:00")
    NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
    #expect(headings() == ["Nov 2, 2026", "Nov 1, 2026", "Oct 31, 2026"])
}

@Test @MainActor
func archiveRowPointerFocusAndActionButtonsUseTheSameCallbacks() throws {
    _ = NSApplication.shared
    let entry = archiveEntry("a", "Quarterly Report", "https://docs.example.com/notes", "2026-11-02T00:01:00+09:00")
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 417, height: 720))
    library.update(archive: [entry])
    let window = NSWindow(contentRect: library.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = library
    defer { window.contentView = nil }
    library.layoutSubtreeIfNeeded()
    let row = try #require(archiveDescendants(library).compactMap { $0 as? ArchiveRowView }.first)
    let buttons = archiveDescendants(row).compactMap { $0 as? NSButton }
    let delete = try #require(buttons.first { $0.accessibilityLabel()?.hasPrefix("Delete archived tab") == true })
    let restore = try #require(buttons.first { $0.accessibilityLabel()?.hasPrefix("Restore ") == true })
    row.pointerLocation = { nil }
    row.refreshHover()
    #expect(buttons.allSatisfy { $0.alphaValue == 0 && $0.canBecomeKeyView })
    let actionPoint = delete.convert(NSPoint(x: delete.bounds.midX, y: delete.bounds.midY), to: row.superview)
    #expect(row.hitTest(actionPoint) === row)
    let pointer = row.convert(NSPoint(x: 10, y: 10), to: nil)
    row.pointerLocation = { pointer }
    row.refreshHover()
    #expect(row.hovered && buttons.allSatisfy { $0.alphaValue == 1 })
    #expect(row.hitTest(actionPoint) === delete)
    let original = row.frame.origin
    row.setFrameOrigin(NSPoint(x: original.x + 700, y: original.y))
    #expect(!row.hovered && buttons.allSatisfy { $0.alphaValue == 0 })
    row.setFrameOrigin(original)
    row.pointerLocation = { nil }
    row.refreshHover()
    #expect(window.makeFirstResponder(row))
    #expect(buttons.allSatisfy { $0.alphaValue == 1 })
    #expect(row.nextValidKeyView === delete)
    #expect(window.makeFirstResponder(delete))
    #expect(buttons.allSatisfy { $0.alphaValue == 1 })
    #expect(window.makeFirstResponder(restore))
    #expect(buttons.allSatisfy { $0.alphaValue == 1 })
    let search = try #require(archiveDescendants(library).compactMap { $0 as? NSSearchField }.first)
    #expect(window.makeFirstResponder(search))
    #expect(buttons.allSatisfy { $0.alphaValue == 0 })
    var deleted: [String] = [], restored: [String] = []
    library.onDelete = { deleted.append($0) }
    library.onRestore = { restored.append($0) }
    delete.performClick(nil)
    restore.performClick(nil)
    #expect(deleted == ["a"] && restored == ["a"])
    #expect(row.accessibilityPerformPress())
    #expect(restored == ["a", "a"])
    #expect(!window.isVisible)
}

@Test @MainActor
func archiveBackArrowClosesTheLibrary() throws {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    sidebar.frame = NSRect(x: 0, y: 0, width: 417, height: 720)
    sidebar.setLibraryOpen(true)
    sidebar.layoutSubtreeIfNeeded()
    let back = try #require(archiveDescendants(sidebar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Exit Library" })
    #expect(back.toolTip == nil)
    var now = 0.0
    sidebar.tooltip.clock = { now }
    sidebar.tooltip.update(target: back, point: .zero)
    now = 1.6
    sidebar.tooltip.update(target: back, point: .zero)
    #expect(sidebar.tooltip.text == "Exit Library")
    back.performClick(nil)
    #expect(!sidebar.libraryOpen)
}

private func virtualArchiveEntries(_ count: Int) -> [ArchiveEntry] {
    (0..<count).map { ArchiveEntry(id: "archive-\($0)", title: "Entry \($0)", url: "https://example.com/\($0)", lifecycleChangedAt: UInt64(1_790_000_000_000 - ($0 / 40) * 86_400_000)) }
}

@Test @MainActor
func archiveVirtualListBudgetsAndDeferredUpdates() throws {
    _ = NSApplication.shared
    for count in [50, 200, 500, 2000] {
        let ordinary = (0..<17).map { Row(id: "tab-\($0)", title: "Tab \($0)", url: "https://tabs.example/\($0)", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil) }
        let spaces = [SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "work", title: "Work", icon: nil, look: nil, favorites: [], pinned: Array(ordinary.prefix(8)), today: []), SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "home", title: "Home", icon: nil, look: nil, favorites: [], pinned: Array(ordinary.suffix(9)), today: [])]
        var snapshot = WorkspaceSnapshot(archive: virtualArchiveEntries(count), shownSpaceId: "work", selectedId: "tab-0", spaces: spaces)
        let sidebar = SidebarView(snapshot: snapshot)
        sidebar.frame = NSRect(x: 0, y: 0, width: 417, height: 720)
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = sidebar
        defer { window.contentView = nil }
        sidebar.layoutSubtreeIfNeeded()
        func measure(_ action: () -> Void) -> Double {
            let start = Date.timeIntervalSinceReferenceDate
            action(); sidebar.layoutSubtreeIfNeeded(); sidebar.displayIfNeeded()
            if sidebar.libraryOpen, let library = archiveDescendants(sidebar).compactMap({ $0 as? LibraryView }).first { _ = archiveCells(library) }
            return (Date.timeIntervalSinceReferenceDate - start) * 1000
        }
        let open = measure { sidebar.setLibraryOpen(true) }
        let library = try #require(archiveDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
        #expect(archiveCells(library).count < 40 && library.rowCreationCount < 40)
        let close = measure { sidebar.setLibraryOpen(false) }
        let revision = library.listRevision, creations = library.rowCreationCount, headings = library.headingCreationCount
        let click = measure { snapshot.selectedId = "tab-1"; sidebar.applySelection(snapshot: snapshot) }
        #expect(library.listRevision == revision && library.rowCreationCount == creations && library.headingCreationCount == headings)
        snapshot.archive.append(ArchiveEntry(id: "deferred", title: "Deferred", url: "https://deferred.example", lifecycleChangedAt: 1_800_000_000_000))
        sidebar.applySelection(snapshot: snapshot)
        #expect(library.listRevision == revision && library.rowCreationCount == creations && library.headingCreationCount == headings)
        let laterOpen = measure { sidebar.setLibraryOpen(true) }
        #expect(library.filteredEntries.count == count + 1 && library.filteredEntries.first?.id == "deferred")
        let width = measure { sidebar.frame.size.width += 8 }
        var keystrokes: [Double] = []
        var createdPerKey: [Int] = []
        for query in ["E", "En", "Ent", "Entry", "Entry 1", "Entry", "site", "no-match", ""] {
            let before = library.rowCreationCount
            keystrokes.append(measure { _ = sidebar.searchArchive(query) })
            createdPerKey.append(library.rowCreationCount - before)
        }
        let search = keystrokes.max() ?? 0
        #expect(createdPerKey.allSatisfy { $0 <= 2 })
        print("ARCHIVE KEYS count=\(count) ms=\(keystrokes) creations=\(createdPerKey)")
        let scroll = measure {
            library.table.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 560))
            library.table.enclosingScrollView?.reflectScrolledClipView(library.table.enclosingScrollView!.contentView)
        }
        #expect(archiveCells(library).count < 40 && library.rowCreationCount < 150)
        #expect(open < 150 && laterOpen < 150 && close < 100 && width < 50 && search < 150 && click < 30 && scroll < 50)
        print("ARCHIVE TABLE count=\(count) open-ms=\(open) later-open-ms=\(laterOpen) close-ms=\(close) width-ms=\(width) search-ms=\(search) closed-click-ms=\(click) scroll-ms=\(scroll) created=\(library.rowCreationCount)")
    }
}

@Test @MainActor
func archiveArrowsSkipHeadingsAndNavigateActionsAndEscapeClearsBeforeExit() throws {
    _ = NSApplication.shared
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 417, height: 720))
    let items = [
        archiveEntry("a", "Alpha", "https://alpha.example", "2026-11-02T12:00:00Z"),
        archiveEntry("b", "Beta", "https://beta.example", "2026-11-01T12:00:00Z"),
        archiveEntry("c", "Gamma", "https://gamma.example", "2026-10-31T12:00:00Z"),
    ]
    library.isHidden = true
    library.update(archive: items)
    #expect(library.rowCreationCount == 0 && library.headingCreationCount == 0 && library.listRevision == 0)
    library.isHidden = false
    let window = NSWindow(contentRect: library.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = library
    defer { window.contentView = nil }
    library.layoutSubtreeIfNeeded()
    let rows = archiveCells(library)
    let search = try #require(archiveDescendants(library).compactMap { $0 as? NSSearchField }.first)
    func key(_ code: UInt16, _ characters: String = "") throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.firstResponder?.keyDown(with: event)
    }
    #expect(window.makeFirstResponder(rows[0]))
    try key(125)
    #expect(window.firstResponder === rows[1])
    try key(126)
    #expect(window.firstResponder === rows[0])
    try key(126)
    #expect(window.firstResponder === rows[0])
    let buttons = archiveDescendants(rows[0]).compactMap { $0 as? NSButton }
    try key(124)
    #expect(window.firstResponder === buttons[0])
    try key(124)
    #expect(window.firstResponder === buttons[1])
    try key(123)
    #expect(window.firstResponder === buttons[0])
    try key(123)
    #expect(window.firstResponder === rows[0])
    var restored: [String] = [], deleted: [String] = []
    library.onRestore = { restored.append($0) }
    library.onDelete = { deleted.append($0) }
    try key(36, "\r")
    try key(124)
    try key(49, " ")
    try key(124)
    try key(36, "\r")
    #expect(restored == ["a", "a"] && deleted == ["a"])
    try key(125)
    #expect(window.firstResponder === rows[1])
    library.setSearchQuery("Gamma")
    #expect(focusedArchiveRow(window)?.entry.id == "c")
    try key(125)
    #expect(focusedArchiveRow(window)?.entry.id == "c")
    var exits = 0
    library.onExit = { exits += 1 }
    #expect(library.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(search.stringValue.isEmpty && exits == 0 && library.filteredEntries.count == 3)
    #expect(library.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(exits == 1)
    var renamed = items[0]
    renamed.title = "Renamed"
    renamed.url = "https://changed.example/path"
    library.update(archive: [renamed, items[2]])
    let surviving = archiveCells(library)
    #expect(surviving.map { $0.entry.id } == ["a", "c"])
    #expect(surviving[0].entry == renamed)
    #expect(surviving[0].accessibilityLabel() == "Renamed, changed.example/path")
    var moved = items[2]
    moved.lifecycleChangedAt = renamed.lifecycleChangedAt + 1000
    library.update(archive: [renamed, moved])
    #expect(archiveCells(library).map { $0.entry.id } == ["c", "a"])
    #expect(surviving.allSatisfy { $0.subviews.allSatisfy { !$0.translatesAutoresizingMaskIntoConstraints } })
    library.update(archive: [])
    #expect((window.firstResponder as? NSButton)?.accessibilityLabel() == "Exit Library")
    #expect(archiveDescendants(library).compactMap { $0 as? NSTextField }.contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == "No archived tabs" })
    #expect(!window.isVisible)
}

@Test @MainActor
func archiveTwoThousandEntriesKeepOnlyVisibleViews() throws {
    _ = NSApplication.shared
    let items = (0..<2000).map { ArchiveEntry(id: "archive-\($0)", title: "Entry \($0)", url: "https://example.com/\($0)", lifecycleChangedAt: UInt64(1_790_000_000_000 - ($0 / 40) * 86_400_000)) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: items, shownSpaceId: nil, selectedId: nil, spaces: []))
    sidebar.frame = NSRect(x: 0, y: 0, width: 417, height: 720)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    let start = Date.timeIntervalSinceReferenceDate
    sidebar.setLibraryOpen(true)
    sidebar.layoutSubtreeIfNeeded()
    let elapsed = Date.timeIntervalSinceReferenceDate - start
    let library = try #require(archiveDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    let cells = archiveDescendants(library).compactMap { $0 as? ArchiveRowView }
    print("ARCHIVE VIRTUAL open-ms=\(elapsed * 1000) created=\(library.rowCreationCount) attached=\(cells.count)")
    #expect(cells.count < 40)
    #expect(library.rowCreationCount < 40)
    #expect(elapsed < 0.15)
}

@Test @MainActor
func archiveFocusAndKeyboardSurviveOffscreenCellReuseAndCloseClearsSearch() throws {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: virtualArchiveEntries(2000), shownSpaceId: nil, selectedId: nil, spaces: []))
    sidebar.frame = NSRect(x: 0, y: 0, width: 417, height: 720)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.setLibraryOpen(true)
    sidebar.layoutSubtreeIfNeeded()
    let library = try #require(archiveDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    let first = try #require(archiveCells(library).first)
    let originalID = first.entry.id
    #expect(window.makeFirstResponder(first.focusTarget(1)))
    let initial = Set(archiveCells(library).map(ObjectIdentifier.init))
    let clip = try #require(library.table.enclosingScrollView?.contentView)
    for y: CGFloat in [20000, 40000, 60000, 80000] {
        clip.scroll(to: NSPoint(x: 0, y: y))
        library.table.enclosingScrollView?.reflectScrolledClipView(clip)
        library.table.layoutSubtreeIfNeeded()
        _ = archiveCells(library)
    }
    #expect(window.firstResponder === library.table || focusedArchiveRow(window)?.entry.id == originalID)
    #expect(library.rowCreationCount < 45)
    #expect(archiveCells(library).count < 25)
    let later = Set(archiveCells(library).map(ObjectIdentifier.init))
    #expect(!later.isDisjoint(with: initial))
    clip.scroll(to: .zero)
    library.table.enclosingScrollView?.reflectScrolledClipView(clip)
    library.table.layoutSubtreeIfNeeded()
    _ = archiveCells(library)
    #expect(focusedArchiveRow(window)?.entry.id == originalID)
    #expect(window.firstResponder === focusedArchiveRow(window)?.focusTarget(1))
    func key(_ code: UInt16, _ text: String = "", shift: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        window.firstResponder?.keyDown(with: event)
    }
    var deleted: [String] = [], restored: [String] = []
    library.onDelete = { deleted.append($0) }; library.onRestore = { restored.append($0) }
    try key(49, " ")
    #expect(deleted == [originalID])
    try key(125)
    #expect(focusedArchiveRow(window)?.entry.id == "archive-1")
    try key(48, "\t")
    #expect(window.firstResponder === focusedArchiveRow(window)?.focusTarget(1))
    try key(48, "\t")
    try key(48, "\t")
    #expect(focusedArchiveRow(window)?.entry.id == library.filteredEntries[2].id)
    try key(48, "\t", shift: true)
    #expect(focusedArchiveRow(window)?.entry.id == "archive-1")
    #expect(window.firstResponder === focusedArchiveRow(window)?.focusTarget(2))
    try key(36, "\r")
    #expect(restored == ["archive-1"])
    if let row = focusedArchiveRow(window) {
        let next = row.focusTarget(2).nextValidKeyView
        #expect((next as? ArchiveRowView)?.entry.id == library.filteredEntries[2].id)
        window.selectNextKeyView(row.focusTarget(2))
        #expect(focusedArchiveRow(window)?.entry.id == library.filteredEntries[2].id)
        window.selectPreviousKeyView(window.firstResponder as? NSView)
        #expect(focusedArchiveRow(window)?.entry.id == "archive-1")
        #expect(window.firstResponder === focusedArchiveRow(window)?.focusTarget(2))
    }
    _ = sidebar.searchArchive("Entry 123")
    #expect(library.filteredEntries.count < 20)
    sidebar.setLibraryOpen(false)
    sidebar.setLibraryOpen(true)
    sidebar.layoutSubtreeIfNeeded()
    let search = try #require(archiveDescendants(library).compactMap { $0 as? NSSearchField }.first)
    #expect(search.stringValue.isEmpty && library.filteredEntries.count == 2000)
    #expect(!window.isVisible)
}

@Test @MainActor
func archiveKeyViewQueriesDoNotScrollButFocusDoes() throws {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: virtualArchiveEntries(200), shownSpaceId: nil, selectedId: nil, spaces: []))
    sidebar.frame = NSRect(x: 0, y: 0, width: 417, height: 720)
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.setLibraryOpen(true)
    sidebar.layoutSubtreeIfNeeded()
    let library = try #require(archiveDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    let search = try #require(archiveDescendants(library).compactMap { $0 as? NSSearchField }.first)
    let back = try #require(archiveDescendants(library).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Exit Library" })
    let clip = try #require(library.table.enclosingScrollView?.contentView)
    clip.scroll(to: NSPoint(x: 0, y: 5000))
    library.table.enclosingScrollView?.reflectScrolledClipView(clip)
    _ = archiveCells(library)
    let position = clip.bounds.origin
    let responder = window.firstResponder
    let first = search.nextValidKeyView
    #expect(clip.bounds.origin == position && window.firstResponder === responder)
    let last = back.previousValidKeyView
    #expect(clip.bounds.origin == position && window.firstResponder === responder)
    #expect((first as? ArchiveRowView)?.entry.id == library.filteredEntries.first?.id)
    #expect(last?.accessibilityLabel() == "Restore \(library.filteredEntries.last!.title)")
    #expect(library.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(focusedArchiveRow(window)?.entry.id == library.filteredEntries.first?.id)
    #expect(clip.bounds.minY < position.y)
    let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    back.keyDown(with: tab)
    #expect(focusedArchiveRow(window)?.entry.id == library.filteredEntries.last?.id)
    #expect(clip.bounds.minY > position.y)
    #expect(window.firstResponder === focusedArchiveRow(window)?.focusTarget(2))
    #expect(!window.isVisible)
}
