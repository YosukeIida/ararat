import AppKit
import AraratKit
import SwiftUI
import Testing
@testable import AraratUI
@testable import AraratHarness

@MainActor
private func settingsValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { done in start { done.resume(with: $0) } }
}

@Test @MainActor
func settingsWindowNavigationSearchAndSlidesKeepTheSidebarSpace() throws {
    _ = NSApplication.shared
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "a", selectedId: nil, spaces: ["a", "b"].map {
        SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: $0, title: $0.uppercased(), icon: nil, look: nil, favorites: [], pinned: [], today: [])
    })
    let model = SettingsModel(snapshot: snapshot, adapter: WorkspaceAdapter(windowID: "settings"), publish: { _ in }, resetWidth: {})
    let sidebar = SidebarView(snapshot: snapshot)
    sidebar.showSpace(at: 1)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    controller.prepare(shownSpaceID: "a")
    #expect(model.page == .space("a"))
    #expect(!window.isVisible)
    #expect(window.frame.size == NSSize(width: 760, height: 540))
    #expect(window.contentViewController is NSSplitViewController)
    controller.prepare(shownSpaceID: "b")
    #expect(controller.window === window && model.page == .space("b"))
    model.slide(-1)
    #expect(model.page == .space("a") && sidebar.spaceShown == 1)
    model.query = "default width"
    let result = try #require(model.results.first)
    #expect(result.id == "width")
    model.select(result)
    #expect(model.page == .tabs && model.highlighted == "width")
    model.navigate(.spaces)
    #expect(model.highlighted == nil)
    model.go(-1)
    #expect(model.page == .tabs)
    model.requestDelete("a")
    #expect(model.pendingDelete == "a")
    model.pendingDelete = nil
    #expect(model.snapshot.spaces.count == 2)
    model.snapshot.spaces.removeLast()
    model.requestDelete("a")
    #expect(model.pendingDelete == nil)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(!window.isVisible)
    window.contentViewController = nil
}

@Test @MainActor
func settingsEditsPublishCoreSnapshotsAndValidateOneGrapheme() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = WorkspaceAdapter(windowID: "settings")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    var snapshot = try await settingsValue { adapter.open(path: directory.appendingPathComponent("settings.sqlite").path, json: { json }, completion: $0) }
    if snapshot.spaces.count < 2 { snapshot = try await settingsValue { adapter.createSpace(name: "Second", completion: $0) } }
    let sidebar = SidebarView(snapshot: snapshot)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { sidebar.applySelection(snapshot: $0) }, resetWidth: {})
    let id = try #require(snapshot.spaces.first?.id)
    model.rename(id, name: "Renamed")
    try await waitUntil { model.snapshot.spaces.first?.title == "Renamed" }
    model.rename(id, name: "  ")
    #expect(model.error == "Enter a space name.")
    let iconHost = NSHostingView(rootView: SettingsField(value: model.snapshot.spaces.first?.icon ?? "", label: "Space icon", characterPalette: true) { model.icon(id, value: $0) })
    let iconWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    iconWindow.isReleasedWhenClosed = false
    iconWindow.contentView = iconHost
    try await waitUntil { iconHost.layoutSubtreeIfNeeded(); return settingsDescendants(iconHost).contains { $0 is NSTextField } }
    let iconField = try #require(settingsDescendants(iconHost).compactMap { $0 as? NSTextField }.first)
    iconField.stringValue = "🔬😀"
    iconField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: iconField))
    try await waitUntil { model.snapshot.spaces.first?.icon == "😀" }
    iconWindow.close()
    #expect(!iconWindow.isVisible)
    let iconDock = try #require(settingsDescendants(sidebar).compactMap { $0 as? SpaceDockView }.first)
    #expect((iconDock.subviews.first as? NSButton)?.title == "😀")
    iconWindow.contentView = nil
    #expect(model.tabCount(model.snapshot.spaces[0]) == model.snapshot.spaces[0].today.filter { $0.kind == .tab || $0.kind == .split }.count)
    model.icon(id, value: "👨‍👩‍👧‍👦")
    try await waitUntil { model.snapshot.spaces.first?.icon == "👨‍👩‍👧‍👦" }
    model.icon(id, value: "ab")
    #expect(model.error == "Choose exactly one character.")
    #expect(model.snapshot.spaces.first?.icon == "👨‍👩‍👧‍👦")
    model.move(id, to: snapshot.spaces.count - 1)
    try await waitUntil { model.snapshot.spaces.last?.id == id }
    #expect(sidebar.spaceShown == model.snapshot.spaces.count - 1)
    let dock = try #require(settingsDescendants(sidebar).first { $0 is SpaceDockView })
    #expect((dock.subviews.last as? NSButton)?.accessibilityLabel() == "Renamed")
    model.move(id, to: -1)
    model.move(id, to: model.snapshot.spaces.count)
    #expect(model.snapshot.spaces.last?.id == id)
    model.requestDelete(id)
    model.pendingDelete = nil
    #expect(model.snapshot.spaces.contains { $0.id == id })
    model.requestDelete(id)
    model.confirmDelete()
    try await waitUntil { !model.snapshot.spaces.contains { $0.id == id } }
    #expect(model.snapshot.spaces[sidebar.spaceShown].id == model.snapshot.shownSpaceId)
    _ = try await settingsValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func settingsShortcutsComeFromMenuItems() {
    let menu = NSMenu()
    let file = NSMenu()
    file.addItem(withTitle: "Close Tab", action: nil, keyEquivalent: "w")
    menu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []), adapter: WorkspaceAdapter(windowID: "test"), publish: { _ in }, resetWidth: {})
    model.readShortcuts(menu)
    #expect(model.shortcuts.map(\.title) == ["Close Tab"])
    #expect(model.shortcuts.first?.keys == ["⌘", "W"])
    file.items[0].keyEquivalent = "x"
    model.readShortcuts(menu)
    #expect(model.shortcuts.first?.keys == ["⌘", "X"])
    file.items[0].keyEquivalent = "X"
    model.readShortcuts(menu)
    #expect(model.shortcuts.first?.keys == ["⇧", "⌘", "X"])
    file.items[0].keyEquivalent = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    model.readShortcuts(menu)
    #expect(model.shortcuts.first?.keys == ["⌘", "←"])
}

@MainActor
private func settingsDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + settingsDescendants($0) }
}

@Test @MainActor
func settingsSearchScrollsTheHostingViewToItsHighlightedRow() async throws {
    _ = NSApplication.shared
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []), adapter: WorkspaceAdapter(windowID: "search"), publish: { _ in }, resetWidth: {})
    model.shortcuts = (0..<30).map { SettingsModel.Row(id: "key-\($0)", pane: .shortcuts, title: "Action \($0)", subtitle: "Perform action \($0)") }
    model.navigate(.tabs)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    let split = try #require(window.contentViewController as? NSSplitViewController)
    let content = split.splitViewItems[1].viewController.view
    defer { window.contentViewController = nil }
    window.contentView?.layoutSubtreeIfNeeded()
    try await waitUntil { content.layoutSubtreeIfNeeded(); return settingsDescendants(content).contains { $0 is NSScrollView } }
    let scroll = try #require(settingsDescendants(content).compactMap { $0 as? NSScrollView }.first)
    model.query = "Perform action 29"
    model.select(try #require(model.results.first))
    try await waitUntil { content.layoutSubtreeIfNeeded(); return scroll.contentView.bounds.minY > 500 }
    #expect(model.highlighted == "key-29")
    #expect(!window.isVisible)
    model.navigate(.tabs)
    #expect(model.highlighted == nil)
}

@Test @MainActor
func settingsHarnessMenusReuseLifetimeAndWindowCloseRouting() throws {
    _ = NSApplication.shared
    let spaces = (0..<10).map { SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "s\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: [], today: []) }
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "s0", selectedId: nil, spaces: spaces)
    var terminations = 0
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "harness-test"), terminate: { terminations += 1 })
    harness.snapshot = snapshot
    harness.sidebar = SidebarView(snapshot: snapshot)
    let browser = BrowserWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    browser.isReleasedWhenClosed = false
    harness.window = browser
    let menu = harness.makeMenu()
    let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
    let close = try #require(file.items.first)
    #expect(close.action == #selector(HarnessDelegate.closeSelectedTab(_:)))
    #expect(!harness.validateMenuItem(close))
    #expect(harness.canCloseTab(keyWindow: browser))
    let first = harness.prepareSettings()
    let settings = try #require(first.window)
    #expect(!harness.canCloseTab(keyWindow: settings))
    harness.sidebar?.showSpace(at: 1)
    let second = harness.prepareSettings()
    #expect(first === second && second.model.page == .space("s1"))
    #expect(!settings.isVisible && !browser.isVisible)
    let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
    let bindings = view.items.filter { $0.action == #selector(HarnessDelegate.showSpace(_:)) }
    #expect(bindings.count == 9)
    for (index, item) in bindings.enumerated() {
        #expect(item.keyEquivalent == String(index + 1) && item.keyEquivalentModifierMask == [.control])
        #expect(harness.validateMenuItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(harness.sidebar?.spaceShown == index)
    }
    second.model.readShortcuts(menu)
    #expect(second.model.spaceKeys[1] == ["⌃", "2"])
    #expect(second.model.spaceKeys[9] == nil)
    #expect(second.model.shortcuts.contains { $0.title == "Show Space 2" && $0.keys == ["⌃", "2"] })
    harness.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: settings))
    #expect(terminations == 0)
    harness.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: browser))
    #expect(terminations == 1)
    let closeObserver = SettingsCloseObserver()
    settings.delegate = closeObserver
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: settings.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    #expect(settings.performKeyEquivalent(with: event))
    #expect(closeObserver.closed)
    #expect(!settings.isVisible && terminations == 1)
    settings.contentViewController = nil
}

@MainActor
private final class SettingsCloseObserver: NSObject, NSWindowDelegate {
    var closed = false
    func windowWillClose(_ notification: Notification) { closed = true }
}

@Test @MainActor
func settingsErrorsSearchAndEdgeBounceUseTheirVisibleValues() {
    _ = NSApplication.shared
    let space = SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: nil, spaces: [space]), adapter: WorkspaceAdapter(windowID: "values"), publish: { _ in }, resetWidth: {})
    model.receive(.failure(CoreError.Edit(message: "unknown space missing-id")))
    #expect(model.error == "unknown space missing-id")
    model.navigate(.tabs)
    #expect(model.error == nil)
    model.query = "name"
    #expect(model.results.map(model.resultTitle) == ["Name — Work"])
    #expect(SettingsModel.iconDraft("🔬😀") == "😀")
    #expect(SettingsModel.iconDraft("👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦")
    #expect(SettingsModel.settingsOffset(100, index: 0) < 100)
    #expect(SettingsModel.settingsOffset(-100, index: 0) == -100)
    #expect(SettingsModel.settingsOffset(100, index: 1) == 100)
}
