import AppKit
import AraratKit
import Testing
@testable import AraratUI
@testable import AraratHarness

// The command bar panel, field, keyboard and commits. Views are built
// unordered and events are fed directly; nothing is posted, no ordered windows, no menus.
@MainActor
private func barKeyEvent(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                  characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
}

/// A modifier-prefixed keycap (⌥W and kin): the characters differ from the unmodified key.
@MainActor
private func barKeycapEvent(_ characters: String, ignoring: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                  characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode))
}

@MainActor
private func barRow(_ title: String, target: SuggestionTarget, url: String? = nil, score: Double = 80) -> Suggestion {
    Suggestion(title: title, subtitle: "", url: url, key: nil, target: target, score: score)
}

@MainActor
private final class FakeCommandBarStore: CommandBarStore {
    var results: [String: CommandBarResult] = [:]
    var queries: [String] = []

    func query(_ text: String, history: [HistoryEntry]) -> CommandBarResult {
        queries.append(text)
        return results[text] ?? CommandBarResult(rows: [], privateWindow: false)
    }
    func searchURL(_ text: String) -> String { "search:" + text }
}

/// A bar in an unordered window; the field editor is made first responder so keys can be fed
/// straight into it. The store may be nil while the session is pending (the panel keys at once).
@MainActor
private func mountedBar(_ store: FakeCommandBarStore?, mode: CommandBarMode = .newTab, prefill: String? = nil, now: (() -> Date)? = nil) throws -> (CommandBarController, CommandBarView, NSWindow) {
    let controller = CommandBarController()
    if let now { controller.now = now }
    let view = CommandBarView(controller: controller)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = view
    // The field takes focus first, like the panel keying on open, so the prefill selection
    // applies synchronously and no queued block lands under the test's feet.
    window.makeFirstResponder(view.field)
    controller.open(mode: mode, prefill: prefill, store: store)
    return (controller, view, window)
}

@Test @MainActor
func commandBarFocusIsSynchronous() throws {
    let controller = CommandBarController()
    let view = CommandBarView(controller: controller)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    controller.open(mode: .editURL, prefill: "https://example.com", store: nil)
    view.focusField()
    let editor = try #require(view.field.currentEditor())
    #expect(window.firstResponder === editor)
    #expect(view.field.stringValue == "https://example.com")
    #expect(editor.selectedRange == NSRange(location: 0, length: 19))
}

@Test @MainActor
func searchModeCommitsLiteralQueryAfterSessionArrives() {
    let controller = CommandBarController()
    let store = FakeCommandBarStore()
    controller.open(mode: .search, prefill: nil, store: nil)
    controller.update(query: "example.com & 日本")
    var target: SuggestionTarget?
    controller.onCommit = { row, _, _ in target = row?.target }
    controller.commit(forceNewTab: false)
    #expect(controller.isOpen)
    controller.applyStore(store)
    #expect(target == .search(url: "search:example.com & 日本"))
    #expect(store.queries.isEmpty)
}

@Test @MainActor
func hiddenCommandBarNeverOrdersItsWindows() {
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let presenter = CommandBarPresenter(parent: parent, visible: false, bindings: [], highlight: .clear)
    presenter.open(mode: .newTab, prefill: nil)
    presenter.applyStore(FakeCommandBarStore())
    #expect(!parent.isVisible && !presenter.panel.isVisible && presenter.panel.parent == nil)
    presenter.close()
    #expect(!parent.isVisible && !presenter.panel.isVisible)
}

@MainActor
private final class FocusCountingWindow: NSWindow {
    var frontCount = 0
    override func makeKeyAndOrderFront(_ sender: Any?) { frontCount += 1 }
}

@Test @MainActor
func clickingAwayDoesNotFrontThePreviousHost() {
    let first = FocusCountingWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let second = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let presenter = CommandBarPresenter(parent: first, visible: true, bindings: [], highlight: .clear)
    var time = Date(timeIntervalSince1970: 100)
    presenter.controller.now = { time }
    presenter.controller.open(mode: .newTab, prefill: nil, store: nil)
    time.addTimeInterval(1)
    presenter.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: second))
    #expect(!presenter.controller.isOpen)
    #expect(first.frontCount == 0)
}

@Test @MainActor
func commandBarCommitSurvivesPresenterReleaseOnClose() {
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    var presenter: CommandBarPresenter? = CommandBarPresenter(parent: parent, visible: false, bindings: [], highlight: .clear)
    var committed = false
    presenter?.onClose = { presenter = nil }
    presenter?.onCommit = { _, _, _ in committed = true }
    presenter?.open(mode: .search, prefill: nil)
    let controller = presenter!.controller
    controller.update(query: "example.com")
    presenter?.applyStore(FakeCommandBarStore())
    controller.commit(forceNewTab: false)
    #expect(presenter == nil && committed)
}

@MainActor
private func commitValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private func commitHarness(_ directory: URL) async throws -> (HarnessDelegate, WorkspaceAdapter) {
    _ = NSApplication.shared
    let adapter = WorkspaceAdapter(windowID: "commandbar")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let snapshot = try await commitValue {
        adapter.open(path: directory.appendingPathComponent("command-bar.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let harness = HarnessDelegate(adapter: adapter)
    harness.snapshot = snapshot
    try await commitValue { harness.keyBindings.load(completion: $0) }
    harness.sidebar = SidebarView(snapshot: snapshot)
    harness.connectSidebar()
    return (harness, adapter)
}

@Test @MainActor
func switchingSpacesSelectsAnOpenRowInTheDestination() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, adapter) = try await commitHarness(directory)
    try await commitValue { adapter.showSpace(id: "space-home", completion: $0) }
    let initialHome = try await commitValue { adapter.createTab(url: "https://home.example", completion: $0) }
    let expectedHomeID = try #require(initialHome.selectedId)
    let first = try await commitValue { adapter.showSpaceSelecting(id: "space-work", completion: $0) }
    let work = try #require(first.spaces.first { $0.id == "space-work" })
    let workID = try #require(first.selectedId)
    #expect((work.today + work.pinned + work.favorites).contains { $0.id == workID && !$0.unloaded })
    let home = try await commitValue { adapter.showSpaceSelecting(id: "space-home", completion: $0) }
    let destination = try #require(home.spaces.first { $0.id == "space-home" })
    let homeID = try #require(home.selectedId)
    #expect(homeID == expectedHomeID)
    #expect((destination.today + destination.pinned + destination.favorites).contains { $0.id == homeID && !$0.unloaded })
    let back = try await commitValue { adapter.showSpaceSelecting(id: "space-work", completion: $0) }
    #expect(back.selectedId == workID)
}

@Test @MainActor
func staleLiveMoveDoesNotChangeWorkspace() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, adapter) = try await commitHarness(directory)
    let before = try await commitValue { adapter.snapshot(completion: $0) }
    let space = try #require(before.spaces.first { $0.id == "space-work" })
    let row = try #require(space.pinned.first { $0.url != nil })
    let result = try await commitValue { adapter.moveIfLive(id: row.id, container: space.todayId, index: 0,
        openFolder: false, expectedLive: "stale-live", completion: $0) }
    #expect(result == nil)
    let after = try await commitValue { adapter.snapshot(completion: $0) }
    #expect(after.spaces.first { $0.id == space.id }?.pinned.contains { $0.id == row.id } == true)
}

@Test @MainActor
func splitSwitchSelectsTheFocusedMember() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, adapter) = try await commitHarness(directory)
    try await commitValue { adapter.showSpace(id: "space-work", completion: $0) }
    _ = try await commitValue { adapter.select(id: "split-1", completion: $0) }
    let before = try await commitValue { adapter.showSpaceSelecting(id: "space-home", completion: $0) }
    let sidebar = SidebarView(snapshot: before)
    let targetIndex = try #require(before.spaces.firstIndex { $0.id == "space-work" })
    var calls = 0
    sidebar.onShowSpace = { _ in calls += 1 }
    sidebar.showSpace(at: targetIndex)
    #expect(sidebar.spaceShown == targetIndex && calls == 1)
    let after = try await commitValue { adapter.showSpaceSelecting(id: "space-work", completion: $0) }
    #expect(after.shownSpaceId == "space-work" && after.selectedId == "tab-a")
    #expect(sidebar.spaceShown == targetIndex && calls == 1)
}

@Test @MainActor
func commandBarGeometryFollowsTheDesignFormula() throws {
    // height = 60 + n·50 + (n−1)·2 + 20, 60 with no rows [Cra, CommandBarView.swift:10-12].
    #expect(CommandBarMetrics.height(forRows: 0) == 60)
    #expect(CommandBarMetrics.height(forRows: 1) == 130)
    #expect(CommandBarMetrics.height(forRows: 2) == 182)
    #expect(CommandBarMetrics.height(forRows: 5) == 338)
    // At most five rows.
    #expect(CommandBarMetrics.maxRows == 5)
    // Width 766 [Arc], capped at window width − 80 [Cra, Theme.swift:490].
    #expect(CommandBarMetrics.width == 766)
    #expect(CommandBarMetrics.cappedWidth(windowWidth: 2000) == 766)
    #expect(CommandBarMetrics.cappedWidth(windowWidth: 800) == 720)
    // Centred, and the field stays put while shorter lists hang down: the top edge is fixed
    // at the window's midY + full height / 2 + 40 [Cra, MainWindowController.swift:1835-1843].
    let windowFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
    let full = CommandBarMetrics.panelFrame(windowFrame: windowFrame, width: 766, rows: 5)
    let empty = CommandBarMetrics.panelFrame(windowFrame: windowFrame, width: 766, rows: 0)
    #expect(full.maxY == windowFrame.midY + 338 / 2 + 40)
    #expect(empty.maxY == full.maxY)
    #expect(full.height == 338 && empty.height == 60)
    #expect(abs(full.midX - windowFrame.midX) < 0.001 && abs(empty.midX - windowFrame.midX) < 0.001)

    // The laid-out view: field row 60 tall, then rows 50 tall, 2 apart, inset 10.
    let store = FakeCommandBarStore()
    store.results[""] = CommandBarResult(rows: [barRow("Alpha", target: .tab(id: "a", spaceId: nil), url: "https://a.test/"),
                                                barRow("Beta", target: .tab(id: "b", spaceId: nil), url: "https://b.test/")], privateWindow: false)
    let (_, view, layoutWindow) = try mountedBar(store)
    defer { _ = layoutWindow }
    view.layoutSubtreeIfNeeded()
    let rows = view.subviews.filter { $0 is CommandBarRowView && !$0.isHidden }
    #expect(rows.count == 2)
    let frames = rows.map { $0.frame }.sorted { $0.minY < $1.minY }
    // Indexed with #require, so a regression that drops a row fails instead of trapping.
    try #require(frames.count == 2)
    #expect(frames[0] == NSRect(x: 10, y: 70, width: 980, height: 50))
    #expect(frames[1] == NSRect(x: 10, y: 122, width: 980, height: 50))
    #expect(abs(view.field.frame.height - 30) < 0.001)
}

@Test @MainActor
func commandTOpensANewTabAndCommandLEditsTheCurrentURL() async throws {
    // ⌘L prefills the current tab's URL all selected; with no tab it falls back to a new tab
    // [Cra, MainWindowController.swift:1799-1801].
    #expect(CommandBarController.openSpec(mode: .editURL, selectedTabURL: "https://example.test/page") == (.editURL, "https://example.test/page"))
    #expect(CommandBarController.openSpec(mode: .editURL, selectedTabURL: nil) == (.newTab, nil))
    #expect(CommandBarController.openSpec(mode: .newTab, selectedTabURL: "https://example.test/") == (.newTab, nil))

    // Both entry points sit in the key-binding table with these defaults, so they show in
    // Settings › Shortcuts and the command source.
    let defaults = defaultKeyBindings()
    let newTab = try #require(defaults.first { $0.command == "new_tab" })
    #expect(newTab.key == KeyCombination(key: "t", command: true, control: false, option: false, shift: false))
    let editURL = try #require(defaults.first { $0.command == "edit_url" })
    #expect(editURL.key == KeyCombination(key: "l", command: true, control: false, option: false, shift: false))
    _ = NSApplication.shared
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "menu"))
    let menu = harness.makeMenu()
    let items = menu.items.flatMap { [$0] + ($0.submenu.map { $0.items } ?? []) }
    let newTabItem = try #require(items.first { $0.identifier?.rawValue == "new_tab" })
    #expect(newTabItem.keyEquivalent == "t" && newTabItem.keyEquivalentModifierMask == [.command])
    let editURLItem = try #require(items.first { $0.identifier?.rawValue == "edit_url" })
    #expect(editURLItem.keyEquivalent == "l" && editURLItem.keyEquivalentModifierMask == [.command])

    // Opening in each mode: the prefill lands selected, and the placeholders differ [Cra, C:51-52].
    let store = FakeCommandBarStore()
    let (editController, editView, editWindow) = try mountedBar(store, mode: .editURL, prefill: "https://example.test/page")
    defer { _ = editWindow }
    #expect(editController.placeholder == "Edit URL or search…")
    #expect(editController.fieldText == "https://example.test/page")
    let editor = try #require(editView.field.currentEditor())
    try await waitUntil { editor.selectedRange.length == "https://example.test/page".count }
    #expect(editView.field.stringValue == "https://example.test/page")
    let (newController, _, newWindow) = try mountedBar(store)
    defer { _ = newWindow }
    #expect(newController.placeholder == "Search or enter URL…")
    #expect(newController.fieldText.isEmpty)
}

@Test @MainActor
func arrowKeysWrapAndTheFieldShowsTheSelectedRow() throws {
    let store = FakeCommandBarStore()
    let rows = [barRow("GitHub", target: .tab(id: "t1", spaceId: nil), url: "https://github.test/x"),
                barRow("Search docs", target: .command(id: "c1")),
                barRow("Go to Docs", target: .folder(id: "f1", spaceId: "s1"))]
    store.results["git"] = CommandBarResult(rows: rows, privateWindow: false)
    let (controller, view, window) = try mountedBar(store)
    defer { _ = window }
    let editor = try #require(view.field.currentEditor())
    editor.insertText("git")
    #expect(controller.selectedIndex == 0)
    #expect(view.field.stringValue == "git")

    editor.keyDown(with: try barKeyEvent("\u{F701}", keyCode: 125))
    #expect(controller.selectedIndex == 1)
    #expect(view.field.stringValue == "Search docs")
    editor.keyDown(with: try barKeyEvent("\u{F701}", keyCode: 125))
    #expect(controller.selectedIndex == 2)
    #expect(view.field.stringValue == "Go to Docs")
    // ↓ past the last row wraps to the top, and the field shows what was typed again.
    editor.keyDown(with: try barKeyEvent("\u{F701}", keyCode: 125))
    #expect(controller.selectedIndex == 0)
    #expect(controller.previewText == nil)
    #expect(view.field.stringValue == "git")
    // ↑ from the top wraps to the bottom.
    editor.keyDown(with: try barKeyEvent("\u{F700}", keyCode: 126))
    #expect(controller.selectedIndex == 2)
}

@Test @MainActor
func returnCommitsTheSelectedRowCommandReturnForcesANewTabAndEscapeCloses() throws {
    let store = FakeCommandBarStore()
    let rows = [barRow("GitHub", target: .tab(id: "t1", spaceId: nil), url: "https://github.test/"),
                barRow("Open docs", target: .command(id: "c1"))]
    store.results["git"] = CommandBarResult(rows: rows, privateWindow: false)

    // Return commits the selected row, not what is in the field.
    let (controller, view, window) = try mountedBar(store)
    let editor = try #require(view.field.currentEditor())
    editor.insertText("git")
    var commits: [(Suggestion?, CommandBarMode, Bool)] = []
    var closed = 0
    controller.onCommit = { commits.append(($0, $1, $2)) }
    controller.onClose = { closed += 1 }
    controller.moveSelection(by: 1)
    editor.keyDown(with: try barKeyEvent("\r", keyCode: 36))
    try #require(commits.count == 1)
    #expect(commits[0].0?.target == .command(id: "c1"))
    #expect(commits[0].1 == .newTab && commits[0].2 == false)
    #expect(closed == 1 && !controller.isOpen)

    // ⌘Return forces a new tab. The command-modified key arrives in the key-equivalent pass
    // (the field editor's bindings map ⌘Return to noop:); a plain key does not take it.
    let (forced, forcedView, forcedWindow) = try mountedBar(store)
    let forcedEditor = try #require(forcedView.field.currentEditor())
    forcedEditor.insertText("git")
    var forcedCommits: [Bool] = []
    forced.onCommit = { _, _, force in forcedCommits.append(force) }
    #expect(!forcedView.performKeyEquivalent(with: try barKeyEvent("x", keyCode: 7, flags: [.command])))
    #expect(forcedView.performKeyEquivalent(with: try barKeyEvent("\r", keyCode: 36, flags: [.command])))
    #expect(forcedCommits == [true] && !forced.isOpen)

    // Esc closes the bar.
    let (escapable, escapeView, escapeWindow) = try mountedBar(store)
    escapable.update(query: "git")
    var escapableClosed = 0
    escapable.onClose = { escapableClosed += 1 }
    let escapeEditor = try #require(escapeView.field.currentEditor())
    escapeEditor.keyDown(with: try barKeyEvent("\u{1b}", keyCode: 53))
    #expect(escapableClosed == 1 && !escapable.isOpen)
    for window in [window, forcedWindow, escapeWindow] { #expect(!window.isVisible) } // never ordered
}

/// D3: no inline completion. Tab and → stay in the field, and ⌘Return commits the selected row.
@Test @MainActor
func tabAndRightArrowNoLongerAcceptACompletion() throws {
    let store = FakeCommandBarStore()
    store.results["exa"] = CommandBarResult(rows: [barRow("Example", target: .tab(id: "t1", spaceId: nil), url: "https://example.com/page", score: 95)], privateWindow: false)
    let (controller, view, window) = try mountedBar(store)
    defer { _ = window }
    let editor = try #require(view.field.currentEditor())
    editor.insertText("exa")
    #expect(view.field.stringValue == "exa")
    editor.keyDown(with: try barKeyEvent("\t", keyCode: 48))
    #expect(view.field.stringValue == "exa")
    #expect(controller.query == "exa")
    editor.keyDown(with: try barKeyEvent("\u{F703}", keyCode: 124))
    #expect(view.field.stringValue == "exa")
    #expect(controller.query == "exa")
}

@Test @MainActor
func returnAndArrowsGoToTheInputMethodWhileTextIsMarked() throws {
    let store = FakeCommandBarStore()
    let rows = [barRow("GitHub", target: .tab(id: "t1", spaceId: nil), url: "https://github.test/"),
                barRow("Other", target: .command(id: "c1"))]
    store.results["こ"] = CommandBarResult(rows: rows, privateWindow: false)
    let (controller, view, window) = try mountedBar(store)
    defer { _ = window }
    controller.update(query: "こ")
    let editor = try #require(view.field.currentEditor() as? NSTextView)
    var commits: [Suggestion?] = []
    controller.onCommit = { row, _, _ in commits.append(row) }

    // Marked text (an IME composition): Return and ↑/↓ belong to the input method, never to
    // the bar — the coordinator does not consume them and nothing commits or moves.
    editor.setMarkedText("こん", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    let delegate = try #require(view.field.delegate)
    #expect(delegate.control?(view.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) == false)
    #expect(!view.performKeyEquivalent(with: try barKeyEvent("\r", keyCode: 36, flags: .command)))
    view.sync()
    #expect(editor.hasMarkedText() && controller.isOpen && commits.isEmpty)
    editor.keyDown(with: try barKeyEvent("\r", keyCode: 36))
    #expect(commits.isEmpty && controller.isOpen)
    editor.keyDown(with: try barKeyEvent("\u{F701}", keyCode: 125))
    #expect(controller.selectedIndex == 0)
    editor.keyDown(with: try barKeyEvent("\u{F700}", keyCode: 126))
    #expect(controller.selectedIndex == 0)

    // Once the composition ends, the same keys work again.
    editor.unmarkText()
    #expect(!editor.hasMarkedText())
    // The unhandled keys may have edited the field text (there is no real IME here); the
    // result for whatever the field holds now brings the rows back.
    let settled = controller.query
    store.results[settled] = CommandBarResult(rows: rows, privateWindow: false)
    controller.update(query: settled)
    editor.keyDown(with: try barKeyEvent("\r", keyCode: 36))
    // A regression fails here instead of trapping on the index.
    try #require(commits.count == 1)
    #expect(commits[0]?.target == .tab(id: "t1", spaceId: nil))
}

@Test @MainActor
func theSessionIsBuiltOncePerOpenAndDroppedOnClose() throws {
    // The store is handed to the controller only, so its weak reference shows the drop: the
    // test's own strong reference is gone before close() runs.
    var store: FakeCommandBarStore? = FakeCommandBarStore()
    weak var weakStore: FakeCommandBarStore?
    let controller = CommandBarController()
    let view = CommandBarView(controller: controller)
    if let held = store {
        held.results[""] = CommandBarResult(rows: [barRow("Recent", target: .tab(id: "t1", spaceId: nil))], privateWindow: false)
        controller.open(mode: .newTab, prefill: nil, store: held)
        weakStore = held
        store = nil // only the controller holds the store now
        // The empty query asked the session for the recent tabs once.
        #expect(controller.isOpen && controller.result.rows.map(\.title) == ["Recent"])
        #expect(held.queries == [""])
        try #require(weakStore != nil) // alive while the bar is open
        var closed = 0
        controller.onClose = { closed += 1 }
        controller.close()
        #expect(closed == 1 && !controller.isOpen)
    }
    // Dropping the store drops the session's index (built once per open).
    #expect(weakStore == nil)
    _ = view // the view keeps the controller's hooks for the span of the test
}

@Test @MainActor
func tabSpaceAndFolderRowsReachTheCore() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (harness, adapter) = try await commitHarness(directory)

    // Switch to Tab selects the tab in its space.
    harness.commitCommandBar(barRow("Unique Beta", target: .tab(id: "tab-b", spaceId: "space-work")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.selectedId == "tab-b" }

    // Switch to a space shows it.
    harness.commitCommandBar(barRow("Switch to Home", target: .space(id: "space-home")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.sidebar?.spaceShown == 1 && harness.snapshot.shownSpaceId == "space-home" }

    // Go to a folder shows its space and reveals (expands) it.
    _ = try await commitValue { harness.adapter.edit(.collapse(id: "folder-docs", collapsed: true), completion: $0) }
    harness.commitCommandBar(barRow("Go to Docs", target: .folder(id: "folder-docs", spaceId: "space-work")), mode: .newTab, forceNewTab: false)
    try await waitUntil {
        harness.sidebar?.spaceShown == 0 && harness.snapshot.shownSpaceId == "space-work"
            && harness.snapshot.spaces[0].pinned.first { $0.id == "folder-docs" }?.collapsed == false
    }
    _ = try await commitValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func openUrlSearchRowsCreateTodayTabsAndCommandLEditsTheCurrentTab() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (harness, adapter) = try await commitHarness(directory)

    // Open URL creates a selected tab at the top of the shown space's Today.
    harness.commitCommandBar(barRow("example.test", target: .openUrl(url: "https://example.test/from-bar")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.selectedId != nil }
    let createdId = try #require(harness.snapshot.selectedId)
    let shown = try #require(harness.snapshot.shownSpaceId)
    let createdSpace = try #require(harness.snapshot.spaces.first { $0.id == shown })
    #expect(createdSpace.today.first?.id == createdId && createdSpace.today.first?.url == "https://example.test/from-bar")

    // A Search row creates a tab with the engine URL (the Google constant).
    harness.commitCommandBar(barRow("hello world", target: .search(url: "https://www.google.com/search?q=hello+world")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.selectedId != createdId }
    let searchId = try #require(harness.snapshot.selectedId)
    let searchSpace = try #require(harness.snapshot.spaces.first { $0.id == shown })
    #expect(searchSpace.today.first?.id == searchId && searchSpace.today.first?.url == "https://www.google.com/search?q=hello+world")

    // ⌘L (editURL) sends the URL to the current tab instead of creating one.
    harness.commitCommandBar(barRow("example.test/edited", target: .openUrl(url: "https://example.test/edited")), mode: .editURL, forceNewTab: false)
    try await waitUntil { harness.snapshot.spaces.first { $0.id == shown }?.today.first { $0.id == searchId }?.url == "https://example.test/edited" }
    #expect(harness.snapshot.selectedId == searchId)

    // ⌘Return forces a new tab even in edit mode.
    harness.commitCommandBar(barRow("example.test/forced", target: .openUrl(url: "https://example.test/forced")), mode: .editURL, forceNewTab: true)
    try await waitUntil { harness.snapshot.selectedId != nil && harness.snapshot.selectedId != searchId }
    let forcedSpace = try #require(harness.snapshot.spaces.first { $0.id == shown })
    #expect(forcedSpace.today.first?.url == "https://example.test/forced")
    _ = try await commitValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func editingPinnedTabKeepsItsSavedDestination() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (harness, adapter) = try await commitHarness(directory)
    harness.commitCommandBar(barRow("Spec", target: .tab(id: "tab-spec", spaceId: "space-work")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.selectedId == "tab-spec" }
    let saved = harness.selectedTabRow?.url
    harness.commitCommandBar(barRow("Next", target: .openUrl(url: "https://example.test/next")), mode: .editURL, forceNewTab: false)
    #expect(harness.selectedTabRow?.url == saved)
    let persisted = try await commitValue { adapter.snapshot(completion: $0) }
    #expect(persisted.spaces.flatMap(\.pinned).first { $0.id == "tab-spec" }?.url == saved)
    _ = try await commitValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func archiveMoveAndCommandRowsReachTheCore() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (harness, adapter) = try await commitHarness(directory)

    // Restore from archive brings the archived tab back selected.
    _ = try await commitValue { adapter.archive(id: "tab-b", completion: $0) }
    harness.commitCommandBar(barRow("Unique Beta", target: .archive(id: "tab-b")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.selectedId == "tab-b" }

    // Selecting a tab through the bar first, so the move commits have a current selection.
    harness.commitCommandBar(barRow("Unique Alpha", target: .tab(id: "tab-a", spaceId: "space-work")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.selectedId == "tab-a" }

    // A same-profile space to move into: the core refuses cross-profile moves, so the bar
    // never offers Home (Profile 1) for a Work tab. Creating it clears the selection, so the
    // tab is selected through the bar again.
    let created = try await commitValue { adapter.createSpace(name: "Other Work", completion: $0) }
    harness.snapshot = created
    let otherSpace = try #require(created.spaces.last?.id)
    // tab-spec is a plain folder child, so the move takes the tab itself (a split member's
    // move takes its split).
    harness.commitCommandBar(barRow("Spec", target: .tab(id: "tab-spec", spaceId: "space-work")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.selectedId == "tab-spec" }

    // Move Tab to a space lands at the end of the target space's Today.
    harness.commitCommandBar(barRow("Move Tab to Other Work", target: .moveToSpace(id: otherSpace)), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.spaces.first { $0.id == otherSpace }?.today.contains { $0.id == "tab-spec" } == true }

    // Move Tab to a folder puts the tab at the end of that folder.
    harness.commitCommandBar(barRow("Move Tab to Docs", target: .moveToFolder(id: "folder-docs", spaceId: "space-work")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.snapshot.spaces[0].pinned.first { $0.id == "tab-spec" }?.parentId == "folder-docs" }

    // A command row runs the table's command: Toggle Library opens the Library.
    #expect(harness.sidebar?.libraryOpen == false)
    harness.commitCommandBar(barRow("Toggle Library", target: .command(id: "toggle_library")), mode: .newTab, forceNewTab: false)
    try await waitUntil { harness.sidebar?.libraryOpen == true }
    _ = try await commitValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func theRealSessionAnswersQueriesAndRecentTabsWithoutTyping() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (harness, adapter) = try await commitHarness(directory)
    let session = try await commitValue { adapter.commandBarSession(completion: $0) }
    let store = CommandBarSessionStore(session: session)

    // The empty query shows the recent tabs; typing answers from the same per-open index.
    let controller = CommandBarController()
    controller.open(mode: .newTab, prefill: nil, store: store)
    #expect(!controller.result.rows.isEmpty)
    #expect(controller.result.rows.allSatisfy { row in
        switch row.target { case .tab: return true; default: return false }
    })
    controller.update(query: "docs")
    #expect(controller.result.rows.contains { $0.target == .folder(id: "folder-docs", spaceId: "space-work") })
    controller.close()
    _ = try await commitValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func thePanelFollowsTheRowCountOnEveryQuery() throws {
    // The panel's height follows the row count on every query, not only at open: the field
    // stays put and shorter lists hang below it (the note's formula; Cra repositions in
    // observeCommandBar, M:1817-1843).
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    defer { _ = window }
    let controller = CommandBarController()
    let view = CommandBarView(controller: controller)
    let panel = CommandBarPanel()
    panel.contentView = view
    controller.panelWidth = 500
    let store = FakeCommandBarStore()
    store.results[""] = CommandBarResult(rows: [barRow("Recent", target: .tab(id: "t1", spaceId: nil))], privateWindow: false)
    let five = (1...5).map { barRow("Row \($0)", target: .tab(id: "t\($0)", spaceId: nil), url: "https://\($0).test/") }
    store.results["five"] = CommandBarResult(rows: five, privateWindow: false)
    store.results["one"] = CommandBarResult(rows: [barRow("Solo", target: .tab(id: "s1", spaceId: nil), url: "https://s.test/")], privateWindow: false)
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "commandbar-position"))
    harness.window = window
    harness.commandPanel = panel
    harness.commandBar = controller
    controller.onRowsChange = { [weak harness, weak controller] in
        guard let harness, let controller else { return }
        harness.positionCommandPanel(controller)
    }
    panel.makeFirstResponder(view.field)
    let editor = try #require(view.field.currentEditor())
    controller.open(mode: .newTab, prefill: nil, store: store)
    #expect(!window.isVisible && !panel.isVisible) // never ordered
    // The open frame: the empty query's one recent tab.
    try #require(abs(panel.frame.height - CommandBarMetrics.height(forRows: 1)) < 0.5)
    let top = panel.frame.maxY
    #expect(abs(panel.frame.midX - window.frame.midX) < 0.5)
    // A query with five rows grows the panel: same top edge, rows hanging below the field.
    editor.insertText("five")
    #expect(abs(panel.frame.height - CommandBarMetrics.height(forRows: 5)) < 0.5)
    #expect(abs(panel.frame.maxY - top) < 0.5 && abs(panel.frame.midX - window.frame.midX) < 0.5)
    // And a query with fewer rows shrinks it again, still without moving the field.
    editor.selectedRange = NSRange(location: 0, length: (view.field.stringValue as NSString).length)
    editor.insertText("one")
    #expect(abs(panel.frame.height - CommandBarMetrics.height(forRows: 1)) < 0.5)
    #expect(abs(panel.frame.maxY - top) < 0.5 && abs(panel.frame.midX - window.frame.midX) < 0.5)
}

@Test @MainActor
func commandReturnAndReturnCommitTheSelectedRowWithoutACompletionStep() throws {
    // D3: the typed row is the selected row, and Return/⌘Return commit it as it stands; nothing
    // is re-queried first. ⌘Return still forces a new tab.
    let store = FakeCommandBarStore()
    store.results["netflix.c"] = CommandBarResult(rows: [barRow("netflix.c", target: .openUrl(url: "https://netflix.c"))], privateWindow: false)
    let (forced, forcedView, forcedWindow) = try mountedBar(store)
    defer { _ = forcedWindow }
    let forcedEditor = try #require(forcedView.field.currentEditor())
    forcedEditor.insertText("netflix.c")
    var forcedCommits: [(Suggestion?, CommandBarMode, Bool)] = []
    forced.onCommit = { forcedCommits.append(($0, $1, $2)) }
    #expect(forcedView.performKeyEquivalent(with: try barKeyEvent("\r", keyCode: 36, flags: [.command])))
    try #require(forcedCommits.count == 1)
    #expect(forcedCommits[0].0?.target == .openUrl(url: "https://netflix.c"))
    #expect(forcedCommits[0].1 == .newTab && forcedCommits[0].2 == true)

    // Return through the field editor commits the same row and does not force a new tab.
    let (plain, plainView, plainWindow) = try mountedBar(store)
    defer { _ = plainWindow }
    let plainEditor = try #require(plainView.field.currentEditor())
    plainEditor.insertText("netflix.c")
    var commits: [(Suggestion?, CommandBarMode, Bool)] = []
    plain.onCommit = { commits.append(($0, $1, $2)) }
    plainEditor.keyDown(with: try barKeyEvent("\r", keyCode: 36))
    try #require(commits.count == 1)
    #expect(commits[0].0?.target == .openUrl(url: "https://netflix.c"))
    #expect(commits[0].1 == .newTab && commits[0].2 == false)
}

@Test @MainActor
func keysWithoutCommandGoToTheBarField() throws {
    // While the bar's panel is key, a table command rebound
    // without Command is typed into the bar's field, not sunk at AppKit's menu pass.
    let panel = CommandBarPanel()
    let controller = CommandBarController()
    let view = CommandBarView(controller: controller)
    panel.contentView = view
    panel.menuCommandBindings = [KeyBinding(command: "toggle_sidebar", title: "Toggle Sidebar", menu: "View", description: "Show or hide the sidebar.",
                                            defaultKey: KeyCombination(key: "w", command: true, control: false, option: false, shift: false),
                                            key: KeyCombination(key: "w", command: false, control: false, option: true, shift: false),
                                            customized: true, conflicting: false, assignedKey: nil)]
    panel.makeFirstResponder(view.field)
    let editor = try #require(panel.firstResponder as? NSTextView)
    controller.open(mode: .newTab, prefill: nil, store: nil)
    // ⌥W, the rebound Toggle Sidebar: the panel claims the key and types it into the field.
    #expect(panel.performKeyEquivalent(with: try barKeycapEvent("∞", ignoring: "w", keyCode: 13, flags: [.option])))
    #expect(editor.string == "∞")
    // A Command key is never claimed by the field routing: it stays with the bar and the menus.
    #expect(!panel.performKeyEquivalent(with: try barKeycapEvent("d", ignoring: "d", keyCode: 2, flags: [.command])))
    #expect(!panel.isVisible) // never ordered
}

@Test @MainActor
func losingKeyClosesTheBarAfterTheGraceOfOpening() throws {
    // Click-away: the bar closes when its panel resigns key (Cra M:2055-2065). Inside 0.6 s of
    // opening the resign is a focus fight: the bar stays open and the host re-keys the panel.
    var time = Date(timeIntervalSinceReferenceDate: 0)
    let (controller, _, window) = try mountedBar(nil, now: { time })
    defer { _ = window }
    #expect(controller.openedAt == time)
    time = time.addingTimeInterval(0.3)
    #expect(controller.panelDidResignKey() == true && controller.isOpen)
    // After the grace the bar closes.
    time = time.addingTimeInterval(1.0)
    var closed = 0
    controller.onClose = { closed += 1 }
    #expect(controller.panelDidResignKey() == false)
    #expect(closed == 1 && !controller.isOpen)

    // The panel's resigns reach the decision through the harness delegate (the after-grace
    // close; the within-grace re-key makes the panel key again over a real key window, so it
    // stays app-only).
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "commandbar-resign"))
    let resignController = CommandBarController()
    resignController.now = { time }
    let resignView = CommandBarView(controller: resignController)
    let resignPanel = CommandBarPanel()
    resignPanel.contentView = resignView
    resignPanel.delegate = harness
    harness.commandBar = resignController
    harness.commandPanel = resignPanel
    resignController.open(mode: .newTab, prefill: nil, store: nil)
    time = time.addingTimeInterval(1.0)
    var resignClosed = 0
    resignController.onClose = { resignClosed += 1 }
    harness.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: resignPanel))
    #expect(resignClosed == 1 && !resignController.isOpen)
    // A resign from another window (the main window under the panel, for one) does nothing.
    resignController.open(mode: .newTab, prefill: nil, store: nil)
    time = time.addingTimeInterval(0.3)
    harness.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: NSWindow()))
    #expect(resignController.isOpen)
}

@Test @MainActor
func theSessionAppliesWhenItArrivesAndReplaysTheTypedText() throws {
    // The panel and field key at once on ⌘T/⌘L (typing never waits, architecture.md:146); the
    // session applies when it arrives and replays the typed text as the query. The apply-later
    // fix was chosen over building the session synchronously: the workspace clone and the index
    // build keep the adapter's queue discipline off the main thread.
    let store = FakeCommandBarStore()
    store.results["do"] = CommandBarResult(rows: [barRow("Docs", target: .folder(id: "f1", spaceId: "s1"))], privateWindow: false)
    let (controller, view, window) = try mountedBar(nil)
    defer { _ = window }
    #expect(controller.isOpen && controller.result.rows.isEmpty) // keyed before any session
    let editor = try #require(view.field.currentEditor())
    // Typed while the session is pending: the field follows, the rows wait.
    editor.insertText("do")
    #expect(controller.query == "do" && store.queries.isEmpty)
    controller.applyStore(store)
    // The typed text is the query the session answers.
    #expect(controller.result.rows.map(\.title) == ["Docs"])
    #expect(controller.query == "do" && store.queries == ["do"])
}

@Test @MainActor
func returnBeforeTheSessionArrivesCommitsWhenItLands() throws {
    // Return (and ⌘Return) pressed while the session is still on its way must not drop the
    // typed text: the bar stays open and the commit happens once when `applyStore` lands.
    // The gap is one adapter round trip; a paste followed by Return right
    // after ⌘T can hit it.
    let store = FakeCommandBarStore()
    store.results["https://a.test"] = CommandBarResult(rows: [barRow("https://a.test", target: .openUrl(url: "https://a.test"))], privateWindow: false)

    // Type, Return, then deliver the store: the commit happens once, with the typed text.
    let (controller, view, window) = try mountedBar(nil)
    defer { _ = window }
    let editor = try #require(view.field.currentEditor())
    editor.insertText("https://a.test")
    #expect(controller.query == "https://a.test" && store.queries.isEmpty)
    var commits: [(Suggestion?, CommandBarMode, Bool)] = []
    var closed = 0
    controller.onCommit = { commits.append(($0, $1, $2)) }
    controller.onClose = { closed += 1 }
    editor.keyDown(with: try barKeyEvent("\r", keyCode: 36))
    // In the gap nothing commits and the bar stays open.
    #expect(commits.isEmpty && closed == 0 && controller.isOpen)
    // The session lands: the commit carries the typed text once.
    controller.applyStore(store)
    try #require(commits.count == 1)
    #expect(commits[0].0?.target == .openUrl(url: "https://a.test"))
    #expect(commits[0].1 == .newTab && commits[0].2 == false)
    #expect(closed == 1 && !controller.isOpen)
    #expect(store.queries == ["https://a.test"])

    // ⌘Return in the gap commits forced when the session lands.
    let (forced, forcedView, forcedWindow) = try mountedBar(nil)
    defer { _ = forcedWindow }
    let forcedEditor = try #require(forcedView.field.currentEditor())
    forcedEditor.insertText("https://a.test")
    var forcedCommits: [Bool] = []
    forced.onCommit = { _, _, force in forcedCommits.append(force) }
    #expect(forcedView.performKeyEquivalent(with: try barKeyEvent("\r", keyCode: 36, flags: [.command])))
    #expect(forcedCommits.isEmpty && forced.isOpen)
    forced.applyStore(store)
    try #require(forcedCommits.count == 1)
    #expect(forcedCommits[0] == true && !forced.isOpen)
}

