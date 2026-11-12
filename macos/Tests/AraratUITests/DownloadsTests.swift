import AppKit
import Testing
import AraratKit
@testable import AraratUI

private func download(_ id: String, start: Double = 0, running: Bool = false, received: Int64 = 0, total: Int64 = 0, actions: [String] = [], restored: Bool = false, state: Int? = nil, profile: String = "Default") -> [String: Any] {
    ["id": id, "profile": profile, "name": id, "state": state ?? (running ? 0 : 1), "running": running, "restored": restored,
     "start": start, "received": received, "total": total, "status": "", "actions": actions]
}

@Test @MainActor func restoredHistoryOnlyActivatesTheListWhenResumable() {
    let model = DownloadsModel()
    model.update([download("history", restored: true)])
    #expect(!model.hasSessionDownloads)
    model.update([download("interrupted", actions: ["resume"], restored: true, state: 3)])
    #expect(model.hasSessionDownloads)
}

@Test @MainActor func downloadsSortAndWeightOnlyRunningItems() {
    let model = DownloadsModel()
    #expect(model.progress == .none)
    model.update([download("old", start: 1, running: true, received: 20, total: 100),
                  download("new", start: 2, running: true, received: 150, total: 300),
                  download("done", start: 3, received: 1000, total: 1000)])
    #expect(model.items.map(\.id) == ["done", "new", "old"])
    #expect(model.progress == .fraction(0.425))
    model.update([download("unknown", running: true, total: 0)])
    #expect(model.progress == .indeterminate)
    model.update([download("done")])
    #expect(model.progress == .none)
}

@Test @MainActor func downloadActionsRequireAnAvailableCurrentItem() {
    let model = DownloadsModel()
    var received: [String] = []
    model.onAction = { action, id in received.append("\(id):\(action)"); return true }
    model.update([download("one", actions: ["show", "cancel"])])
    #expect(model.perform("cancel", id: "one"))
    #expect(!model.perform("keep", id: "one"))
    model.update([])
    #expect(!model.perform("show", id: "one"))
    #expect(received == ["one:cancel"])
}

@Test @MainActor func downloadRowButtonsSendTheirActionAndIdentifier() throws {
    let model = DownloadsModel()
    var received: [String] = []
    model.onAction = { action, id in received.append("\(id):\(action)"); return true }
    model.update([download("one", actions: ["show", "cancel"])])
    let popover = DownloadsPopover(model: model, anchor: NSView())
    let row = popover.row(try #require(model.items.first))
    func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    let cancel = try #require(buttons(row).first { $0.title == "Cancel" })
    cancel.performClick(nil)
    #expect(received == ["one:cancel"])
}

@Test @MainActor func libraryButtonOpensLibraryOnlyWhenTheListIsEmpty() {
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let model = DownloadsModel()
    sidebar.setDownloadsModel(model)
    model.update([download("item", running: true, received: 1, total: 2)])
    #expect(sidebar.libraryButton.progress == .fraction(0.5))
    sidebar.libraryButton.performClick(nil)
    #expect(!sidebar.libraryOpen)
    model.update([])
    #expect(sidebar.libraryButton.progress == .none)
    sidebar.libraryButton.performClick(nil)
    #expect(sidebar.libraryOpen)
}

@Test @MainActor func downloadHoverWaitsAndExitCancels() {
    let button = DownloadsButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    var tasks: [DispatchWorkItem] = []
    var opened = 0
    button.scheduleHover = { tasks.append($0) }
    button.onHover = { opened += 1 }
    let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    button.mouseEntered(with: event)
    #expect(opened == 0)
    button.mouseExited(with: event)
    tasks[0].perform()
    #expect(opened == 0)
    button.mouseEntered(with: event)
    tasks[1].perform()
    #expect(opened == 1)
    var fired = false
    button.checkHover { fired = true }
    #expect(!fired)
    tasks[2].perform()
    #expect(fired && opened == 2)
}

@Test @MainActor func popoverKeepsRowsAndActionsDuringProgressUpdates() throws {
    let model = DownloadsModel()
    model.update([download("a", running: true, received: 1, total: 100, actions: ["cancel"])])
    let popover = DownloadsPopover(model: model, anchor: NSView())
    popover.refresh(limit: 10)
    let row = try #require(popover.rows["a"])
    let button = try #require(row.actionButtons.first)
    model.update([download("a", running: true, received: 2, total: 100, actions: ["cancel"])])
    popover.refresh(limit: 10)
    #expect(popover.rows["a"] === row)
    #expect(row.actionButtons.first === button)
    model.update([download("b", start: 2), download("a", running: true, received: 3, total: 100, actions: ["cancel"])])
    popover.refresh(limit: 10)
    #expect(popover.rows["a"] === row)
}

@Test @MainActor func indeterminateRingKeepsItsAnimationAcrossUpdatesAndLayout() throws {
    let button = DownloadsButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    button.reduceMotion = { false }
    button.progress = .indeterminate
    let initial = try #require(button.ring.animation(forKey: "spin")).beginTime
    button.progress = .indeterminate
    button.layout()
    #expect(button.ring.animation(forKey: "spin")?.beginTime == initial)
    #expect(button.accessibilityValue() as? String == "Downloading")
    button.progress = .fraction(0.42)
    #expect(button.ring.animation(forKey: "spin") == nil)
    #expect(button.accessibilityValue() as? String == "Downloading, 42 %")
}

@Test @MainActor func runningRingHasVisibleGeometryEvenAtLowProgress() {
    let button = DownloadsButton(frame: .zero)
    button.progress = .fraction(0.004)
    button.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
    button.layout()
    #expect(!button.ring.isHidden && button.ring.opacity > 0)
    #expect(button.ring.bounds.width > 0 && button.ring.bounds.height > 0)
    #expect(button.ring.strokeEnd >= 0.12 && button.ring.path != nil)
    #expect(button.accessibilityValue() as? String == "Downloading, 0 %")
}

@Test @MainActor func downloadsPopoverUsesThePhysicalUpperEdgeAndFitsThreeRows() throws {
    _ = NSApplication.shared
    #expect(DownloadsPopover.edge(flipped: true) == .minY)
    #expect(DownloadsPopover.edge(flipped: false) == .maxY)
    let screen = try #require(NSScreen.main)
    let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let anchor = DownloadsButton(frame: NSRect(x: 9, y: 9, width: 32, height: 32))
    window.contentView?.addSubview(anchor)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let model = DownloadsModel()
    model.update([download("a"), download("b"), download("c")])
    let popover = DownloadsPopover(model: model, anchor: anchor)
    popover.show()
    defer { popover.close() }
    let panel = try #require(popover.checkWindow)
    let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    #expect(window.frame.insetBy(dx: -1, dy: -1).contains(panel.frame))
    #expect(panel.frame.minY >= button.maxY - 1)
    #expect(panel.frame.width >= SidebarMetrics.defaultWidth)
    #expect(panel.frame.height >= DownloadsPopover.headerHeight + 3 * DownloadsPopover.rowHeight)
    #expect(popover.rows.count == 3)
    let metrics = popover.checkMetrics
    #expect(metrics["content_width"] as? CGFloat == 240)
    #expect(metrics["title_font"] as? CGFloat == 13)
    #expect((metrics["title_height"] as? CGFloat ?? 0) >= 13)
    #expect(metrics["rows_leading_and_status_fit"] as? Bool == true)
    #expect(metrics["library_fills"] as? Bool == true)
    #expect(popover.library.alignment == .left)
}

@Test @MainActor func downloadsPageUsesAvailableWidthForStatus() throws {
    _ = NSApplication.shared
    let model = DownloadsModel()
    var item = download("a", actions: ["show", "cancel"])
    item["status"] = "4.0/1,024 KB, 9 minutes left"
    model.update([item])
    let page = DownloadsPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let window = NSWindow(contentRect: page.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = page
    defer { window.contentView = nil }
    page.setModel(model)
    page.layoutSubtreeIfNeeded()
    page.table.layoutSubtreeIfNeeded()
    let row = try #require(page.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? DownloadRowView)
    row.layoutSubtreeIfNeeded()
    func labels(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels) }
    let status = try #require(labels(row).first { $0.stringValue == "4.0/1,024 KB, 9 minutes left" })
    #expect(row.bounds.width > 300)
    #expect(status.bounds.width > 250)
    #expect(page.actionButtonsFit)
    #expect(row.actionButtons.allSatisfy { $0.image != nil && $0.accessibilityLabel()?.contains("a") == true })
    let clip = try #require(page.table.enclosingScrollView?.contentView)
    for width: CGFloat in [198, 164, 400] {
        window.setContentSize(NSSize(width: width, height: 400))
        page.layoutSubtreeIfNeeded()
        page.table.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        let visible = clip.bounds
        let rowFrame = clip.convert(row.bounds, from: row)
        let statusFrame = row.statusFrame(in: clip)
        #expect(abs((page.table.tableColumns.first?.width ?? 0) - visible.width) <= 1)
        #expect(rowFrame.maxX <= visible.maxX + 1)
        #expect(statusFrame.maxX <= visible.maxX + 1)
        #expect(page.actionButtonsFit)
        #expect(page.rowsLeadingAndStatusFit)
        #expect(row.statusTruncates)
    }
}

@Test @MainActor func libraryDownloadsIncludesRestoredAndFollowsProfileUpdates() throws {
    let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
    let model = DownloadsModel()
    library.setDownloadsModel(model)
    #expect(library.page == .archive)
    library.showDownloads()
    #expect(library.downloadsPage.emptyVisible)
    model.update([download("old", start: 1, restored: true), download("new", start: 2, actions: ["show"])])
    library.refreshDownloads()
    #expect(library.downloadsPage.entries.map(\.id) == ["new", "old"])
    #expect(!library.downloadsPage.emptyVisible)
    model.update([download("other-profile", start: 3, profile: "Profile 1")])
    library.refreshDownloads()
    #expect(library.downloadsPage.entries.map(\.id) == ["other-profile"])
    #expect(library.downloadsPage.entries.first?.profile == "Profile 1")
    model.update([])
    library.refreshDownloads()
    #expect(library.downloadsPage.entries.isEmpty && library.downloadsPage.emptyVisible)
}

@Test @MainActor func libraryAndPopoverUseTheSameRowActions() throws {
    let model = DownloadsModel()
    var called: [String] = []
    model.onAction = { action, id in called.append("\(id):\(action)"); return true }
    model.update([download("one", actions: ["show", "cancel"])])
    let page = DownloadsPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    page.setModel(model)
    page.layoutSubtreeIfNeeded()
    let row = try #require(page.tableView(page.table, viewFor: page.table.tableColumns.first, row: 0) as? DownloadRowView)
    try #require(row.actionButtons.first { $0.downloadAction == "cancel" }).performClick(nil)
    #expect(called == ["one:cancel"])
}

@Test @MainActor func downloadsPageArrowAndTabNavigateRows() throws {
    _ = NSApplication.shared
    let model = DownloadsModel()
    model.update([download("first", start: 2, actions: ["show", "cancel"]), download("second", start: 1, actions: ["open"])])
    let page = DownloadsPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let window = NSWindow(contentRect: page.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = page
    defer { window.contentView = nil }
    page.setModel(model)
    page.layoutSubtreeIfNeeded()
    page.focusFirst()
    func key(_ code: UInt16, _ text: String = "") throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        window.firstResponder?.keyDown(with: event)
    }
    #expect((window.firstResponder as? DownloadActionButton)?.downloadAction == "show")
    try key(48, "\t")
    #expect((window.firstResponder as? DownloadActionButton)?.downloadAction == "cancel")
    try key(125)
    #expect((window.firstResponder as? DownloadActionButton)?.downloadID == "second")
    try key(126)
    #expect((window.firstResponder as? DownloadActionButton)?.downloadID == "first")
}

@Test @MainActor func downloadsPageKeepsLongHistoryInAVirtualTable() {
    _ = NSApplication.shared
    let model = DownloadsModel()
    model.update((0..<2000).map { download("item-\($0)", start: Double($0), restored: true) })
    let page = DownloadsPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let window = NSWindow(contentRect: page.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = page
    defer { window.contentView = nil }
    page.setModel(model)
    page.layoutSubtreeIfNeeded()
    page.table.layoutSubtreeIfNeeded()
    var visible = 0
    page.table.enumerateAvailableRowViews { _, _ in visible += 1 }
    #expect(page.table.numberOfRows == 2000)
    #expect(visible < 30)
}

@Test @MainActor func libraryEntryPointsSelectTheRequestedPage() throws {
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let model = DownloadsModel()
    sidebar.setDownloadsModel(model)
    sidebar.setLibraryOpen(true)
    #expect(sidebar.libraryPage == "Archive")
    try #require(sidebar.downloadsPopover).library.performClick(nil)
    #expect(sidebar.libraryPage == "Downloads")
    sidebar.setLibraryOpen(false)
    sidebar.libraryButton.performClick(nil)
    #expect(sidebar.libraryOpen && sidebar.libraryPage == "Archive")
    try #require(sidebar.downloadsPopover).library.performClick(nil)
    sidebar.setLibraryOpen(false)
    sidebar.setLibraryOpen(true)
    #expect(sidebar.libraryPage == "Archive")
}

@Test @MainActor func removingFocusedDownloadKeepsTheNearestRow() throws {
    _ = NSApplication.shared
    let model = DownloadsModel()
    model.update([download("first", start: 3, actions: ["remove"]), download("middle", start: 2, actions: ["remove"]), download("last", start: 1, actions: ["remove"])])
    let page = DownloadsPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    let window = NSWindow(contentRect: page.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = page
    defer { window.contentView = nil }
    page.setModel(model)
    page.layoutSubtreeIfNeeded()
    page.focusFirst()
    let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
    window.firstResponder?.keyDown(with: down)
    #expect((window.firstResponder as? DownloadActionButton)?.downloadID == "middle")
    model.update([download("first", start: 3, actions: ["remove"]), download("last", start: 1, actions: ["remove"])])
    page.refresh()
    #expect((window.firstResponder as? DownloadActionButton)?.downloadID == "last")
    model.update([download("first", start: 3, actions: ["remove"])])
    page.refresh()
    #expect((window.firstResponder as? DownloadActionButton)?.downloadID == "first")
    model.update([])
    page.refresh()
    #expect((window.firstResponder as? NSView)?.accessibilityLabel() == "Exit Library")
}
