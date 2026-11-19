import AppKit
@testable import AraratKit
import AraratUI
import AraratEngineAPI
import ObjectiveC.runtime
import Testing
@testable import Ararat

// U27b: `installCoreMenu` builds the Ararat Commands menu from `Runtime.coreMenuCommandIDs`.
// A table command that is missing from the list keeps its Shortcuts row and the command bar's row
// but has no menu item, so a recorded key would never fire. Reading the list here is the only way
// to assert the menu without launching the app.
@Test @MainActor
func theAraratCommandsMenuCarriesClearCacheAndClearCookiesUnbound() throws {
    let table = defaultKeyBindings()
    for (id, title) in [("clear_cache_site", "Clear Cache"), ("clear_cookies_site", "Clear Cookies")] {
        #expect(Runtime.coreMenuCommandIDs.contains(id))
        let row = try #require(table.first { $0.command == id })
        #expect(row.title == title)
        #expect(row.key == nil && row.defaultKey == nil)
        #expect(row.customized == false)
    }
    // Every id the menu installs resolves to a table command, so no item is added half-built.
    for id in Runtime.coreMenuCommandIDs {
        #expect(table.contains { $0.command == id }, "\(id)")
    }
}

// The smallest host that survives the dispatcher's prologue: it answers the two closing
// questions and records what it was asked to run.
@MainActor private final class SiteCommandHost: NSObject {
    var commands: [String] = []
    @objc(isClosing) func isClosing() -> Bool { false }
    @objc(isClosingAll) func isClosingAll() -> Bool { false }
    @objc(runCommand:) func runCommand(_ command: String) -> Bool { commands.append(command); return true }
}

// P5d: Add Split View's menu item. The key, the command-bar row and the row menu item all end in
// the same dispatcher; this pins the menu's enabled state, the one claim the other two surfaces
// cannot make (the command bar has no disabled rows, and a row menu only opens on a row).
@MainActor private final class AddSplitViewHost: NSObject {
    let value = AddSplitViewKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
    @objc(window) func window() -> NSWindow { value }
}

@MainActor private final class AddSplitViewKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@Test @MainActor
func addSplitViewMenuNeedsASelectedTodayOrPinnedTab() throws {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let windowID = "add-split-view-menu"
    let runtime = Runtime(windowID: windowID)
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: windowID, card: NSView(), session: session)
    runtime.adapter = engine
    defer { engine.shutdown() }
    class_addProtocol(AddSplitViewHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = AddSplitViewHost()
    runtime.host = host as? any ARWindowHostAPI
    let item = NSMenuItem(title: "Add Split View", action: #selector(Runtime.coreMenuCommand(_:)), keyEquivalent: "")
    item.representedObject = "add_split_view"
    let store = try session.queue.sync { try #require(session.store) }
    let space = try #require(session.queue.sync { store.snapshot(windowId: windowID).spaces.first })
    #expect(!runtime.validateMenuItem(item))
    let today = try session.queue.sync {
        try #require(store.createTab(windowId: windowID, url: "https://today.test").selectedId)
    }
    #expect(runtime.validateMenuItem(item) && runtime.addSplitViewTarget == today)
    let pinned = try session.queue.sync {
        let id = try #require(store.createTab(windowId: windowID, url: "https://pinned.test").selectedId)
        _ = try store.moveItem(windowId: windowID, id: id, container: space.pinnedId, index: 0, openFolder: false)
        return id
    }
    #expect(runtime.validateMenuItem(item) && runtime.addSplitViewTarget == pinned)
    let split = try session.queue.sync { try store.addSplitPane(windowId: windowID, itemId: today, side: .right) }
    let member = try session.queue.sync { try store.selectItem(windowId: windowID, id: split.pane) }
    #expect(runtime.validateMenuItem(item) && runtime.addSplitViewTarget == split.pane)
    let sidebar = SidebarView(snapshot: member)
    runtime.sidebar = sidebar
    sidebar.setLibraryOpen(true)
    #expect(!runtime.validateMenuItem(item))
    sidebar.setLibraryOpen(false)
    #expect(runtime.validateMenuItem(item))
    try session.queue.sync {
        _ = try store.ensureFavorites(windowId: windowID, spaceId: space.id, containerId: "favorites")
        _ = try store.moveItem(windowId: windowID, id: pinned, container: "favorites", index: 0, openFolder: false)
        _ = try store.selectItem(windowId: windowID, id: pinned)
    }
    #expect(!runtime.validateMenuItem(item))
}

@Test @MainActor
func theDispatcherRunsBothSiteCommandsThroughTheHost() {
    // U27b: one dispatcher. The header … menu's ids, the Ararat Commands menu's items, the
    // command bar's rows and a recorded key all end in `performWorkspaceCommand`, and it hands
    // the same id to the engine's `runCommand`. The engine's own clear path is the header
    // check's `clear` and its `checkSiteClearResults`, so no new VM condition is needed here.
    _ = NSApplication.shared
    let runtime = Runtime(windowID: "core-menu-dispatch")
    class_addProtocol(SiteCommandHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = SiteCommandHost()
    runtime.host = host as? any ARWindowHostAPI
    runtime.performWorkspaceCommand("clear_cache_site")
    runtime.performWorkspaceCommand("clear_cookies_site")
    #expect(host.commands == ["clear_cache_site", "clear_cookies_site"])
}

@Test @MainActor
func archiveActionsNeedANonemptyRegularArchive() throws {
    let runtime = Runtime(windowID: "archive-actions")
    #expect(!Runtime.archiveActionsEnabled(nil))
    #expect(!Runtime.archiveActionsEnabled(runtime))
    runtime.snapshot = WorkspaceSnapshot(archive: [ArchiveEntry(id: "closed", title: "Closed", url: "https://closed.test", lifecycleChangedAt: 1)], shownSpaceId: nil, selectedId: nil, spaces: [])
    #expect(Runtime.archiveActionsEnabled(runtime))
    runtime.isPrivateWindow = true
    #expect(!Runtime.archiveActionsEnabled(runtime))
    let binding = try #require(defaultKeyBindings().first { $0.command == "reopen_closed_tab" })
    #expect(binding.key == KeyCombination(key: "t", command: true, control: false, option: false, shift: true))
    #expect(Runtime.coreMenuCommandIDs.contains("clear_archive"))
}

@Test @MainActor
func settingsRebindingUpdatesTheInstalledAppMenu() async throws {
    _ = NSApplication.shared
    let originalMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = originalMenu }
    let menu = NSMenu()
    let appMenu = NSMenu()
    menu.addItem(withTitle: "Ararat", action: nil, keyEquivalent: "").submenu = appMenu
    let item = appMenu.addItem(withTitle: "Settings…", action: NSSelectorFromString("showPreferences:"), keyEquivalent: ",")
    NSApp.mainMenu = menu

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = Runtime(windowID: "settings-binding")
    let session = WorkspaceSession()
    try session.queue.sync { session.store = try WorkspaceStore.open(path: directory.appendingPathComponent("db").path) }
    let bindings = KeyBindingsModel(adapter: WorkspaceAdapter(windowID: runtime.windowID, session: session))
    runtime.keyBindings = bindings

    let firstKey = KeyCombination(key: "s", command: true, control: false, option: false, shift: false)
    try await withCheckedThrowingContinuation { continuation in
        bindings.set(command: "settings", key: firstKey) { continuation.resume(with: $0) }
    }
    runtime.installCoreMenu()
    #expect(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.command])

    let key = KeyCombination(key: "y", command: false, control: true, option: false, shift: false)
    try await withCheckedThrowingContinuation { continuation in
        bindings.set(command: "settings", key: key) { continuation.resume(with: $0) }
    }
    #expect(item.keyEquivalent == "y")
    #expect(item.keyEquivalentModifierMask == [.control])
}

@Test @MainActor
func chromiumNewTabMenuFollowsTheCoreBinding() async throws {
    _ = NSApplication.shared
    let originalMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = originalMenu }
    let menu = NSMenu()
    let file = NSMenu(title: "File")
    menu.addItem(withTitle: "Ararat", action: nil, keyEquivalent: "").submenu = NSMenu()
    menu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
    let newTab = file.addItem(withTitle: "New Tab", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "t")
    newTab.tag = 34014
    NSApp.mainMenu = menu

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = Runtime(windowID: "alias-binding")
    let session = WorkspaceSession()
    let store = try WorkspaceStore.open(path: directory.appendingPathComponent("db").path)
    let cmdJ = KeyCombination(key: "j", command: true, control: false, option: false, shift: false)
    let cmdT = KeyCombination(key: "t", command: true, control: false, option: false, shift: false)
    try session.queue.sync {
        _ = try store.setKeyBinding(command: "new_tab", key: cmdJ)
        session.store = store
    }
    let bindings = KeyBindingsModel(adapter: WorkspaceAdapter(windowID: runtime.windowID, session: session))
    runtime.keyBindings = bindings
    try await withCheckedThrowingContinuation { continuation in
        bindings.load { continuation.resume(with: $0) }
    }
    runtime.installCoreMenu()
    let toggleSidebar = try #require(menu.item(withTitle: "Ararat Commands")?.submenu?.item(withTitle: "Toggle Sidebar"))
    #expect(bindings.binding(command: "new_tab")?.key == cmdJ)
    #expect(newTab.keyEquivalent == "j")
    #expect(newTab.keyEquivalentModifierMask == [.command])

    try await withCheckedThrowingContinuation { continuation in
        bindings.reset(command: "new_tab") { continuation.resume(with: $0) }
    }
    #expect(newTab.keyEquivalent == "t" && newTab.keyEquivalentModifierMask == [.command])
    try await withCheckedThrowingContinuation { continuation in
        bindings.set(command: "toggle_sidebar", key: cmdT) { continuation.resume(with: $0) }
    }
    #expect(bindings.binding(command: "toggle_sidebar")?.key == cmdT)
    #expect(newTab.keyEquivalent == "")
    #expect(newTab.keyEquivalentModifierMask.isEmpty)
    #expect(toggleSidebar.keyEquivalent == "t")
    #expect(toggleSidebar.keyEquivalentModifierMask == [.command])

    try await withCheckedThrowingContinuation { continuation in
        bindings.set(command: "new_tab", key: cmdJ) { continuation.resume(with: $0) }
    }
    #expect(newTab.keyEquivalent == "j" && newTab.keyEquivalentModifierMask == [.command])
    #expect(toggleSidebar.keyEquivalent == "t" && toggleSidebar.keyEquivalentModifierMask == [.command])

    try await withCheckedThrowingContinuation { continuation in
        bindings.resetAll { continuation.resume(with: $0) }
    }
    #expect(newTab.keyEquivalent == "t" && newTab.keyEquivalentModifierMask == [.command])
    #expect(toggleSidebar.keyEquivalent == "s" && toggleSidebar.keyEquivalentModifierMask == [.command])
    #expect(newTab.action == NSSelectorFromString("commandDispatch:"))
}

@Test @MainActor
func chromiumCloseShortcutFollowsTheActiveCloseMenuItem() throws {
    let file = NSMenu(title: "File")
    let closeWindowAction = NSSelectorFromString("performClose:")
    let closeTabAction = NSSelectorFromString("commandDispatch:")
    let secondary = file.addItem(withTitle: "", action: nil, keyEquivalent: "W")
    secondary.tag = 0
    secondary.isHidden = true
    let primary = file.addItem(withTitle: "Close Window", action: closeWindowAction, keyEquivalent: "w")
    primary.tag = 34012
    primary.identifier = NSUserInterfaceItemIdentifier("close_tab")

    var binding = try #require(defaultKeyBindings().first { $0.command == "close_tab" })
    KeyBindingsModel.apply([binding], to: file)
    #expect(primary.keyEquivalent == "w" && primary.keyEquivalentModifierMask == [.command])
    #expect(primary.action == closeWindowAction)

    binding.key = KeyCombination(key: "j", command: true, control: false, option: false, shift: false)
    KeyBindingsModel.apply([binding], to: file)
    #expect(primary.keyEquivalent == "j" && primary.keyEquivalentModifierMask == [.command])
    #expect(primary.action == closeWindowAction)

    // Chromium changes the menu items' roles when a tabbed window becomes active.
    primary.title = "Close Tab"
    primary.tag = 34015
    primary.action = closeTabAction
    secondary.title = "Close Window"
    secondary.tag = 34012
    secondary.action = closeWindowAction
    secondary.isHidden = false
    KeyBindingsModel.apply([binding], to: file)
    #expect(primary.keyEquivalent == "j" && primary.keyEquivalentModifierMask == [.command])
    #expect(primary.action == closeTabAction)
    #expect(secondary.keyEquivalent == "W" && secondary.keyEquivalentModifierMask == [.command])

    binding.key = binding.defaultKey
    KeyBindingsModel.apply([binding], to: file)
    #expect(primary.keyEquivalent == "w" && primary.keyEquivalentModifierMask == [.command])

    binding.key = nil
    KeyBindingsModel.apply([binding], to: file)
    #expect(primary.keyEquivalent.isEmpty)
    #expect(secondary.keyEquivalent == "W" && secondary.keyEquivalentModifierMask == [.command])
}

@Test @MainActor
func installingArchiveMenuKeepsEveryHistoryTagKnownToChromium() throws {
    _ = NSApplication.shared
    let originalMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = originalMenu }
    // Why not tag 0: Chromium 9a31f0acec1854d44e49a73fbf8017598151a583's
    // chrome/browser/ui/cocoa/history_menu_bridge.mm:725–745 accepts only these tags;
    // history_menu_bridge.h:123–131 and chrome/app/chrome_command_ids.h define their values.
    let handledTags: Set<Int> = [33003, 33000, 33001, 400, 401, 440, 441, 480, 40010]
    let menu = NSMenu(title: "Main")
    for title in ["File", "History", "Tab"] {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = NSMenu(title: title)
    }
    let file = try #require(menu.item(withTitle: "File")?.submenu)
    let chromiumReopen = file.addItem(withTitle: "Reopen Closed Tab", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "t")
    chromiumReopen.tag = 34028
    chromiumReopen.keyEquivalentModifierMask = [.command, .shift]
    let history = try #require(menu.item(withTitle: "History")?.submenu)
    for tag in handledTags.sorted() {
        history.addItem(withTitle: "History \(tag)", action: nil, keyEquivalent: "").tag = tag
    }
    NSApp.mainMenu = menu
    let runtime = Runtime(windowID: "archive-menu")
    class_addProtocol(AddSplitViewHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = AddSplitViewHost()
    runtime.host = host as? any ARWindowHostAPI
    runtime.installCoreMenu()
    #expect(history.items.count == handledTags.count)
    for item in history.items {
        #expect(handledTags.contains(item.tag), "Unknown History tag: \(item.tag) (\(item.title))")
    }
    let reopen = try #require(file.items.first { $0.representedObject as? String == "reopen_closed_tab" })
    #expect(reopen === chromiumReopen)
    #expect(reopen.title == "Reopen Closed Tab")
    #expect(reopen.target === runtime)
    #expect(reopen.action == #selector(Runtime.coreMenuCommand(_:)))
    #expect(reopen.keyEquivalent == "T")
    #expect(reopen.keyEquivalentModifierMask == [.command])
    let shortcuts = menu.items.compactMap(\.submenu).flatMap(\.items).filter {
        ($0.keyEquivalent == "T" && $0.keyEquivalentModifierMask == [.command]) ||
        ($0.keyEquivalent == "t" && $0.keyEquivalentModifierMask == [.command, .shift])
    }
    #expect(shortcuts.count == 1)
    #expect(shortcuts.first === reopen)
    #expect(!runtime.validateMenuItem(reopen))
    runtime.snapshot = WorkspaceSnapshot(archive: [ArchiveEntry(id: "closed", title: "Closed", url: "https://closed.test", lifecycleChangedAt: 1)], shownSpaceId: nil, selectedId: nil, spaces: [])
    #expect(runtime.validateMenuItem(reopen))
    runtime.isPrivateWindow = true
    #expect(!Runtime.archiveActionsEnabled(runtime))
}
