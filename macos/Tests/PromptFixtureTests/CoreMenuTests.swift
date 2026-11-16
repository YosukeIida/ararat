import AppKit
import AraratKit
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
func addSplitViewMenuNeedsASelectedTodayOrPinnedTab() {
    _ = NSApplication.shared
    let runtime = Runtime(windowID: "add-split-view-menu")
    class_addProtocol(AddSplitViewHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = AddSplitViewHost()
    runtime.host = host as? any ARWindowHostAPI
    let item = NSMenuItem(title: "Add Split View", action: #selector(Runtime.coreMenuCommand(_:)), keyEquivalent: "")
    item.representedObject = "add_split_view"
    func row(_ id: String, parent: String, depth: UInt32 = 0, kind: RowKind = .tab) -> Row {
        Row(folderHasTabs: false, parentId: parent, siblingIndex: 0, collapsed: false, id: id, title: id,
            url: kind == .tab ? "https://\(id).test" : nil, depth: depth, kind: kind, unloaded: false, lastSelectedAt: nil)
    }
    func snapshot(selected: String?, pinned: [Row] = [], today: [Row] = [], favorites: [Row] = []) -> WorkspaceSnapshot {
        let space = SpaceSnapshot(pinnedCount: UInt32(pinned.count), todayCount: UInt32(today.count), profileKey: "default",
                                  pinnedId: "pin", todayId: "today", favoritesId: "fav", archiveAfter: .hours12,
                                  profileName: "Default", profile: .default, id: "work", title: "Work", icon: nil,
                                  look: nil, pinnedCollapsed: false, favorites: favorites, pinned: pinned, today: today)
        return WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: selected, spaces: [space])
    }
    // No selected tab — an empty space, or the Library shown — disables the item; its key then
    // reaches the same guard through performWorkspaceCommand and does nothing.
    runtime.snapshot = snapshot(selected: nil)
    #expect(!runtime.validateMenuItem(item))
    #expect(runtime.addSplitViewTarget == nil)
    // A Today tab and a pinned tab are the two rows the row menu offers it on.
    runtime.snapshot = snapshot(selected: "today-tab", today: [row("today-tab", parent: "today")])
    #expect(runtime.validateMenuItem(item) && runtime.addSplitViewTarget == "today-tab")
    runtime.snapshot = snapshot(selected: "pin-tab", pinned: [row("pin-tab", parent: "pin")])
    #expect(runtime.validateMenuItem(item) && runtime.addSplitViewTarget == "pin-tab")
    // A split adds beside its panes: the focused pane is the one the segment menu's Add Right
    // Split would take, and the split's first pane when the focus sits elsewhere.
    runtime.snapshot = snapshot(selected: "split", today: [row("split", parent: "today", kind: .split), row("member", parent: "split", depth: 1)])
    let sidebar = SidebarView(snapshot: runtime.snapshot)
    runtime.sidebar = sidebar
    sidebar.focusedPane = ("member", "https://member.test")
    #expect(runtime.validateMenuItem(item) && runtime.addSplitViewTarget == "member")
    sidebar.focusedPane = nil
    #expect(runtime.addSplitViewTarget == "member")
    // A folder has no page to split, a favourite row keeps no split item (the row menu), and the
    // Library covers the rows, so neither enables the command.
    runtime.snapshot = snapshot(selected: "folder", today: [row("folder", parent: "today", kind: .folder)])
    #expect(!runtime.validateMenuItem(item))
    runtime.snapshot = snapshot(selected: "fav", favorites: [row("fav", parent: "fav")])
    #expect(!runtime.validateMenuItem(item))
    runtime.snapshot = snapshot(selected: "today-tab", today: [row("today-tab", parent: "today")])
    sidebar.setLibraryOpen(true)
    #expect(!runtime.validateMenuItem(item))
    sidebar.setLibraryOpen(false)
    #expect(runtime.validateMenuItem(item))
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
