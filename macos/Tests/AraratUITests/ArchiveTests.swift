import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func archiveDescendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + archiveDescendants($0) } }

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
    let headings = { archiveDescendants(library).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "archive-day-heading" && !$0.isHidden }.map(\.stringValue) }
    #expect(headings() == ["Today", "Yesterday", "Oct 31, 2026"])
    let rows = archiveDescendants(library).compactMap { $0 as? ArchiveRowView }
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
    #expect(back.toolTip == "Exit Library")
    back.performClick(nil)
    #expect(!sidebar.libraryOpen)
}

@Test @MainActor
func archiveLargeListsKeepViewsAndBoundSelectionOpenAndSearch() throws {
    _ = NSApplication.shared
    for count in [50, 200, 500] {
        let items = (0..<count).map { ArchiveEntry(id: "archive-\($0)", title: "Entry \($0)", url: "https://example.com/\($0)", lifecycleChangedAt: UInt64(1_790_000_000_000 + $0)) }
        var snapshot = WorkspaceSnapshot(archive: items, shownSpaceId: nil, selectedId: nil, spaces: [])
        let sidebar = SidebarView(snapshot: snapshot)
        sidebar.frame = NSRect(x: 0, y: 0, width: 417, height: 720)
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.layoutSubtreeIfNeeded()
        let startClick = Date.timeIntervalSinceReferenceDate
        snapshot.selectedId = "tab-click"
        sidebar.applySelection(snapshot: snapshot)
        let click = Date.timeIntervalSinceReferenceDate - startClick
        let startOpen = Date.timeIntervalSinceReferenceDate
        sidebar.setLibraryOpen(true)
        sidebar.layoutSubtreeIfNeeded()
        let open = Date.timeIntervalSinceReferenceDate - startOpen
        let library = try #require(archiveDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
        let rows = archiveDescendants(library).compactMap { $0 as? ArchiveRowView }
        let identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.entry.id, ObjectIdentifier($0)) })
        #expect(library.rowCreationCount == count)
        let headingCount = library.headingCreationCount
        sidebar.setLibraryOpen(false)
        let revision = library.listRevision
        let startClosedClick = Date.timeIntervalSinceReferenceDate
        snapshot.selectedId = "another-tab"
        snapshot.archive.append(ArchiveEntry(id: "deferred", title: "Deferred", url: "https://deferred.example", lifecycleChangedAt: 1))
        sidebar.applySelection(snapshot: snapshot)
        #expect(Date.timeIntervalSinceReferenceDate - startClosedClick < 0.25)
        #expect(library.listRevision == revision)
        #expect(library.rowCreationCount == count)
        #expect(library.headingCreationCount == headingCount)
        #expect(archiveDescendants(library).compactMap { $0 as? ArchiveRowView }.allSatisfy { identities[$0.entry.id] == ObjectIdentifier($0) })
        sidebar.setLibraryOpen(true)
        sidebar.layoutSubtreeIfNeeded()
        #expect(library.rowCreationCount == count + 1)
        let creations = library.rowCreationCount
        let headings = library.headingCreationCount
        let startSearch = Date.timeIntervalSinceReferenceDate
        _ = sidebar.searchArchive("1")
        sidebar.layoutSubtreeIfNeeded()
        let search = Date.timeIntervalSinceReferenceDate - startSearch
        print("ARCHIVE BENCH count=\(count) closed-click-ms=\(click * 1000) open-ms=\(open * 1000) search-ms=\(search * 1000)")
        #expect(click < 0.25)
        #expect(open < 3)
        #expect(search < 0.25)
        let after = archiveDescendants(library).compactMap { $0 as? ArchiveRowView }
        #expect(after.allSatisfy { $0.entry.id == "deferred" || identities[$0.entry.id] == ObjectIdentifier($0) })
        _ = sidebar.searchArchive("")
        #expect(library.rowCreationCount == creations)
        #expect(library.headingCreationCount == headings)
        window.contentView = nil
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
    let rows = archiveDescendants(library).compactMap { $0 as? ArchiveRowView }
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
    #expect(window.firstResponder === rows[2])
    try key(125)
    #expect(window.firstResponder === rows[2])
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
    let surviving = archiveDescendants(library).compactMap { $0 as? ArchiveRowView }
    #expect(surviving.count == 2 && surviving[0] === rows[0] && surviving[1] === rows[2])
    #expect(rows[0].entry == renamed)
    #expect(rows[0].accessibilityLabel() == "Renamed, changed.example/path")
    #expect(surviving.allSatisfy { $0.constraints.isEmpty && $0.subviews.allSatisfy { !$0.translatesAutoresizingMaskIntoConstraints } })
    #expect(!window.isVisible)
}
