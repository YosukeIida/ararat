import AppKit
import AraratKit
import SwiftUI
import Testing
@testable import AraratUI
@testable import AraratHarness

@Test @MainActor
func settingsRetargetsOneWindowToTheNewWorkspace() {
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [])
    let first = WorkspaceAdapter(windowID: "settings-first")
    let second = WorkspaceAdapter(windowID: "settings-second")
    let model = SettingsModel(snapshot: snapshot, adapter: first, publish: { _ in }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: first), airTraffic: AirTrafficModel(adapter: first))
    let controller = SettingsWindowController(model: model)
    let window = controller.window
    var target = ""
    controller.retarget(snapshot: snapshot, adapter: second, publish: { _ in target = "second" }, resetWidth: {},
                        preview: { _, _, _ in }, keyBindings: KeyBindingsModel(adapter: second), airTraffic: AirTrafficModel(adapter: second))
    model.publish(snapshot)
    #expect(controller.window === window && model.adapter === second && target == "second")
    #expect(window?.isVisible == false)
}

@Test @MainActor
func settingsEditAfterRetargetUsesTheSecondWindowsSpace() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let first = WorkspaceAdapter(windowID: "settings-window-one", session: session)
    let second = WorkspaceAdapter(windowID: "settings-window-two", session: session)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let initial = try await settingsValue { first.open(path: directory.appendingPathComponent("settings.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    try await settingsValue { first.showSpace(id: "space-work", completion: $0) }
    try await settingsValue { second.showSpace(id: "space-home", completion: $0) }
    let firstSnapshot = try await settingsValue { first.snapshot(completion: $0) }
    let secondSnapshot = try await settingsValue { second.snapshot(completion: $0) }
    let model = SettingsModel(snapshot: firstSnapshot, adapter: first, publish: { _ in }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: first), airTraffic: AirTrafficModel(adapter: first))
    let settings = SettingsWindowController(model: model)
    let window = settings.window
    settings.retarget(snapshot: secondSnapshot, adapter: second, publish: { _ in }, resetWidth: {}, preview: { _, _, _ in },
                      keyBindings: KeyBindingsModel(adapter: second), airTraffic: AirTrafficModel(adapter: second))
    settings.prepare(shownSpaceID: secondSnapshot.shownSpaceId)
    model.rename("space-home", name: "Second window")
    try await waitUntil { model.snapshot.spaces.first { $0.id == "space-home" }?.title == "Second window" }
    #expect(settings.window === window && model.page == .space("space-home"))
    #expect(model.snapshot.spaces.first { $0.id == "space-work" }?.title == initial.spaces.first { $0.id == "space-work" }?.title)
    #expect(window?.isVisible == false)
}

@MainActor
private func settingsValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { done in start { done.resume(with: $0) } }
}

@Test @MainActor
func settingsPendingEditKeepsItsOriginAfterRetarget() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let first = WorkspaceAdapter(windowID: "pending-settings-a", session: session)
    let second = WorkspaceAdapter(windowID: "pending-settings-b", session: session)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    _ = try await settingsValue { first.open(path: directory.appendingPathComponent("pending.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    try await settingsValue { first.showSpace(id: "space-work", completion: $0) }
    try await settingsValue { second.showSpace(id: "space-home", completion: $0) }
    let firstSnapshot = try await settingsValue { first.snapshot(completion: $0) }
    let secondSnapshot = try await settingsValue { second.snapshot(completion: $0) }
    var firstPublished: WorkspaceSnapshot?
    var secondPublished: WorkspaceSnapshot?
    var release: (() -> Void)?
    let model = SettingsModel(snapshot: firstSnapshot, adapter: first, publish: { firstPublished = $0 }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: first), airTraffic: AirTrafficModel(adapter: first))
    model.checkEditCompletion = { release = $0 }
    model.rename("space-work", name: "Delayed edit")
    try await waitUntil { release != nil }
    model.retarget(snapshot: secondSnapshot, adapter: second, publish: { secondPublished = $0 }, resetWidth: {}, preview: { _, _, _ in },
                   keyBindings: KeyBindingsModel(adapter: second), airTraffic: AirTrafficModel(adapter: second))
    release?()
    try await waitUntil { secondPublished != nil }
    #expect(firstPublished?.shownSpaceId == "space-work")
    #expect(secondPublished?.shownSpaceId == "space-home")
    #expect(model.snapshot.shownSpaceId == "space-home")
    #expect(model.snapshot.spaces.first { $0.id == "space-work" }?.title == "Delayed edit")
    #expect(secondPublished?.spaces.first { $0.id == "space-work" }?.title == "Delayed edit")
}

@Test @MainActor
func delayedLookCompletionDoesNotClearRetargetedPreview() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let first = WorkspaceAdapter(windowID: "look-pending-a", session: session)
    let second = WorkspaceAdapter(windowID: "look-pending-b", session: session)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let initial = try await settingsValue { first.open(path: directory.appendingPathComponent("look.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let space = try #require(initial.spaces.first)
    let secondSnapshot = try await settingsValue { second.snapshot(completion: $0) }
    var firstPublished: WorkspaceSnapshot?
    var secondPreview: Look?
    var secondPreviewActive = false
    var release: (() -> Void)?
    let model = SettingsModel(snapshot: initial, adapter: first, publish: { firstPublished = $0 }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: first), airTraffic: AirTrafficModel(adapter: first))
    let oldEditor = LookEditorModel(settings: model, space: space)
    first.checkLookCompletion = { release = $0 }
    oldEditor.applyChip(page: 0, index: 1)
    oldEditor.dismiss()
    try await waitUntil { release != nil }
    model.retarget(snapshot: secondSnapshot, adapter: second, publish: { _ in }, resetWidth: {},
                   preview: { _, look, active in secondPreview = look; secondPreviewActive = active },
                   keyBindings: KeyBindingsModel(adapter: second), airTraffic: AirTrafficModel(adapter: second))
    let newEditor = LookEditorModel(settings: model, space: space)
    newEditor.begin()
    newEditor.change { $0.opacity = 0.21 }
    let expectedPreview = newEditor.look
    release?()
    #expect(firstPublished?.spaces.first(where: { $0.id == space.id })?.look?.colors == [LookEditorModel.chipColour(LookEditorModel.chipPages[0][1])])
    #expect(secondPreviewActive && secondPreview == expectedPreview)
    #expect(newEditor.editing)
}

@Test @MainActor
func aShortcutsSearchResultHighlightsItsRowId() throws {
    // A Shortcuts search result opens the Shortcuts pane, `highlighted` is the result's own
    // row id, and that id is the id of a row the pane's list renders, since the rows come from
    // `shortcutRows` at one place.
    let sidebar = KeyBinding(command: "toggle_sidebar", title: "Toggle Sidebar", menu: "View", description: "Show or hide the sidebar.", defaultKey: nil, key: nil, customized: false, conflicting: false, assignedKey: nil)
    let library = KeyBinding(command: "toggle_library", title: "Toggle Library", menu: "View", description: "Show or hide the Library.", defaultKey: nil, key: nil, customized: false, conflicting: false, assignedKey: nil)
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []), adapter: WorkspaceAdapter(windowID: "shortcuts-result"), publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "shortcuts-result-keys")), airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "shortcuts-result-atc")))
    model.shortcuts = SettingsModel.shortcutRows([sidebar, library])
    model.query = "Toggle Library"
    let result = try #require(model.results.first)
    model.select(result)
    #expect(result.id == "shortcut-toggle_library")
    #expect(model.page == .shortcuts && model.highlighted == result.id)
    #expect(model.filteredShortcuts.contains { $0.id == model.highlighted })
}

// The rendered pane fills the result's row with the selection grey and its neighbours with the
// card grey, read 6 pt inside each card's left edge off a cached bitmap of the detail view,
// against the same `SettingsColor` values the pane draws, rendered to a bitmap of its own. The
// aqua appearance pins the greys, which differ with the appearance.
@Test @MainActor
func aShortcutsSearchResultFillsItsRenderedRow() async throws {
    _ = NSApplication.shared
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []), adapter: WorkspaceAdapter(windowID: "card-fill"), publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "card-fill-keys")), airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "card-fill-atc")))
    model.shortcuts = SettingsModel.shortcutRows((0..<3).map {
        KeyBinding(command: "command_\($0)", title: "Utility \($0)", menu: "Utilities", description: "Do utility \($0).", defaultKey: nil, key: nil, customized: false, conflicting: false, assignedKey: nil)
    })
    model.navigate(.tabs)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    let aqua = try #require(NSAppearance(named: .aqua))
    window.appearance = aqua
    let split = try #require(window.contentViewController as? NSSplitViewController)
    let content = split.splitViewItems[1].viewController.view
    defer { window.contentViewController = nil }
    model.query = "Utility 1"
    let result = try #require(model.results.first)
    model.select(result)
    try await waitUntil {
        content.layoutSubtreeIfNeeded()
        let ids = Set(settingsDescendants(content).compactMap { $0.identifier?.rawValue })
        return ["row-shortcut-command_0", "row-shortcut-command_1", "row-shortcut-command_2"].allSatisfy { ids.contains($0) }
    }
    let swatches = NSHostingView(rootView: HStack(spacing: 0) {
        Rectangle().fill(SettingsColor.selected).frame(width: 20)
        Rectangle().fill(SettingsColor.card).frame(width: 20)
    }.frame(width: 40, height: 40))
    let swatchWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [], backing: .buffered, defer: false)
    swatchWindow.isReleasedWhenClosed = false
    swatchWindow.appearance = aqua
    swatchWindow.contentView = swatches
    defer { swatchWindow.contentView = nil }
    // The swatch read comes first: the row wait beneath needs the two source greys on hand,
    // and its one draw reads both values at once.
    swatchWindow.contentView?.layoutSubtreeIfNeeded()
    let swatchBitmap = try #require(swatches.bitmapImageRepForCachingDisplay(in: swatches.bounds))
    swatches.cacheDisplay(in: swatches.bounds, to: swatchBitmap)
    let selection = try #require(settingsCachedGrey(root: swatches, target: swatches, x: 10, bitmap: swatchBitmap))
    let card = try #require(settingsCachedGrey(root: swatches, target: swatches, x: 30, bitmap: swatchBitmap))
    // The row greys wait on their own pixels: every try draws a fresh bitmap and returns once
    // the highlighted card reads the selection grey and the two neighbours the card grey, so a
    // loaded machine cannot read a half-laid view.
    try await waitUntil {
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let read = (0...2).compactMap { index -> Int? in
            guard let view = settingsDescendants(content).first(where: { $0.identifier?.rawValue == "row-shortcut-command_\(index)" }) else { return nil }
            return settingsCachedGrey(root: content, target: view, x: 6, bitmap: bitmap)
        }
        return read.count == 3 && abs(read[1] - selection) <= 3 && abs(read[0] - card) <= 3 && abs(read[2] - card) <= 3
    }
    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bitmap)
    var greys: [Int] = []
    for index in 0...2 {
        let view = try #require(settingsDescendants(content).first { $0.identifier?.rawValue == "row-shortcut-command_\(index)" })
        greys.append(try #require(settingsCachedGrey(root: content, target: view, x: 6, bitmap: bitmap)))
    }
    #expect(abs(selection - card) > 10)
    #expect(greys[1] != greys[0] && greys[1] != greys[2])
    #expect(abs(greys[1] - selection) <= 3)
    #expect(abs(greys[0] - card) <= 3 && abs(greys[2] - card) <= 3)
    #expect(!window.isVisible)
}

@Test @MainActor
func settingsWindowNavigationSearchAndSlidesKeepTheSidebarSpace() throws {
    _ = NSApplication.shared
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "a", selectedId: nil, spaces: ["a", "b"].map {
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: $0, title: $0.uppercased(), icon: nil, look: nil, favorites: [], pinned: [], today: [])
    })
    let model = SettingsModel(snapshot: snapshot, adapter: WorkspaceAdapter(windowID: "settings"), publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "settings-defaults")), airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "settings-atc")))
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
    var snapshot = try await settingsValue { adapter.open(path: directory.appendingPathComponent("settings.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    if snapshot.spaces.count < 2 { snapshot = try await settingsValue { adapter.createSpace(name: "Second", completion: $0) } }
    let sidebar = SidebarView(snapshot: snapshot)
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { sidebar.applySelection(snapshot: $0) }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
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

@MainActor
private func settingsDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + settingsDescendants($0) }
}

// Reads the grey at the point `x` pt right of `target`'s left edge and level with its middle,
// off the cached bitmap of `root`; nil means the bitmap or the read failed, and the caller
// decides — with `#require`, or by retrying inside a `waitUntil`.
@MainActor
private func settingsCachedGrey(root: NSView, target: NSView, x: CGFloat, bitmap: NSBitmapImageRep) -> Int? {
    guard !root.bounds.isEmpty, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
    let scale = CGFloat(bitmap.pixelsWide) / max(1, root.bounds.width)
    let frame = target.convert(target.bounds, to: root)
    let px = Int((frame.minX + x) * scale)
    let yTop = root.isFlipped ? frame.midY : root.bounds.height - frame.midY
    let py = Int(yTop * scale)
    guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh else { return nil }
    let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceGray)
    return color.map { Int(($0.whiteComponent * 255).rounded()) }
}

@Test @MainActor
func settingsSearchScrollsTheHostingViewToItsHighlightedRow() async throws {
    _ = NSApplication.shared
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []), adapter: WorkspaceAdapter(windowID: "search"), publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "search-keys")), airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "search-atc")))
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

// The pane's own row ids from `shortcutRows` scroll the running detail view like the hand-set
// rows the earlier search test uses.
@Test @MainActor
func settingsSearchScrollsThePaneRowFromShortcutRows() async throws {
    _ = NSApplication.shared
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []), adapter: WorkspaceAdapter(windowID: "search-shortcuts"), publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "search-shortcuts-keys")), airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "search-shortcuts-atc")))
    model.shortcuts = SettingsModel.shortcutRows((0..<30).map {
        KeyBinding(command: "command_\($0)", title: "Utility \($0)", menu: "Utilities", description: "Do utility \($0).", defaultKey: nil, key: nil, customized: false, conflicting: false, assignedKey: nil)
    })
    model.navigate(.tabs)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    let split = try #require(window.contentViewController as? NSSplitViewController)
    let content = split.splitViewItems[1].viewController.view
    defer { window.contentViewController = nil }
    window.contentView?.layoutSubtreeIfNeeded()
    try await waitUntil { content.layoutSubtreeIfNeeded(); return settingsDescendants(content).contains { $0 is NSScrollView } }
    let scroll = try #require(settingsDescendants(content).compactMap { $0 as? NSScrollView }.first)
    model.query = "Utility 29"
    let result = try #require(model.results.first)
    model.select(result)
    try await waitUntil { content.layoutSubtreeIfNeeded(); return scroll.contentView.bounds.minY > 500 }
    #expect(result.id == "shortcut-command_29" && model.highlighted == result.id)
    #expect(model.filteredShortcuts.contains { $0.id == model.highlighted })
    #expect(!window.isVisible)
    model.navigate(.tabs)
    #expect(model.highlighted == nil)
}

@Test @MainActor
func settingsHarnessMenusReuseLifetimeAndWindowCloseRouting() throws {
    _ = NSApplication.shared
    let spaces = (0..<10).map { SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "s\($0)", title: "Space \($0)", icon: nil, look: nil, favorites: [], pinned: [], today: []) }
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
    second.model.readShortcuts()
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
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil, favorites: [], pinned: [], today: [])
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: nil, spaces: [space]), adapter: WorkspaceAdapter(windowID: "values"), publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "values-keys")), airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "values-atc")))
    model.editCompletion()(.failure(CoreError.Edit(message: "unknown space missing-id")))
    #expect(model.error == "unknown space missing-id")
    model.navigate(.tabs)
    #expect(model.error == nil)
    model.query = "This space"
    #expect(model.results.map(model.resultTitle) == ["Name — Work", "Icon — Work", "Look — Work", "Profile — Work"])
    #expect(SettingsModel.iconDraft("🔬😀") == "😀")
    #expect(SettingsModel.iconDraft("👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦")
    #expect(SettingsModel.settingsOffset(100, index: 0) < 100)
    #expect(SettingsModel.settingsOffset(-100, index: 0) == -100)
    #expect(SettingsModel.settingsOffset(100, index: 1) == 100)
}

// The count words go singular only at one: 0 and 2 stay plural, at the helper the header,
// the Spaces rows and the search results all read (a folder row in Today is not a tab).
@Test @MainActor
func theTabCountWordsGoSingularOnlyAtOne() {
    let tab = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "tab", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let split = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "split", title: "Split", url: nil, depth: 0, kind: .split, unloaded: false, lastSelectedAt: nil)
    let folder = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "folder", title: "Folder", url: nil, depth: 0, kind: .folder, unloaded: false, lastSelectedAt: nil)
    func space(_ id: String, today: [Row]) -> SpaceSnapshot {
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: id, title: id, icon: nil, look: nil, favorites: [], pinned: [], today: today)
    }
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [space("empty", today: []), space("one", today: [tab]), space("two", today: [tab, split, folder])]),
        adapter: WorkspaceAdapter(windowID: "counts"), publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "counts-keys")), airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "counts-atc")))
    #expect(model.tabCountLabel(model.snapshot.spaces[0]) == "0 tabs")
    #expect(model.tabCountLabel(model.snapshot.spaces[1]) == "1 tab")
    #expect(model.tabCountLabel(model.snapshot.spaces[2]) == "2 tabs")
    // The Spaces row subtitle carries the same words as the helper.
    #expect(model.rows.first { $0.id == "one" }?.subtitle.hasPrefix("1 tab ·") == true)
    #expect(model.rows.first { $0.id == "empty" }?.subtitle.hasPrefix("0 tabs ·") == true)
}
