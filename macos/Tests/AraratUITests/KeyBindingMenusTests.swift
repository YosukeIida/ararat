import AppKit
import AraratKit
import Testing
@testable import AraratUI
@testable import AraratHarness

@MainActor
private func bindingValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private func commandItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(commandItems) ?? []) }
}

@MainActor
private func bindingDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(bindingDescendants) }

private func bindingFlags(_ key: KeyCombination?) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if key?.command == true { flags.insert(.command) }
    if key?.control == true { flags.insert(.control) }
    if key?.option == true { flags.insert(.option) }
    if key?.shift == true { flags.insert(.shift) }
    return flags
}

@MainActor
private func routingEvent(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers, isARepeat: false, keyCode: keyCode))
}

@MainActor
private final class ShortcutTarget: NSObject {
    var calls = 0
    @objc func toggle(_ sender: Any?) { calls += 1 }
}

@Test @MainActor
func shiftedCoreMenuShortcutMatchesTheNativeKeyEvent() throws {
    _ = NSApplication.shared
    let target = ShortcutTarget()
    let menu = NSMenu()
    let item = menu.addItem(withTitle: "Toggle Library", action: #selector(ShortcutTarget.toggle(_:)), keyEquivalent: "")
    item.target = target
    let key = try #require(defaultKeyBindings().first { $0.command == "toggle_library" }?.key)
    KeyBindingsModel.setCoreMenuShortcut(key, on: item)
    let event = try routingEvent(keyCode: 37, characters: "l", charactersIgnoringModifiers: "L", flags: [.command, .shift])
    #expect(menu.performKeyEquivalent(with: event))
    #expect(target.calls == 1)
    let unshifted = try routingEvent(keyCode: 37, characters: "l", charactersIgnoringModifiers: "l", flags: [.command])
    #expect(!menu.performKeyEquivalent(with: unshifted))
    #expect(target.calls == 1)
}

@MainActor
private func openBindings(_ directory: URL) async throws -> (WorkspaceAdapter, WorkspaceSnapshot) {
    let adapter = WorkspaceAdapter(windowID: "bindings")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let snapshot = try await bindingValue {
        adapter.open(path: directory.appendingPathComponent("keys.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    return (adapter, snapshot)
}

@Test @MainActor
func everyMenuShortcutComesFromTheCoreIncludingPinAndFavoriteClose() throws {
    _ = NSApplication.shared
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "binding-defaults"))
    let menu = harness.makeMenu()
    let items = commandItems(menu)
    let defaults = defaultKeyBindings()
    #expect(items.filter { $0.identifier != nil }.count == defaults.count)
    #expect(items.filter { !$0.keyEquivalent.isEmpty }.allSatisfy { $0.identifier != nil })
    for row in defaults {
        let item = try #require(items.first { $0.identifier?.rawValue == row.command })
        #expect(item.keyEquivalent == row.key?.key ?? "")
        #expect(item.keyEquivalentModifierMask == bindingFlags(row.key))
    }
    let pin = try #require(items.first { $0.identifier?.rawValue == "pin_tab" })
    #expect(pin.menu?.title == "Tabs" && pin.keyEquivalent == "d")
    #expect(pin.action == #selector(HarnessDelegate.pinSelectedTab(_:)))
    let row = Row(folderHasTabs: false, parentId: "fav", siblingIndex: 0, collapsed: false, id: "favorite", title: "Favorite", url: "https://example.test", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let favorite = sidebar.favoriteMenu(row: row)
    let close = try #require(favorite.items.first { $0.title == "Close Tab" })
    #expect(close.keyEquivalent == "w" && close.keyEquivalentModifierMask == [.command])
    #expect(!sidebar.pinnedMenu(row: row).items.contains { $0.title == "Pin Tab" || $0.title == "Unpin Tab" })
}

@Test @MainActor
func overridingClearingAndResettingUpdateExistingMenusAndSettingsImmediately() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openBindings(directory)
    let harness = HarnessDelegate(adapter: adapter)
    harness.snapshot = snapshot
    harness.sidebar = SidebarView(snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    let menu = harness.makeMenu()
    let close = try #require(commandItems(menu).first { $0.identifier?.rawValue == "close_tab" })
    let favorite = try #require(snapshot.spaces.first?.favorites.first)
    let rowMenu = try #require(harness.sidebar).favoriteMenu(row: favorite)
    let rowClose = try #require(rowMenu.items.first { $0.title == "Close Tab" })
    let settings = harness.prepareSettings()
    settings.model.readShortcuts()
    let key = KeyCombination(key: "x", command: false, control: true, option: true, shift: true)
    try await bindingValue { harness.keyBindings.set(command: "close_tab", key: key, completion: $0) }
    for item in [close, rowClose] {
        #expect(item.keyEquivalent == "x")
        #expect(item.keyEquivalentModifierMask == [.control, .option, .shift])
    }
    #expect(settings.model.shortcuts.contains { $0.title == "Close Tab" && $0.keys == ["⌃", "⌥", "⇧", "X"] })
    #expect(SidebarTooltip.keycaps(for: close).last?.stringValue == "X")
    try await bindingValue { harness.keyBindings.set(command: "close_tab", key: nil, completion: $0) }
    #expect(close.keyEquivalent.isEmpty && rowClose.keyEquivalent.isEmpty)
    try await bindingValue { harness.keyBindings.reset(command: "close_tab", completion: $0) }
    #expect(close.keyEquivalent == "w" && rowClose.keyEquivalent == "w")
    try await bindingValue { harness.keyBindings.set(command: "close_tab", key: key, completion: $0) }
    try await bindingValue { harness.keyBindings.set(command: "show_space_1", key: KeyCombination(key: "g", command: false, control: false, option: true, shift: false), completion: $0) }
    #expect(settings.model.spaceKeys[0] == ["⌥", "G"])
    try await bindingValue { harness.keyBindings.resetAll(completion: $0) }
    #expect(harness.keyBindings.bindings == defaultKeyBindings())
    #expect(close.keyEquivalent == "w" && rowClose.keyEquivalent == "w")
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func pinCommandMovesTodayTabShowsTimedHintAndUnpinsWithoutHint() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, _) = try await openBindings(directory)
    var snapshot = try await bindingValue { adapter.select(id: "tab-a", completion: $0) }
    let space = snapshot.spaces[0]
    snapshot = try await bindingValue { adapter.move(id: "tab-a", container: space.todayId, index: 0, openFolder: false, completion: $0) }
    let harness = HarnessDelegate(adapter: adapter)
    harness.snapshot = snapshot
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.frame = .init(x: 0, y: 0, width: 260, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    var now: CFTimeInterval = 100
    sidebar.renameHintClock = { now }
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    harness.window = window
    harness.sidebar = sidebar
    var moves = 0
    sidebar.onMove = { id, container, index, open, done in
        moves += 1
        adapter.move(id: id, container: container, index: index, openFolder: open) { result in
            do { done(try result.get()) } catch { Issue.record("pin move failed: \(error)"); done(nil) }
        }
    }
    let pin = try #require(commandItems(harness.makeMenu()).first { $0.identifier?.rawValue == "pin_tab" })
    #expect(pin.keyEquivalent == "d" && pin.keyEquivalentModifierMask == [.command])
    harness.pinTab(in: window)
    try await waitUntil { bindingDescendants(sidebar).compactMap { $0 as? SidebarRowView }.contains { $0.row.id == "tab-a" && $0.pinned } }
    let row = try #require(bindingDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "tab-a" })
    let hint = try #require(bindingDescendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Double-click to rename" })
    #expect(!hint.isHidden && hint.alphaValue == 1)
    now = 103.1
    row.refreshRenameHint()
    #expect(hint.alphaValue < 1)
    now = 103.3
    row.refreshRenameHint()
    #expect(hint.isHidden)
    #expect(sidebar.selectedTabIsPinned)
    _ = harness.validateMenuItem(pin)
    #expect(pin.title == "Unpin Tab")
    harness.pinTab(in: window)
    try await waitUntil { !sidebar.selectedTabIsPinned }
    #expect(moves == 2 && hint.isHidden)
    let result = try await bindingValue { adapter.snapshot(completion: $0) }
    #expect(result.spaces[0].today.contains { $0.id == "tab-a" })
    #expect(!window.isVisible)
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func nativeTextFieldsAndCreationProtectPageCommandsWithoutChangingFocus() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, _) = try await openBindings(directory)
    var snapshot = try await bindingValue { adapter.select(id: "tab-a", completion: $0) }
    let todayID = snapshot.spaces[0].todayId
    snapshot = try await bindingValue { adapter.move(id: "tab-a", container: todayID, index: 0, openFolder: false, completion: $0) }
    #expect(!WorkspaceCommands.allowsPageCommand(NSTextField()))
    #expect(!WorkspaceCommands.allowsPageCommand(NSSearchField()))
    #expect(!WorkspaceCommands.allowsPageCommand(NSTextView()))
    #expect(WorkspaceCommands.allowsPageCommand(NSView()))
    let sidebar = SidebarView(snapshot: snapshot)
    #expect(sidebar.pageCommandsAllowed && sidebar.canPinSelectedTab)
    sidebar.setCreateSpaceOpen(true)
    #expect(!sidebar.pageCommandsAllowed)
    var closes = 0
    var moves = 0
    sidebar.onCloseSelected = { closes += 1 }
    sidebar.onMove = { _, _, _, _, done in moves += 1; done(nil) }
    sidebar.closeSelectedTab(nil)
    sidebar.pinSelectedTab(nil)
    #expect(closes == 0 && moves == 0)
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func loadedOverridesReplaceDefaultsBeforeUseAndErrorsKeepMenuKeys() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, _) = try await openBindings(directory)
    let original = KeyBindingsModel(adapter: adapter)
    let key = KeyCombination(key: "j", command: true, control: false, option: false, shift: true)
    try await bindingValue { original.set(command: "pin_tab", key: key, completion: $0) }
    let loaded = KeyBindingsModel(adapter: adapter)
    let menu = NSMenu()
    let item = menu.addItem(withTitle: "Pin Tab", action: nil, keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("pin_tab")
    loaded.register(menu)
    #expect(item.keyEquivalent == "d")
    try await bindingValue { loaded.load(completion: $0) }
    #expect(item.keyEquivalent == "j" && item.keyEquivalentModifierMask == [.command, .shift])
    do {
        try await bindingValue { loaded.set(command: "pin_tab", key: KeyCombination(key: "q", command: true, control: false, option: false, shift: false), completion: $0) }
        Issue.record("reserved key was accepted")
    } catch {
        #expect(loaded.error == "this shortcut is reserved by the system")
        #expect(item.keyEquivalent == "j")
    }
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func rebindingsWithoutCommandYieldToOurOwnTextFields() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openBindings(directory)
    let harness = HarnessDelegate(adapter: adapter)
    harness.snapshot = snapshot
    var closes = 0
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.onCloseSelected = { closes += 1 }
    harness.sidebar = sidebar
    let menu = harness.makeMenu()
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    let close = try #require(commandItems(menu).first { $0.identifier?.rawValue == "close_tab" })
    try await bindingValue { harness.keyBindings.set(command: "close_tab", key: KeyCombination(key: "w", command: false, control: false, option: true, shift: false), completion: $0) }
    #expect(close.keyEquivalent == "w" && close.keyEquivalentModifierMask == [.option])

    // The window pass: a rebinding without Command must not reach the menu while one of our own
    // text fields has keyboard focus. AppKit's menu pass claims the matching equivalent even for
    // a disabled item, so the windows claim it here and hand the key to the field.
    let browser = BrowserWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
    browser.isReleasedWhenClosed = false
    browser.contentView = sidebar
    sidebar.frame = browser.contentView!.bounds
    browser.delegate = harness
    harness.window = browser
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    browser.contentView?.addSubview(field)
    browser.makeFirstResponder(field)
    let optionW = try routingEvent(keyCode: 13, characters: "∞", charactersIgnoringModifiers: "w", flags: [.option])
    #expect(browser.performKeyEquivalent(with: optionW))
    #expect((browser.firstResponder as? NSTextView)?.string == "∞")
    #expect(closes == 0)
    // A Command key is never claimed by the field routing: it stays available for the menus.
    #expect(!browser.performKeyEquivalent(with: try routingEvent(keyCode: 2, characters: "d", charactersIgnoringModifiers: "d", flags: [.command])))

    // Rename in progress: the field is an NSTextField subclass of ours, so the routing yields as well.
    let row = try #require(bindingDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.kind == .tab })
    sidebar.beginRename(id: row.row.id)
    let renameField = try #require(row.renameField)
    // beginRename already made the field (its editor) first responder.
    try await waitUntil { browser.firstResponder is NSTextView }
    #expect(browser.performKeyEquivalent(with: optionW))
    #expect((browser.firstResponder as? NSTextView)?.string.contains("∞") == true)
    #expect(closes == 0)
    renameField.finish(commit: false)

    // The settings search field is reached through SettingsWindow's own routing.
    let settings = harness.prepareSettings()
    let settingsWindow = try #require(settings.window as? SettingsWindow)
    let searchField = NSTextView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
    settingsWindow.contentView?.addSubview(searchField)
    settingsWindow.makeFirstResponder(searchField)
    try await bindingValue { harness.keyBindings.set(command: "toggle_sidebar", key: KeyCombination(key: "s", command: false, control: false, option: true, shift: false), completion: $0) }
    #expect(settingsWindow.performKeyEquivalent(with: try routingEvent(keyCode: 1, characters: "ß", charactersIgnoringModifiers: "s", flags: [.option])))
    #expect(searchField.string == "ß")
    settingsWindow.contentViewController = nil
    browser.contentView = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}
