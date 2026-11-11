import AppKit
import AraratKit
import Testing
import SQLite3
@testable import AraratUI
@testable import AraratHarness

@MainActor
private final class MenuFixture {
    let directory: URL
    let store: WorkspaceStore
    let sidebar: SidebarView
    let window: NSWindow
    var edits: [SidebarItemEdit] = []
    var moves: [(String, String, Int)] = []
    var closes: [String] = []
    var archives: [String] = []
    init() throws {
        directory = try testTemporaryDirectory()
        store = try WorkspaceStore.open(path: directory.appendingPathComponent("menus.sqlite").path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        _ = try store.importArcSidebar(windowId: "menus", json: String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8), windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil).snapshot
        _ = try store.createSpace(windowId: "menus", name: "Other", spaceId: "other")
        try store.showSpace(windowId: "menus", spaceId: "space-work")
        _ = NSApplication.shared
        sidebar = SidebarView(snapshot: store.snapshot(windowId: "menus"))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: [], backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.layoutSubtreeIfNeeded()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.onItemEdit = { [weak self] edit, done in
            guard let self else { done(nil); return }
            self.edits.append(edit)
            do {
                let result: WorkspaceSnapshot
                switch edit {
                case let .createFolder(id, container, index): result = try self.store.createFolder(windowId: "menus", id: id, name: "Untitled", container: container, index: UInt32(index), wrapping: [])
                case let .rename(id, title, folder): result = try folder ? self.store.renameFolder(windowId: "menus", id: id, name: title) : self.store.renameTab(windowId: "menus", id: id, title: title)
                case let .collapse(id, collapsed): result = try self.store.setFolderCollapsed(windowId: "menus", id: id, collapsed: collapsed)
                case let .duplicate(id): result = try self.store.duplicateItem(windowId: "menus", id: id)
                case let .deleteFolder(id): result = try self.store.deleteFolder(windowId: "menus", id: id)
                }
                done(result)
            } catch { Issue.record("edit failed: \(error)"); done(nil) }
        }
        sidebar.onMove = { [weak self] id, container, index, open, done in
            guard let self else { done(nil); return }
            self.moves.append((id, container, index))
            do { done(try self.store.moveItem(windowId: "menus", id: id, container: container, index: UInt32(index), openFolder: open)) }
            catch { Issue.record("move failed: \(error)"); done(nil) }
        }
        sidebar.onClose = { [weak self] id in
            self?.closes.append(id)
            do { if let self { self.sidebar.applySelection(snapshot: try self.store.closeItem(windowId: "menus", id: id)) } }
            catch { Issue.record("close failed: \(error)") }
        }
        sidebar.onArchive = { [weak self] id in
            self?.archives.append(id)
            do { if let self { self.sidebar.applySelection(snapshot: try self.store.archiveItem(windowId: "menus", id: id)) } }
            catch { Issue.record("archive failed: \(error)") }
        }
        sidebar.dragReduceMotion = { true }
    }
    var snapshot: WorkspaceSnapshot { store.snapshot(windowId: "menus") }
    var space: SpaceSnapshot { snapshot.spaces.first { $0.id == "space-work" }! }
    func row(_ id: String) throws -> Row { try #require(snapshot.spaces.flatMap { $0.favorites + $0.pinned + $0.today }.first { $0.id == id }) }
    func view(_ id: String) throws -> SidebarRowView { try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == id }) }
    func dispose() { window.contentView = nil; try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor
private func invoke(_ menu: NSMenu, _ title: String) throws {
    let item = try #require(menu.items.first { $0.title == title })
    #expect(item.isEnabled)
    #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
}

@Test @MainActor
func menusExposeOnlySupportedItemsInMeasuredOrderAndUsePrivatePasteboard() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let pin = try f.row("tab-spec")
    let favorite = try f.row("tab-mail")
    let folder = try f.row("folder-docs")
    let menus = [f.sidebar.todayMenu(row: pin), f.sidebar.pinnedMenu(row: pin), f.sidebar.favoriteMenu(row: favorite), f.sidebar.folderMenu(row: folder)]
    let titles = [["Copy Link", "Rename…", "Duplicate", "Move to", "Archive Tab"], ["Copy Link", "Rename…", "Duplicate", "Move to", "Remove Pin"], ["Copy Link", "Rename…", "Move to", "Close Tab", "Remove Favorite"], ["New Nested Folder…", "Rename…", "Duplicate", "Move to", "Delete"]]
    for (menu, expected) in zip(menus, titles) {
        #expect(menu.items.map(\.title) == expected)
        #expect(menu.items.allSatisfy { $0.isEnabled })
        #expect(!menu.autoenablesItems)
        #expect(menu.items.allSatisfy { $0.title == "Move to" || ($0.target != nil && $0.action != nil) })
        #expect(menu.items.contains { $0.title == "Duplicate" } == (menu !== menus[2]))
    }
    #expect(menus[2].items[3].keyEquivalent == "w")
    #expect(menus[2].items[2].keyEquivalentModifierMask == .command)
    #expect(menus[0].items[3].submenu?.items.map(\.title) == ["Other"])
    #expect(f.sidebar.emptyAreaMenu().items.map(\.title) == ["New Folder"])
    #expect(f.sidebar.newSpaceMenu.items.map(\.title) == ["New Space", "New Folder"])
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("Ararat-menu-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    f.sidebar.pasteboard = pasteboard
    for (menu, row) in zip(menus.prefix(3), [pin, pin, favorite]) {
        try invoke(menu, "Copy Link")
        #expect(pasteboard.string(forType: .string) == row.url)
    }
    var invalid = pin; invalid.url = nil
    #expect(f.sidebar.todayMenu(row: invalid).items[0].isEnabled == false)
    var noTargets = f.snapshot; noTargets.spaces.removeAll { $0.id == "other" }
    f.sidebar.update(snapshot: noTargets)
    #expect(!f.sidebar.pinnedMenu(row: pin).items[3].isEnabled)
    #expect(!f.window.isVisible && !f.window.isKeyWindow)
}

@Test @MainActor
func menuActionsMoveArchiveAndCloseExactlyOnce() throws {
    for action in ["Remove Pin", "Move pinned", "Move today", "Move folder", "Move favorite", "Archive Tab", "Close Tab", "Remove Favorite"] {
        let f = try MenuFixture(); defer { f.dispose() }
        let pin = try f.row("tab-spec")
        if action == "Remove Pin" {
            try invoke(f.sidebar.pinnedMenu(row: pin), action)
            #expect(f.moves.count == 1 && f.moves[0].1 == "today-work" && f.moves[0].2 == 0)
            #expect(f.space.today.first?.id == pin.id)
        } else if action.hasPrefix("Move") {
            var row = pin
            if action == "Move folder" { row = try f.row("folder-docs") }
            if action == "Move favorite" { row = try f.row("tab-mail") }
            if action == "Move today" {
                let result = try f.store.moveItem(windowId: "menus", id: pin.id, container: "today-work", index: 0, openFolder: false)
                f.sidebar.update(snapshot: result); row = try f.row(pin.id)
            }
            let menu = row.kind == .folder ? f.sidebar.folderMenu(row: row) : action == "Move today" ? f.sidebar.todayMenu(row: row) : action == "Move favorite" ? f.sidebar.favoriteMenu(row: row) : f.sidebar.pinnedMenu(row: row)
            try invoke(try #require(menu.items.first { $0.title == "Move to" }?.submenu), "Other")
            let other = try #require(f.snapshot.spaces.first { $0.id == "other" })
            #expect(f.moves.count == 1)
            #expect(f.moves[0].1 == (action == "Move today" ? other.todayId : other.pinnedId))
            #expect(f.snapshot.shownSpaceId == "space-work" && f.sidebar.spaceShown == 0)
        } else if action == "Archive Tab" {
            let result = try f.store.moveItem(windowId: "menus", id: pin.id, container: "today-work", index: 0, openFolder: false)
            f.sidebar.update(snapshot: result)
            try invoke(f.sidebar.todayMenu(row: try f.row(pin.id)), action)
            #expect(f.archives == [pin.id] && f.snapshot.archive.contains { $0.id == pin.id })
        } else {
            try invoke(f.sidebar.favoriteMenu(row: try f.row("tab-mail")), action)
            if action == "Remove Favorite" {
                #expect(f.archives == ["tab-mail"] && f.space.favorites.isEmpty)
            } else {
                #expect(f.closes == ["tab-mail"] && f.space.favorites.first?.unloaded == true)
            }
            #expect(!f.space.today.contains { $0.id == "tab-mail" })
        }
    }
}

@Test @MainActor
func organizeRenameAndDeleteResolveFolderFocusOrSelectedTab() throws {
    do {
        let f = try MenuFixture(); defer { f.dispose() }
        f.sidebar.updateSelection(id: "tab-spec")
        let folder = try f.view("folder-docs")
        #expect(f.window.makeFirstResponder(folder))
        #expect(f.sidebar.canDeleteOrganizeFolder)
        f.sidebar.organize(command: "rename")
        #expect(folder.renameField != nil)
        folder.finishRename(commit: false)
    }
    do {
        let f = try MenuFixture(); defer { f.dispose() }
        f.sidebar.updateSelection(id: "tab-spec")
        let unrelated = try f.view("tab-a")
        #expect(f.window.makeFirstResponder(unrelated))
        f.sidebar.organize(command: "rename")
        #expect(try f.view("tab-spec").renameField != nil && unrelated.renameField == nil)
        try f.view("tab-spec").finishRename(commit: false)
    }
    for focused in [true, false] {
        let f = try MenuFixture(); defer { f.dispose() }
        f.sidebar.updateSelection(id: focused ? "tab-mail" : "tab-spec")
        #expect(f.window.makeFirstResponder(focused ? try f.view("folder-docs") : f.sidebar))
        #expect(f.sidebar.canDeleteOrganizeFolder)
        f.sidebar.confirmFolderDeletion = { _, done in done(true) }
        f.sidebar.organize(command: "delete_folder")
        #expect(!f.space.pinned.contains { $0.id == "folder-docs" })
    }
    do {
        let f = try MenuFixture(); defer { f.dispose() }
        #expect(f.window.makeFirstResponder(try f.view("folder-docs")))
        f.sidebar.organize(command: "new_folder")
        let id = try #require(f.sidebar.renamingID)
        #expect(try f.row(id).parentId == "folder-docs")
    }
    do {
        let f = try MenuFixture(); defer { f.dispose() }
        f.sidebar.updateSelection(id: "tab-mail")
        #expect(f.window.makeFirstResponder(f.sidebar))
        #expect(!f.sidebar.canDeleteOrganizeFolder)
        let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "menu-validation"))
        harness.sidebar = f.sidebar
        let menu = harness.makeMenu()
        let item = try #require(menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.identifier?.rawValue == "delete_folder" })
        #expect(!harness.validateMenuItem(item))
        f.sidebar.updateSelection(id: "tab-spec")
        #expect(harness.validateMenuItem(item))
        f.sidebar.updateSelection(id: "tab-mail")
        f.sidebar.organize(command: "delete_folder")
        #expect(f.edits.isEmpty)
    }
}

@Test @MainActor
func organizeCommandsActOnSelectedRowsAndRespectHiddenOrEditingStates() throws {
    do {
        let f = try MenuFixture(); defer { f.dispose() }
        f.sidebar.updateSelection(id: "tab-spec")
        f.sidebar.organize(command: "duplicate")
        #expect(f.edits.count == 1 && f.space.pinned.filter { $0.url == "https://docs.example.com/spec" }.count == 2)
        f.sidebar.updateSelection(id: "tab-mail")
        f.sidebar.organize(command: "duplicate")
        #expect(f.edits.count == 1)
        f.sidebar.updateSelection(id: "tab-spec")
        f.sidebar.organize(command: "rename")
        let row = try f.view("tab-spec")
        #expect(row.renameField != nil)
        f.sidebar.organize(command: "duplicate")
        f.sidebar.organize(command: "new_folder")
        #expect(f.edits.count == 1)
        row.finishRename(commit: false)
        f.sidebar.organize(command: "delete_folder")
        #expect(f.edits.count == 1)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        f.sidebar.addSubview(text)
        #expect(f.window.makeFirstResponder(text))
        f.sidebar.organize(command: "duplicate")
        f.sidebar.organize(command: "new_folder")
        #expect(f.edits.count == 1)
        #expect(f.window.makeFirstResponder(f.sidebar))
        f.sidebar.setLibraryOpen(true)
        f.sidebar.organize(command: "duplicate")
        f.sidebar.organize(command: "new_folder")
        #expect(f.edits.count == 1)
        f.sidebar.setLibraryOpen(false)
        f.sidebar.setCreateSpaceOpen(true)
        f.sidebar.organize(command: "duplicate")
        f.sidebar.organize(command: "new_folder")
        #expect(f.edits.count == 1)
        f.sidebar.setCreateSpaceOpen(false)
    }
    do {
        let f = try MenuFixture(); defer { f.dispose() }
        f.sidebar.confirmFolderDeletion = { _, completion in completion(true) }
        #expect(f.window.makeFirstResponder(try f.view("folder-docs")))
        f.sidebar.organize(command: "delete_folder")
        #expect(!f.space.pinned.contains { $0.id == "folder-docs" })
    }
    for origin in ["today", "pinned", "favorite", "foreign"] {
        let f = try MenuFixture(); defer { f.dispose() }
        if origin != "foreign" { _ = try f.store.moveSpace(windowId: "menus", spaceId: "other", index: 1) }
        var id = "tab-spec"
        if origin == "today" { _ = try f.store.moveItem(windowId: "menus", id: id, container: "today-work", index: 0, openFolder: false) }
        if origin == "favorite" { id = "tab-mail" }
        f.sidebar.update(snapshot: f.snapshot)
        f.sidebar.updateSelection(id: id)
        f.sidebar.organize(command: "move_to_space_2")
        if origin == "foreign" { #expect(f.moves.isEmpty) }
        else {
            let other = try #require(f.snapshot.spaces.first { $0.id == "other" })
            #expect(f.moves.count == 1 && f.moves[0].1 == (origin == "today" ? other.todayId : other.pinnedId))
        }
    }
    do {
        let f = try MenuFixture(); defer { f.dispose() }
        f.sidebar.updateSelection(id: "tab-spec")
        f.sidebar.organize(command: "new_folder")
        let id = try #require(f.sidebar.renamingID)
        #expect(try f.row(id).parentId == f.space.pinnedId)
    }
}

@Test @MainActor
func renameCommitsCancelsClearsAndRefusesEmptyFolder() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let row = try f.view("tab-spec")
    try invoke(f.sidebar.pinnedMenu(row: row.row), "Rename…")
    let field = try #require(row.renameField)
    field.stringValue = "Named"
    #expect(field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(try f.row("tab-spec").title == "Named" && row.renameField == nil && f.edits.count == 1)
    f.sidebar.beginRename(id: row.row.id)
    row.renameField?.stringValue = "Discard"
    let cancelling = try #require(row.renameField)
    #expect(cancelling.control(cancelling, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(try f.row("tab-spec").title == "Named" && f.edits.count == 1)
    f.sidebar.beginRename(id: row.row.id)
    row.renameField?.stringValue = ""
    row.renameField?.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
    #expect(try f.row("tab-spec").title == "Spec" && f.edits.count == 2)
    let folder = try f.view("folder-docs")
    f.sidebar.beginRename(id: folder.row.id)
    folder.renameField?.stringValue = "  "
    folder.finishRename(commit: true)
    #expect(folder.renameField != nil && f.edits.count == 2)
    folder.renameField?.stringValue = "Sources"
    folder.finishRename(commit: true)
    #expect(try f.row("folder-docs").title == "Sources" && f.edits.count == 3)
    let favorite = try #require(descendants(f.sidebar).compactMap { $0 as? FavoriteTile }.first)
    try invoke(f.sidebar.favoriteMenu(row: favorite.row), "Rename…")
    favorite.renameField?.stringValue = "Inbox"
    favorite.renameField?.finish(commit: true)
    #expect(try f.row("tab-mail").title == "Inbox" && f.edits.count == 4)
}

@Test @MainActor
func newFoldersAppendAndRenameAndDeletionUsesInjectedConfirmation() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let previous = f.space.pinnedCount
    try invoke(f.sidebar.newSpaceMenu, "New Folder")
    let id = try #require(f.sidebar.renamingID)
    let row = try f.row(id)
    #expect(row.title == "Untitled" && row.parentId == "pin-work" && row.siblingIndex == previous)
    #expect(try f.view(id).renameField != nil)
    try f.view(id).finishRename(commit: false)
    var confirmations = 0
    var confirm = false
    f.sidebar.confirmFolderDeletion = { row, done in
        confirmations += 1; #expect(row.id == "folder-docs"); done(confirm)
    }
    try invoke(f.sidebar.folderMenu(row: row), "Delete")
    #expect(confirmations == 0 && !f.space.pinned.contains { $0.id == id })
    _ = try f.store.setFolderCollapsed(windowId: "menus", id: "folder-docs", collapsed: true)
    f.sidebar.update(snapshot: f.snapshot)
    let folder = try f.row("folder-docs")
    #expect(folder.folderHasTabs && !f.space.pinned.contains { $0.id == "tab-spec" })
    let before = f.edits.count
    try invoke(f.sidebar.folderMenu(row: folder), "Delete")
    #expect(confirmations == 1 && f.edits.count == before)
    confirm = true
    try invoke(f.sidebar.folderMenu(row: folder), "Delete")
    #expect(confirmations == 2 && f.edits.count == before + 1)
    #expect(!f.space.pinned.contains { $0.id == folder.id })
    #expect(f.snapshot.archive.contains { $0.id == "tab-spec" })
}

@Test @MainActor
func nestedFolderCreationOpensParentAndDoubleClickStartsRename() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    _ = try f.store.setFolderCollapsed(windowId: "menus", id: "folder-docs", collapsed: true)
    f.sidebar.update(snapshot: f.snapshot)
    try invoke(f.sidebar.folderMenu(row: try f.row("folder-docs")), "New Nested Folder…")
    let id = try #require(f.sidebar.renamingID)
    #expect(try f.row(id).parentId == "folder-docs" && f.row(id).siblingIndex == 1)
    #expect(try f.row("folder-docs").collapsed == false)
    try f.view(id).finishRename(commit: false)
    let pin = try f.view("tab-spec")
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
    pin.mouseDown(with: event)
    #expect(f.sidebar.renamingID == pin.row.id && pin.renameField != nil && f.sidebar.drag == nil)
    #expect(descendants(pin).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Double-click to rename" && !$0.isHidden } == false)
    pin.finishRename(commit: false)
}

@Test @MainActor
func folderClickAndAccessibilityTogglePersistButDraggingNeverToggles() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let folder = try f.view("folder-docs")
    let point = folder.convert(NSPoint(x: 30, y: 20), to: nil)
    func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    folder.mouseDown(with: try event(.leftMouseDown, point))
    folder.mouseUp(with: try event(.leftMouseUp, point))
    #expect(try f.row("folder-docs").collapsed)
    #expect(f.edits.count == 1)
    let expanded = try #require(folder.accessibilityCustomActions()?.first)
    #expect(expanded.name == "Expand" && expanded.handler?() == true)
    #expect(try !f.row("folder-docs").collapsed && f.edits.count == 2)
    folder.mouseDown(with: try event(.leftMouseDown, point))
    folder.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: point.x + 4, y: point.y)))
    folder.mouseUp(with: try event(.leftMouseUp, NSPoint(x: -20, y: -20)))
    #expect(f.edits.count == 2 && f.sidebar.drag == nil)
    #expect(try !f.row("folder-docs").collapsed)
    _ = try f.store.setFolderCollapsed(windowId: "menus", id: "folder-docs", collapsed: true)
    try f.store.flush()
    let reopened = try WorkspaceStore.open(path: f.directory.appendingPathComponent("menus.sqlite").path)
    #expect(reopened.snapshot(windowId: "menus").spaces[0].pinned.first { $0.id == "folder-docs" }?.collapsed == true)
}

@Test @MainActor
func rowMenusParticipateInTooltipTrackingWithoutShowingMenus() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let menu = f.sidebar.folderMenu(row: try f.row("folder-docs"))
    f.sidebar.menuWillOpen(menu)
    #expect(f.sidebar.tooltip.menuTracking)
    f.sidebar.menuDidClose(menu)
    #expect(!f.sidebar.tooltip.menuTracking)
    let row = try f.view("tab-spec")
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    #expect(row.menu(for: event)?.items.map(\.title) == ["Copy Link", "Rename…", "Duplicate", "Move to", "Remove Pin"])
}

@Test @MainActor
func adapterFolderAndRenameEditsReachTheCoreAndPersist() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let adapter = WorkspaceAdapter(windowID: "menu-adapter")
    func value<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { done in start { done.resume(with: $0) } }
    }
    let path = directory.appendingPathComponent("adapter.sqlite").path
    _ = try await value { adapter.open(path: path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let created = try await value { adapter.edit(.createFolder(id: "new", container: "pin-work", index: 2), completion: $0) }
    #expect(created.spaces[0].pinned.last?.id == "new")
    let renamed = try await value { adapter.edit(.rename(id: "new", title: "Named", folder: true), completion: $0) }
    #expect(renamed.spaces[0].pinned.last?.title == "Named")
    _ = try await value { adapter.edit(.rename(id: "tab-spec", title: "Custom", folder: false), completion: $0) }
    let cleared = try await value { adapter.edit(.rename(id: "tab-spec", title: "", folder: false), completion: $0) }
    #expect(cleared.spaces[0].pinned.first { $0.id == "tab-spec" }?.title == "Spec")
    let folded = try await value { adapter.edit(.collapse(id: "folder-docs", collapsed: true), completion: $0) }
    #expect(folded.spaces[0].pinned.first { $0.id == "folder-docs" }?.collapsed == true)
    #expect(folded.spaces[0].pinned.first { $0.id == "folder-docs" }?.folderHasTabs == true)
    let deleted = try await value { adapter.edit(.deleteFolder(id: "new"), completion: $0) }
    #expect(!deleted.spaces[0].pinned.contains { $0.id == "new" })
    _ = try await value { adapter.shutdown(completion: $0) }
    let reopened = try WorkspaceStore.open(path: path)
    #expect(reopened.snapshot(windowId: "menu-adapter").spaces[0].pinned.first { $0.id == "folder-docs" }?.collapsed == true)
}

@Test @MainActor
func everyRowMenuHoldsFloatingSidebarUntilTrackingEnds() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let container = SidebarContainerView(sidebar: f.sidebar, page: NSView())
    container.applicationActive = { true }
    container.windowKey = { true }
    container.pressedButtons = { 0 }
    var now = 0.0
    var point = NSPoint(x: f.window.frame.minX, y: f.window.frame.midY)
    container.clock = { now }
    container.pointerLocation = { point }
    f.window.contentView = container
    f.sidebar.updateSelection(id: "tab-spec")
    container.selectionChanged()
    container.layoutSubtreeIfNeeded()
    let pin = try f.row("tab-spec")
    let menus = [f.sidebar.todayMenu(row: pin), f.sidebar.pinnedMenu(row: pin), f.sidebar.favoriteMenu(row: try f.row("tab-mail")), f.sidebar.folderMenu(row: try f.row("folder-docs")), f.sidebar.emptyAreaMenu()]
    for menu in menus {
        point.x = f.window.frame.minX
        if container.sidebarState != "hidden" { container.toggleSidebar() }
        container.processPointer()
        now += 0.2
        container.processPointer()
        #expect(container.sidebarState == "floating")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        point.x = f.window.frame.maxX + 100
        container.processPointer()
        #expect(container.sidebarState == "floating" && f.sidebar.tooltip.menuTracking)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(container.sidebarState == "hidden" && !f.sidebar.tooltip.menuTracking)
    }
    #expect(!f.window.isVisible && !f.window.isKeyWindow)
}

@Test @MainActor
func unchangedRenameSkipsCoreEditsAndKeepsFollowingThePageTitle() throws {
    for folder in [false, true] {
        for focusLoss in [false, true] {
            let f = try MenuFixture(); defer { f.dispose() }
            let id = folder ? "folder-docs" : "tab-mail"
            let row = try f.row(id)
            try invoke(folder ? f.sidebar.folderMenu(row: row) : f.sidebar.favoriteMenu(row: row), "Rename…")
            let field: SidebarRenameField
            if folder { field = try #require(f.view(id).renameField) }
            else { field = try #require(descendants(f.sidebar).compactMap { $0 as? FavoriteTile }.first?.renameField) }
            field.stringValue = "  " + row.title + "  "
            if focusLoss { field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification)) }
            else { _ = field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))) }
            #expect(f.edits.isEmpty && f.sidebar.renamingID == nil)
            if !folder {
                try f.store.flush()
                var connection: OpaquePointer?
                try #require(sqlite3_open(f.directory.appendingPathComponent("menus.sqlite").path, &connection) == SQLITE_OK)
                defer { sqlite3_close(connection) }
                try #require(sqlite3_exec(connection, "UPDATE records SET body = json_set(body, '$.kind.Tab.saved_title', 'Updated Mail') WHERE kind = 'item' AND id = 'tab-mail'", nil, nil, nil) == SQLITE_OK)
                let reopened = try WorkspaceStore.open(path: f.directory.appendingPathComponent("menus.sqlite").path)
                #expect(reopened.snapshot(windowId: "menus").spaces[0].favorites.first?.title == "Updated Mail")
            }
        }
    }
}

@Test @MainActor
func folderDoubleClickTogglesTwiceWithoutRenaming() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let folder = try f.view("folder-docs")
    let point = folder.convert(NSPoint(x: 30, y: 20), to: nil)
    for count in [1, 2] {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            if type == .leftMouseDown { folder.mouseDown(with: event) }
            else { folder.mouseUp(with: event) }
        }
    }
    #expect(f.edits.count == 2)
    #expect(try !f.row("folder-docs").collapsed)
    #expect(folder.renameField == nil && f.sidebar.renamingID == nil)
}

@Test @MainActor
func pinFromTodayShowsTimedHintWithSeparatedTextAndRestarts() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    _ = try f.store.moveItem(windowId: "menus", id: "tab-spec", container: f.space.todayId, index: 0, openFolder: false)
    _ = try f.store.selectItem(windowId: "menus", id: "tab-spec")
    f.sidebar.update(snapshot: f.snapshot)
    var now: CFTimeInterval = 100
    f.sidebar.renameHintClock = { now }
    f.sidebar.dragReduceMotion = { false }
    let row = try f.view("tab-spec")
    let hint = try #require(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Double-click to rename" })
    func pin() throws {
        _ = try f.store.moveItem(windowId: "menus", id: row.row.id, container: f.space.pinnedId, index: 0, openFolder: false)
        f.sidebar.update(snapshot: f.snapshot)
        row.showRenameHint()
    }
    func unpin() throws {
        _ = try f.store.moveItem(windowId: "menus", id: row.row.id, container: f.space.todayId, index: 0, openFolder: false)
        f.sidebar.update(snapshot: f.snapshot)
    }
    #expect(hint.isHidden)
    try pin()
    #expect(!hint.isHidden && hint.alphaValue == 1)
    #expect(row.hintTimer?.timeInterval == 0)
    let holdTimer = try #require(row.hintTimer)
    #expect(holdTimer.fireDate.timeIntervalSinceNow > 2 && holdTimer.fireDate.timeIntervalSinceNow <= 3)
    f.sidebar.layoutSubtreeIfNeeded()
    let title = try #require(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == row.row.title })
    #expect(!title.frame.intersects(hint.frame))
    #expect(title.frame.midY > row.bounds.midY)
    #expect(title.frame.minY - hint.frame.maxY >= 2)
    now = 102.9
    row.refreshRenameHint()
    #expect(!hint.isHidden && hint.alphaValue == 1)
    now = 103.1
    row.refreshRenameHint()
    #expect(abs(hint.alphaValue - 0.5) < 0.001)
    #expect(row.hintTimer?.timeInterval == 1.0 / 60)
    now = 103.2
    row.refreshRenameHint()
    #expect(hint.isHidden && row.hintTimer == nil)
    try unpin()
    try pin()
    now += 2
    row.refreshRenameHint()
    #expect(!hint.isHidden)
    f.sidebar.updateSelection(id: "tab-mail")
    #expect(hint.isHidden)
    f.sidebar.updateSelection(id: row.row.id)
    #expect(hint.isHidden)
    try unpin()
    try pin()
    f.sidebar.dragReduceMotion = { true }
    now += 3
    row.refreshRenameHint()
    #expect(hint.isHidden)
    try unpin()
    try pin()
    row.beginRename()
    #expect(hint.isHidden)
    let field = try #require(row.renameField)
    #expect(field.focusRingType == .none && !field.isBezeled && !field.isBordered && !field.drawsBackground)
    row.finishRename(commit: false)
}

@Test @MainActor
func renameFieldHasNoFocusRingBezelOrBackground() {
    let field = SidebarRenameField(title: "A", save: { _, done in done(true) }, ended: {})
    #expect(field.focusRingType == .none)
    #expect(!field.isBezeled && !field.isBordered && !field.drawsBackground)
}

@Test @MainActor
func narrowPinnedHintStopsBeforeVisibleCloseButton() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    f.sidebar.frame.size.width = 164
    f.sidebar.updateSelection(id: "tab-spec")
    let row = try f.view("tab-spec")
    row.showRenameHint()
    row.pointerLocation = { row.convert(NSPoint(x: 60, y: 20), to: nil) }
    row.refreshHover()
    f.sidebar.layoutSubtreeIfNeeded()
    let hint = try #require(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Double-click to rename" })
    #expect(!hint.isHidden && !row.closeButton.isHidden)
    #expect(hint.frame.maxX <= row.closeButton.frame.minX)
}

@Test @MainActor
func duplicateMenusCopyAfterOriginalWithoutChangingSelection() throws {
    for source in ["folder-docs", "tab-spec", "tab-a"] {
        let f = try MenuFixture(); defer { f.dispose() }
        let row = try f.row(source)
        let original = source == "tab-a" ? "split-1" : source
        let parent = try #require(f.space.pinned.first { $0.id == original }?.parentId)
        let before = f.space.pinned.filter { $0.parentId == parent }
        let index = try #require(before.firstIndex { $0.id == original })
        let menu = row.kind == .folder ? f.sidebar.folderMenu(row: row) : f.sidebar.pinnedMenu(row: row)
        let selected = f.snapshot.selectedId
        try invoke(menu, "Duplicate")
        let after = f.space.pinned.filter { $0.parentId == parent }
        #expect(after.count == before.count + 1)
        #expect(after[index].id == original)
        #expect(!before.contains { $0.id == after[index + 1].id })
        #expect(after[index + 1].kind == before[index].kind)
        #expect(f.snapshot.selectedId == selected)
        #expect(descendants(f.sidebar).compactMap { $0 as? SidebarRowView }.contains { $0.row.id == after[index + 1].id })
        #expect(f.edits.count == 1)
        #expect(!f.window.isVisible && !f.window.isKeyWindow)
    }
    let f = try MenuFixture(); defer { f.dispose() }
    let snapshot = try f.store.moveItem(windowId: "menus", id: "tab-spec", container: "today-work", index: 0, openFolder: false)
    f.sidebar.update(snapshot: snapshot)
    let row = try f.row("tab-spec")
    try invoke(f.sidebar.todayMenu(row: row), "Duplicate")
    #expect(f.space.today[0].id == "tab-spec")
    #expect(f.space.today.count == 2)
    #expect(f.space.today[1].id != "tab-spec")
}

@Test @MainActor
func dockSpaceMenuActionsAndAvailability() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let cell = try #require(descendants(f.sidebar).compactMap { $0 as? SpaceDockButton }.first { $0.spaceID == "space-work" })
    #expect(cell.accessibilityHelp() == f.space.title)
    let menu = f.sidebar.spaceMenu(spaceID: "space-work")
    f.sidebar.update(snapshot: f.snapshot)
    #expect(descendants(f.sidebar).contains { $0 === cell })
    #expect(menu.items.map(\.title) == ["Rename Space…", "Edit Look…", "Space Settings…", "New Folder", "Delete Space…"])
    #expect(f.sidebar.dockMenuItems(for: "space-work").map(\.title) == menu.items.map(\.title))
    #expect(menu.items.allSatisfy { $0.isEnabled })
    var settings: String?
    f.sidebar.onSpaceSettings = { settings = $0 }
    try invoke(menu, "Space Settings…")
    #expect(settings == "space-work")
    var saved: (String, String)?
    f.sidebar.onRenameSpace = { id, name, done in saved = (id, name); done(true) }
    try invoke(menu, "Rename Space…")
    let field = try #require(descendants(f.sidebar).compactMap { $0 as? SidebarRenameField }.first)
    field.stringValue = "Renamed"
    field.finish(commit: true)
    #expect(saved?.0 == "space-work" && saved?.1 == "Renamed")
    try invoke(menu, "New Folder")
    #expect(f.edits.count == 1)
    let missing = f.sidebar.spaceMenu(spaceID: "missing")
    #expect(missing.items.allSatisfy { !$0.isEnabled })
    var snapshot = f.snapshot
    snapshot.spaces = [f.space]
    f.sidebar.update(snapshot: snapshot)
    #expect(!f.sidebar.spaceMenu(spaceID: "space-work").items[4].isEnabled)
}

@Test @MainActor
func otherDockCellRenamesItsOwnSpaceAfterTheSwitchCompletes() throws {
    let f = try MenuFixture(); defer { f.dispose() }
    let index = try #require(f.snapshot.spaces.firstIndex { $0.id == "other" })
    let cell = try #require(descendants(f.sidebar).compactMap { $0 as? SpaceDockButton }.first { $0.spaceID == "other" })
    let menu = try #require(cell.menuProvider?())
    var settings: String?
    f.sidebar.onSpaceSettings = { settings = $0 }
    try invoke(menu, "Space Settings…")
    #expect(settings == "other")
    var saved: (String, String)?
    f.sidebar.onRenameSpace = { id, name, done in saved = (id, name); done(true) }
    try invoke(menu, "Rename Space…")
    #expect(f.sidebar.spaceShown == index)
    let field = try #require(descendants(f.sidebar).compactMap { $0 as? SidebarRenameField }.first)
    f.sidebar.showSpaceWithoutNotification(at: index)
    #expect(descendants(f.sidebar).contains { $0 === field })
    field.stringValue = "Renamed other"
    field.finish(commit: true)
    #expect(saved?.0 == "other" && saved?.1 == "Renamed other")
    try invoke(menu, "Rename Space…")
    let nextField = try #require(descendants(f.sidebar).compactMap { $0 as? SidebarRenameField }.first)
    nextField.stringValue = "Saved on switch"
    let previous = try #require(f.snapshot.spaces.firstIndex { $0.id == "space-work" })
    f.sidebar.showSpaceWithoutNotification(at: previous)
    #expect(saved?.0 == "other" && saved?.1 == "Saved on switch")
    #expect(!descendants(f.sidebar).contains { $0 === nextField })
}
