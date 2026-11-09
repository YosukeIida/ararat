import AppKit
import AraratKit
import Testing
@testable import AraratUI
@testable import AraratHarness

@Test @MainActor
func clearingCoreShortcutCollisionsPreservesOtherModifiers() {
    let menu = NSMenu()
    let collision = menu.addItem(withTitle: "Save", action: nil, keyEquivalent: "s")
    collision.keyEquivalentModifierMask = .command
    let other = menu.addItem(withTitle: "Other", action: nil, keyEquivalent: "s")
    other.keyEquivalentModifierMask = [.command, .shift]
    let displaced = KeyBindingsModel.clearCollisions(defaultKeyBindings().filter { $0.command == "toggle_sidebar" }, in: menu)
    #expect(displaced["toggle_sidebar"] === collision)
    #expect(collision.keyEquivalent.isEmpty)
    #expect(other.keyEquivalent == "s")
}

@Test @MainActor
func clearingCoreShortcutCollisionsRecognizesShiftInUppercaseEquivalent() {
    let menu = NSMenu()
    let collision = menu.addItem(withTitle: "Vertical Tabs", action: nil, keyEquivalent: "L")
    collision.keyEquivalentModifierMask = .command
    let other = menu.addItem(withTitle: "Location", action: nil, keyEquivalent: "l")
    other.keyEquivalentModifierMask = .command
    let displaced = KeyBindingsModel.clearCollisions(defaultKeyBindings().filter { $0.command == "toggle_library" }, in: menu)
    #expect(displaced["toggle_library"] === collision)
    #expect(collision.keyEquivalent.isEmpty)
    #expect(other.keyEquivalent == "l")
}

@MainActor
private func bindingValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private func commandItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(commandItems) ?? []) }
}

/// A key event built in the test process; the recorder view consumes it, nothing is posted to the OS.
private func recorderKeyEvent(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers, isARepeat: false, keyCode: keyCode))
}

private func recorderBinding(key: String, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) -> KeyCombination {
    KeyCombination(key: key, command: command, control: control, option: option, shift: shift)
}

@MainActor
private func openedBindings(_ directory: URL) async throws -> (WorkspaceAdapter, WorkspaceSnapshot) {
    let adapter = WorkspaceAdapter(windowID: "recorder")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let snapshot = try await bindingValue {
        adapter.open(path: directory.appendingPathComponent("recorder.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    return (adapter, snapshot)
}

/// assembles the running pieces for the recorder tests, like the menus tests do.
@MainActor
private func mountedHarness(_ adapter: WorkspaceAdapter, snapshot: WorkspaceSnapshot) throws -> (HarnessDelegate, NSMenu, SettingsWindowController, ShortcutsRecorderView) {
    let harness = HarnessDelegate(adapter: adapter)
    harness.snapshot = snapshot
    let menu = harness.makeMenu()
    harness.sidebar = SidebarView(snapshot: snapshot)
    let settings = harness.prepareSettings()
    // The recorder is fed directly, as the pane's bridge mounts it while a row records.
    let recorder = ShortcutsRecorderView()
    recorder.bindings = harness.keyBindings
    return (harness, menu, settings, recorder)
}

@Test @MainActor
func recorderAppliesAKeyThenEscCancelsAndBackspaceClears() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, menu, settings, recorder) = try mountedHarness(adapter, snapshot: snapshot)
    let library = try #require(commandItems(menu).first { $0.identifier?.rawValue == "toggle_library" })
    let defaults = try #require(harness.keyBindings.binding(command: "toggle_library"))
    #expect(defaults.key == recorderBinding(key: "l", command: true, shift: true))
    settings.model.readShortcuts()

    // Click the row's key (the pane calls toggleRecording), then type the new key into the recorder view.
    harness.keyBindings.toggleRecording("toggle_library")
    #expect(harness.keyBindings.recording == KeyBindingsModel.Recording(command: "toggle_library", candidate: nil, holder: nil))
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 40, characters: "k", charactersIgnoringModifiers: "k", flags: [.control, .option]))
    _ = try await bindingValue { adapter.keyBindings(completion: $0) }
    try #require(harness.keyBindings.recording == nil)
    #expect(try #require(harness.keyBindings.binding(command: "toggle_library")).key == recorderBinding(key: "k", control: true, option: true))
    #expect(library.keyEquivalent == "k" && library.keyEquivalentModifierMask == [.control, .option])
    settings.model.readShortcuts()
    let customized = try #require(settings.model.shortcuts.first { $0.command == "toggle_library" })
    #expect(customized.keys == ["⌃", "⌥", "K"] && customized.customized && !customized.conflicting)

    // Esc cancels the next recording and keeps the recorded key from before.
    harness.keyBindings.toggleRecording("toggle_library")
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 53, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", flags: []))
    #expect(harness.keyBindings.recording == nil)
    #expect(harness.keyBindings.binding(command: "toggle_library")?.key?.key == "k")
    #expect(library.keyEquivalent == "k")

    // ⌫ clears the row to none, which the menus show as no key at all.
    harness.keyBindings.toggleRecording("toggle_library")
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 51, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", flags: []))
    _ = try await bindingValue { adapter.keyBindings(completion: $0) }
    #expect(harness.keyBindings.recording == nil)
    #expect(try #require(harness.keyBindings.binding(command: "toggle_library")).key == nil)
    #expect(library.keyEquivalent.isEmpty && library.keyEquivalentModifierMask == [])
    settings.model.readShortcuts()
    #expect(try #require(settings.model.shortcuts.first { $0.command == "toggle_library" }).keys.isEmpty)

    // clean up the store for later runs
    try await bindingValue { harness.keyBindings.reset(command: "toggle_library", completion: $0) }
    #expect(try #require(harness.keyBindings.binding(command: "toggle_library")).key == recorderBinding(key: "l", command: true, shift: true))
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func recorderRefusesAModifierlessKeyAndAReservedKeyAndKeepsTheOldKey() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, menu, _, recorder) = try mountedHarness(adapter, snapshot: snapshot)
    let library = try #require(commandItems(menu).first { $0.identifier?.rawValue == "toggle_library" })
    let close = try #require(commandItems(menu).first { $0.identifier?.rawValue == "close_tab" })

    // A key without Command, Control or Option is refused with the reason and keeps the old key.
    harness.keyBindings.toggleRecording("toggle_library")
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 13, characters: "w", charactersIgnoringModifiers: "w", flags: []))
    try await waitUntil { harness.keyBindings.error == "a shortcut needs Command, Control or Option" }
    #expect(harness.keyBindings.recording == nil)
    #expect(harness.keyBindings.binding(command: "toggle_library")?.key == recorderBinding(key: "l", command: true, shift: true))
    #expect(library.keyEquivalent == "l" && library.keyEquivalentModifierMask == [.command, .shift])

    // A reserved system key is refused the same way, with the menus untouched: ⌥⌘Esc is reserved
    // and held by no command, so the first press goes to the core and comes back with the reason.
    harness.keyBindings.toggleRecording("toggle_library")
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 53, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", flags: [.option, .command]))
    try await waitUntil { harness.keyBindings.error == "this shortcut is reserved by the system" }
    #expect(harness.keyBindings.recording == nil)
    #expect(harness.keyBindings.binding(command: "toggle_library")?.key == recorderBinding(key: "l", command: true, shift: true))
    #expect(close.keyEquivalent == "w" && library.keyEquivalent == "l")
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func recorderNamesTheHolderAndASecondPressTakesTheKeyOver() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let harness = HarnessDelegate(adapter: adapter)
    harness.snapshot = snapshot
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    let menu = harness.makeMenu()
    harness.sidebar = SidebarView(snapshot: snapshot)
    let recorder = ShortcutsRecorderView()
    recorder.bindings = harness.keyBindings
    let sidebar = try #require(commandItems(menu).first { $0.identifier?.rawValue == "toggle_sidebar" })
    let library = try #require(commandItems(menu).first { $0.identifier?.rawValue == "toggle_library" })
    // toggle_library takes toggle_sidebar's ⌘S, so toggle_sidebar's row loses its key.
    try await bindingValue { harness.keyBindings.set(command: "toggle_library", key: recorderBinding(key: "s", command: true), completion: $0) }
    #expect(sidebar.keyEquivalent.isEmpty && library.keyEquivalent == "s")

    // Recording toggle_sidebar and pressing ⌘S names the holder; the table is not touched yet.
    harness.keyBindings.toggleRecording("toggle_sidebar")
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 1, characters: "s", charactersIgnoringModifiers: "s", flags: [.command]))
    try #require(harness.keyBindings.recording == KeyBindingsModel.Recording(command: "toggle_sidebar",
                                                                              candidate: recorderBinding(key: "s", command: true),
                                                                              holder: "Toggle Library"))
    #expect(sidebar.keyEquivalent.isEmpty && library.keyEquivalent == "s" && sidebar.keyEquivalentModifierMask == [])
    // Pressing the same key again takes it over: the loser goes back to none.
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 1, characters: "s", charactersIgnoringModifiers: "s", flags: [.command]))
    _ = try await bindingValue { adapter.keyBindings(completion: $0) }
    #expect(harness.keyBindings.recording == nil)
    #expect(try #require(harness.keyBindings.binding(command: "toggle_sidebar")).key == recorderBinding(key: "s", command: true))
    #expect(try #require(harness.keyBindings.binding(command: "toggle_library")).key == nil)
    #expect(sidebar.keyEquivalent == "s" && sidebar.keyEquivalentModifierMask == [.command] && library.keyEquivalent.isEmpty)
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func recorderTakesTheKeyCharacterFromTheKeyCodeNotFromShift() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, menu, _, recorder) = try mountedHarness(adapter, snapshot: snapshot)
    let library = try #require(commandItems(menu).first { $0.identifier?.rawValue == "toggle_library" })
    harness.keyBindings.toggleRecording("toggle_library")
    // ⇧ is not part of the key: the event gives "$", the key code gives "4".
    let event = try recorderKeyEvent(keyCode: 21, characters: "$", charactersIgnoringModifiers: "4", flags: [.control, .option, .shift])
    #expect(event.characters(byApplyingModifiers: []) == "4")
    recorder.keyDown(with: event)
    _ = try await bindingValue { adapter.keyBindings(completion: $0) }
    #expect(try #require(harness.keyBindings.binding(command: "toggle_library")).key == recorderBinding(key: "4", control: true, option: true, shift: true))
    #expect(library.keyEquivalent == "4" && library.keyEquivalentModifierMask == [.control, .option, .shift])
    try await bindingValue { harness.keyBindings.reset(command: "toggle_library", completion: $0) }
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func theMenusUpdateAfterARecording() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, menu, settings, recorder) = try mountedHarness(adapter, snapshot: snapshot)
    settings.model.readShortcuts()
    let close = try #require(commandItems(menu).first { $0.identifier?.rawValue == "close_tab" })
    let pin = try #require(commandItems(menu).first { $0.identifier?.rawValue == "pin_tab" })
    // One recording updates the menu, the row and the sidebar keys; a cancelled recording changes nothing.
    harness.keyBindings.toggleRecording("close_tab")
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 7, characters: "x", charactersIgnoringModifiers: "x", flags: [.control, .option]))
    _ = try await bindingValue { adapter.keyBindings(completion: $0) }
    #expect(close.keyEquivalent == "x" && close.keyEquivalentModifierMask == [.control, .option])
    #expect(pin.keyEquivalent == "d")
    settings.model.readShortcuts()
    let row = try #require(settings.model.shortcuts.first { $0.command == "close_tab" })
    #expect(row.keys == ["⌃", "⌥", "X"] && row.customized)
    harness.keyBindings.toggleRecording("pin_tab")
    recorder.keyDown(with: try recorderKeyEvent(keyCode: 53, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", flags: []))
    #expect(pin.keyEquivalent == "d" && close.keyEquivalent == "x")
    try await bindingValue { harness.keyBindings.resetAll(completion: $0) }
    #expect(close.keyEquivalent == "w" && pin.keyEquivalent == "d")
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func paneSearchFiltersResetRemoveAndResetAllEditTheRows() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let harness = HarnessDelegate(adapter: adapter)
    harness.snapshot = snapshot
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    let menu = harness.makeMenu()
    harness.sidebar = SidebarView(snapshot: snapshot)
    let settings = harness.prepareSettings()
    let model = settings.model

    // A table with a conflict (cross-device merges produce these; a local edit steals instead):
    let s = recorderBinding(key: "s", command: true)
    let sidebar = KeyBinding(command: "toggle_sidebar", title: "Toggle Sidebar", menu: "View", description: "Show or hide the sidebar.",
                             defaultKey: s, key: s, customized: false, conflicting: false, assignedKey: nil)
    let library = KeyBinding(command: "toggle_library", title: "Toggle Library", menu: "View", description: "Show or hide the Library.",
                             defaultKey: recorderBinding(key: "l", command: true, shift: true), key: nil, customized: false,
                             conflicting: true, assignedKey: s)
    let none = KeyBinding(command: "reset_sidebar_width", title: "Reset Sidebar Width", menu: "View", description: "Reset the sidebar width.",
                          defaultKey: nil, key: nil, customized: false, conflicting: false, assignedKey: nil)
    let rows = SettingsModel.shortcutRows([sidebar, library, none])
    model.shortcuts = rows
    model.shortcutQuery = ""
    #expect(model.filteredShortcuts == rows)
    // The conflicting row shows the key it lost and names the holder.
    let conflictRow = try #require(rows.first { $0.conflicting })
    #expect(conflictRow.subtitle.contains("Conflicting: ⌘S is held by Toggle Sidebar") && conflictRow.keys == ["⌘", "S"])

    // Search matches names, descriptions and keys: the conflicting row also matches through the
    // holder name in its subtitle.
    model.shortcutQuery = "sidebar"
    #expect(Set(model.filteredShortcuts.map(\.id)) == Set(rows.map(\.id)))
    model.shortcutQuery = "⌘S"
    #expect(Set(model.filteredShortcuts.map(\.id)) == Set(rows.prefix(2).map(\.id)))
    model.shortcutQuery = "4"
    #expect(model.filteredShortcuts.isEmpty)

    // The filters combine with the search.
    model.shortcutQuery = ""
    model.conflictingOnly = true
    #expect(model.filteredShortcuts == [rows[1]])
    model.conflictingOnly = false
    model.customizedOnly = true
    #expect(model.filteredShortcuts.isEmpty)
    var customized = sidebar
    customized.key = recorderBinding(key: "w", command: true)
    customized.customized = true
    model.shortcuts = SettingsModel.shortcutRows([customized, library, none])
    #expect(model.filteredShortcuts.map(\.id) == ["shortcut-toggle_sidebar"])
    model.customizedOnly = false

    // Real adapter edits behind the pane wrappers, read back through the rows.
    try await bindingValue { harness.keyBindings.set(command: "close_tab", key: recorderBinding(key: "x", control: true, option: true), completion: $0) }
    model.readShortcuts()
    #expect(model.shortcuts.contains { $0.command == "close_tab" && $0.customized && $0.keys == ["⌃", "⌥", "X"] })
    model.customizedOnly = true
    #expect(model.filteredShortcuts.map(\.command) == ["close_tab"])
    model.customizedOnly = false
    model.removeShortcut("close_tab")
    try await waitUntil { harness.keyBindings.binding(command: "close_tab")?.key == nil }
    model.readShortcuts()
    #expect(model.shortcuts.contains { $0.command == "close_tab" && $0.customized && $0.keys.isEmpty })
    model.customizedOnly = true
    #expect(model.filteredShortcuts.map(\.command) == ["close_tab"])
    model.customizedOnly = false

    // Reset puts the default back; Reset All clears every override.
    try await bindingValue { harness.keyBindings.set(command: "close_tab", key: recorderBinding(key: "x", control: true), completion: $0) }
    model.resetShortcut("close_tab")
    try await waitUntil { harness.keyBindings.binding(command: "close_tab")?.key == recorderBinding(key: "w", command: true) }
    model.readShortcuts()
    try await bindingValue { harness.keyBindings.set(command: "close_tab", key: recorderBinding(key: "x", control: true), completion: $0) }
    try await bindingValue { harness.keyBindings.set(command: "toggle_sidebar", key: recorderBinding(key: "b", option: true), completion: $0) }
    model.resetAllShortcuts()
    try await waitUntil { harness.keyBindings.bindings == defaultKeyBindings() }
    model.readShortcuts()
    #expect(model.shortcuts.first { $0.command == "close_tab" }?.keys == ["⌘", "W"])
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@MainActor
private func bindingDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(bindingDescendants) }

@MainActor
private final class RecorderWindowObserver: NSObject, NSWindowDelegate {
    var closed = false
    func windowWillClose(_ notification: Notification) { closed = true }
}

@Test @MainActor
func theSettingsWindowRoutesARecordingPastItsCloseAndSettingsKeys() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    settings.model.readShortcuts()
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window as? SettingsWindow)
    let closer = RecorderWindowObserver()
    window.delegate = closer
    try await waitUntil {
        window.contentView!.layoutSubtreeIfNeeded()
        return bindingDescendants(window.contentView!).contains { $0 is ShortcutsRecorderView }
    }
    // The pane bridge takes first responder while a row records, so ⌘W and ⌘, are recorded
    // instead of closing the window or opening Settings.
    settings.model.toggleRecording("settings")
    try await waitUntil { window.firstResponder is ShortcutsRecorderView }
    let commandW = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    let commandComma = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
    #expect(window.performKeyEquivalent(with: commandW))
    #expect(harness.keyBindings.recording == KeyBindingsModel.Recording(command: "settings", candidate: recorderBinding(key: "w", command: true), holder: "Close Tab"))
    #expect(!closer.closed)
    // Pressing ⌘W again takes the key over: the loser goes back to none, through the window.
    #expect(window.performKeyEquivalent(with: commandW))
    try await waitUntil { harness.keyBindings.binding(command: "settings")?.key == recorderBinding(key: "w", command: true) }
    #expect(harness.keyBindings.binding(command: "close_tab")?.key == nil)
    #expect(!closer.closed)
    // ⌘, follows the same route to a different row (⌘, is free after the takeover).
    settings.model.toggleRecording("quit")
    try await waitUntil { window.firstResponder is ShortcutsRecorderView }
    #expect(window.performKeyEquivalent(with: commandComma))
    try await waitUntil { harness.keyBindings.binding(command: "quit")?.key == recorderBinding(key: ",", command: true) }
    #expect(!closer.closed)
    try await bindingValue { harness.keyBindings.resetAll(completion: $0) }
    try await waitUntil { harness.keyBindings.bindings == defaultKeyBindings() }
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func aConflictingRowMarksItsLostKey() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    // A cross-device table with a conflict: toggle_library lost its ⇧⌘L to toggle_sidebar's ⌘S.
    let kept = recorderBinding(key: "s", command: true)
    let sidebar = KeyBinding(command: "toggle_sidebar", title: "Toggle Sidebar", menu: "View", description: "Show or hide the sidebar.",
                             defaultKey: kept, key: kept, customized: false, conflicting: false, assignedKey: nil)
    let library = KeyBinding(command: "toggle_library", title: "Toggle Library", menu: "View", description: "Show or hide the Library.",
                             defaultKey: recorderBinding(key: "l", command: true, shift: true), key: nil, customized: false,
                             conflicting: true, assignedKey: kept)
    settings.model.shortcuts = SettingsModel.shortcutRows([sidebar, library])
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window as? SettingsWindow)
    try await waitUntil {
        window.contentView!.layoutSubtreeIfNeeded()
        let labels = bindingDescendants(window.contentView!).compactMap { $0 as? NSTextField }
        return labels.contains { $0.stringValue == "Conflicting" }
    }
    // The row still shows the key it lost in caps beside the label (the model side is covered
    // through paneSearchFilters…), so it does not read as a live key.
    let conflictRow = try #require(settings.model.shortcuts.first { $0.conflicting })
    #expect(conflictRow.keys == ["⌘", "S"])
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func leavingTheRecorderCancelsTheRecordingAndKeysReachTheSearchField() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    settings.model.readShortcuts()
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window as? SettingsWindow)
    try await waitUntil {
        window.contentView!.layoutSubtreeIfNeeded()
        return bindingDescendants(window.contentView!).contains { $0 is ShortcutsRecorderView }
    }
    settings.model.toggleRecording("close_tab")
    try await waitUntil { window.firstResponder is ShortcutsRecorderView }
    let split = try #require(window.contentViewController as? NSSplitViewController)
    let detail = split.splitViewItems[1].viewController.view
    let search = try #require(bindingDescendants(detail).compactMap { $0 as? NSTextField }.first { "\(type(of: $0))" == "AppKitTextField" })
    // A click into the search field resigns the recorder: the recording cancels instead of the
    // bridge pulling focus back on the next SwiftUI pass.
    window.makeFirstResponder(search)
    try await waitUntil { harness.keyBindings.recording == nil }
    #expect(!(window.firstResponder is ShortcutsRecorderView))
    // Typed keys stay in the field across the SwiftUI updates they trigger: the bridge takes
    // first responder only when a recording starts, never while the same one records.
    search.currentEditor()?.insertText("c")
    try await waitUntil { (search.currentEditor()?.string ?? search.stringValue) == "c" && settings.model.shortcutQuery == "c" }
    #expect(!(window.firstResponder is ShortcutsRecorderView))
    search.currentEditor()?.insertText("lo")
    try await waitUntil { (search.currentEditor()?.string ?? search.stringValue) == "clo" && settings.model.shortcutQuery == "clo" }
    #expect(!(window.firstResponder is ShortcutsRecorderView))
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func screenshotKeysAreRefusedByKeyCodeOnAnyLayout() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, menu, _, recorder) = try mountedHarness(adapter, snapshot: snapshot)
    let library = try #require(commandItems(menu).first { $0.identifier?.rawValue == "toggle_library" })
    for keyCode: UInt16 in [20, 21, 23] {
        harness.keyBindings.toggleRecording("toggle_library")
        // The key code is the physical screenshot key; the character is what the AZERTY layout
        // puts there (", ' ( instead of 3 4 5), and the core's character check passes it.
        recorder.keyDown(with: try recorderKeyEvent(keyCode: keyCode, characters: "'", charactersIgnoringModifiers: "'", flags: [.command, .shift]))
        #expect(harness.keyBindings.error == "this shortcut is reserved by the system")
        #expect(harness.keyBindings.recording == nil)
        #expect(try #require(harness.keyBindings.binding(command: "toggle_library")).key == recorderBinding(key: "l", command: true, shift: true))
        #expect(library.keyEquivalent == "l" && library.keyEquivalentModifierMask == [.command, .shift])
    }
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}



@MainActor
private func shortcutMarker(_ window: NSWindow, _ id: String) -> NSView? {
    guard let content = window.contentView else { return nil }
    content.layoutSubtreeIfNeeded()
    return bindingDescendants(content).first { $0.identifier?.rawValue == id }
}

@MainActor
private func shortcutFrame(_ window: NSWindow, _ id: String) throws -> NSRect {
    let view = try #require(shortcutMarker(window, id))
    return view.convert(view.bounds, to: nil)
}

/// A non-throwing frame height: a row SwiftUI is rebuilding can drop its marker for a pass,
/// so waits fold presence and size in here instead of measuring straight after a marker wait.
@MainActor
private func shortcutHeight(_ window: NSWindow, _ id: String) -> CGFloat? {
    shortcutMarker(window, id).map { $0.convert($0.bounds, to: nil).height }
}

@Test @MainActor
func shortcutRecorderStaysInsideItsColumnInBothAppearances() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    settings.model.readShortcuts()
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        settings.model.toggleRecording("toggle_sidebar")
        try await waitUntil {
            shortcutMarker(window, "recorder-shortcut-toggle_sidebar") != nil
                && shortcutMarker(window, "column-shortcut-toggle_sidebar") != nil
                && shortcutMarker(window, "row-shortcut-toggle_sidebar") != nil
        }
        let column = try shortcutFrame(window, "column-shortcut-toggle_sidebar")
        let recorder = try shortcutFrame(window, "recorder-shortcut-toggle_sidebar")
        let row = try shortcutFrame(window, "row-shortcut-toggle_sidebar")
        #expect(abs(column.width - 140) < 1)
        #expect(column.insetBy(dx: -1, dy: -1).contains(recorder))
        #expect(abs(row.maxX - column.maxX - 12) < 1)
        settings.model.toggleRecording("toggle_sidebar")
    }
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func shortcutConflictMessageIsBelowDescriptionOutsideRecorder() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    settings.model.readShortcuts()
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        try await waitUntil { shortcutMarker(window, "row-shortcut-toggle_sidebar") != nil }
        let baseline = try shortcutFrame(window, "row-shortcut-toggle_sidebar").height
        let commandD = try recorderKeyEvent(keyCode: 2, characters: "d", charactersIgnoringModifiers: "d", flags: [.command])
        let escape = try recorderKeyEvent(keyCode: 53, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", flags: [])

        settings.model.toggleRecording("toggle_sidebar")
        _ = harness.keyBindings.handle(commandD)
        try await waitUntil {
            shortcutMarker(window, "message-shortcut-toggle_sidebar") != nil
                && (shortcutHeight(window, "row-shortcut-toggle_sidebar") ?? 0) > baseline + 0.5
        }
        let description = try shortcutFrame(window, "description-shortcut-toggle_sidebar")
        let message = try shortcutFrame(window, "message-shortcut-toggle_sidebar")
        let recorder = try shortcutFrame(window, "recorder-shortcut-toggle_sidebar")
        #expect(message.maxY <= description.minY + 1)
        #expect(!message.intersects(recorder))
        #expect(try shortcutFrame(window, "row-shortcut-toggle_sidebar").height > baseline)
        _ = harness.keyBindings.handle(escape)
        try await waitUntil {
            shortcutMarker(window, "message-shortcut-toggle_sidebar") == nil
                && abs((shortcutHeight(window, "row-shortcut-toggle_sidebar") ?? 0) - baseline) < 0.5
        }
        #expect(abs((try shortcutFrame(window, "row-shortcut-toggle_sidebar").height) - baseline) < 1)

        settings.model.toggleRecording("toggle_sidebar")
        _ = harness.keyBindings.handle(commandD)
        try await waitUntil { shortcutMarker(window, "message-shortcut-toggle_sidebar") != nil }
        _ = harness.keyBindings.handle(commandD)
        try await waitUntil {
            harness.keyBindings.binding(command: "toggle_sidebar")?.key == recorderBinding(key: "d", command: true)
                && shortcutMarker(window, "message-shortcut-toggle_sidebar") == nil
                && abs((shortcutHeight(window, "row-shortcut-toggle_sidebar") ?? 0) - baseline) < 0.5
        }
        #expect(abs((try shortcutFrame(window, "row-shortcut-toggle_sidebar").height) - baseline) < 1)
        try await bindingValue { harness.keyBindings.resetAll(completion: $0) }
        settings.model.readShortcuts()

        settings.model.toggleRecording("toggle_sidebar")
        try await waitUntil { window.firstResponder is ShortcutsRecorderView }
        _ = harness.keyBindings.handle(commandD)
        try await waitUntil { shortcutMarker(window, "message-shortcut-toggle_sidebar") != nil }
        let split = try #require(window.contentViewController as? NSSplitViewController)
        let search = try #require(bindingDescendants(split.splitViewItems[1].viewController.view).compactMap { $0 as? NSTextField }.first { "\(type(of: $0))" == "AppKitTextField" })
        window.makeFirstResponder(search)
        try await waitUntil {
            harness.keyBindings.recording == nil
                && shortcutMarker(window, "message-shortcut-toggle_sidebar") == nil
                && abs((shortcutHeight(window, "row-shortcut-toggle_sidebar") ?? 0) - baseline) < 0.5
        }
        #expect(abs((try shortcutFrame(window, "row-shortcut-toggle_sidebar").height) - baseline) < 1)

        settings.model.toggleRecording("toggle_sidebar")
        try await waitUntil { shortcutMarker(window, "recorder-shortcut-toggle_sidebar") != nil }
        let refusalRecorder = try shortcutFrame(window, "recorder-shortcut-toggle_sidebar")
        _ = harness.keyBindings.handle(try recorderKeyEvent(keyCode: 13, characters: "w", charactersIgnoringModifiers: "w", flags: []))
        try await waitUntil {
            harness.keyBindings.errorCommand == "toggle_sidebar"
                && shortcutMarker(window, "message-shortcut-toggle_sidebar") != nil
                && shortcutMarker(window, "description-shortcut-toggle_sidebar") != nil
                && shortcutMarker(window, "row-shortcut-toggle_sidebar") != nil
        }
        let refusal = try shortcutFrame(window, "message-shortcut-toggle_sidebar")
        let refusalDescription = try shortcutFrame(window, "description-shortcut-toggle_sidebar")
        let marker = try #require(shortcutMarker(window, "message-shortcut-toggle_sidebar") as? NSTextField)
        #expect(harness.keyBindings.error == "a shortcut needs Command, Control or Option")
        #expect(marker.textColor == NSColor.systemRed)
        #expect(refusal.maxY <= refusalDescription.minY + 1)
        #expect(!refusal.intersects(refusalRecorder))
        settings.model.toggleRecording("toggle_sidebar")
        settings.model.toggleRecording("toggle_sidebar")
        try await waitUntil { shortcutMarker(window, "message-shortcut-toggle_sidebar") == nil }
        #expect(abs((try shortcutFrame(window, "row-shortcut-toggle_sidebar").height) - baseline) < 1)
    }
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func shortcutColumnsShareTheirTrailingEdge() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    settings.model.readShortcuts()
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        try await waitUntil { shortcutMarker(window, "column-shortcut-close_tab") != nil && shortcutMarker(window, "column-shortcut-toggle_sidebar") != nil }
        let columns = try settings.model.shortcuts.map { try shortcutFrame(window, "column-\($0.id)") }
        let trailing = try #require(columns.first?.maxX)
        #expect(columns.allSatisfy { abs($0.maxX - trailing) < 1 && abs($0.width - 140) < 1 })
        for row in settings.model.shortcuts {
            let content = try shortcutFrame(window, "content-\(row.id)")
            let column = try shortcutFrame(window, "column-\(row.id)")
            #expect(abs(content.maxX - column.maxX) < 1, "\(row.title)")
        }
    }
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func conflictingLongShortcutFitsItsColumn() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    let key = recorderBinding(key: "x", command: true, control: true, option: true, shift: true)
    let holder = KeyBinding(command: "toggle_sidebar", title: "Toggle Sidebar", menu: "View", description: "Show or hide the sidebar.", defaultKey: key, key: key, customized: false, conflicting: false, assignedKey: nil)
    let loser = KeyBinding(command: "toggle_library", title: "Toggle Library", menu: "View", description: "Show or hide the Library.", defaultKey: key, key: nil, customized: false, conflicting: true, assignedKey: key)
    settings.model.shortcuts = SettingsModel.shortcutRows([holder, loser])
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        try await waitUntil { shortcutMarker(window, "face-shortcut-toggle_library") != nil && shortcutMarker(window, "content-shortcut-toggle_library") != nil }
        let face = try shortcutFrame(window, "face-shortcut-toggle_library")
        let caps = try shortcutFrame(window, "content-shortcut-toggle_library")
        let column = try shortcutFrame(window, "column-shortcut-toggle_library")
        #expect(face.width <= 140)
        #expect(column.insetBy(dx: -1, dy: -1).contains(face))
        #expect(abs(caps.maxX - column.maxX) < 1)
        let caption = try #require(bindingDescendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Conflicting" })
        let captionFrame = caption.convert(caption.bounds, to: nil)
        #expect(captionFrame.maxY <= caps.minY + 1)
    }
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func aRefusalOnARowHiddenByTheQueryShowsAtPaneLevel() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    settings.model.readShortcuts()
    settings.model.navigate(.shortcuts)
    let window = try #require(settings.window)
    try await waitUntil { shortcutMarker(window, "row-shortcut-toggle_sidebar") != nil }

    // Recording toggle_sidebar and then hiding its row with the search: the core's refusal for a
    // modifierless key arrives with the row filtered out, so the reason must show above the list
    // instead of under a row the pane does not render.
    settings.model.toggleRecording("toggle_sidebar")
    settings.model.shortcutQuery = "library"
    try await waitUntil { shortcutMarker(window, "row-shortcut-toggle_sidebar") == nil }
    _ = harness.keyBindings.handle(try recorderKeyEvent(keyCode: 13, characters: "w", charactersIgnoringModifiers: "w", flags: []))
    try await waitUntil {
        harness.keyBindings.error == "a shortcut needs Command, Control or Option"
            && shortcutMarker(window, "refusal-pane") != nil
            && shortcutMarker(window, "message-shortcut-toggle_sidebar") == nil
            && shortcutMarker(window, "row-shortcut-toggle_sidebar") == nil
    }
    try #require(harness.keyBindings.errorCommand == "toggle_sidebar")
    let refusal = try #require(shortcutMarker(window, "refusal-pane") as? NSTextField)
    #expect(refusal.stringValue == "a shortcut needs Command, Control or Option")
    #expect(refusal.textColor == NSColor.systemRed)
    #expect(refusal.font?.pointSize == 11)
    window.contentViewController = nil
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}

@Test @MainActor
func changingTheQueryOrTheFiltersClearsARefusal() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (adapter, snapshot) = try await openedBindings(directory)
    let (harness, _, settings, _) = try mountedHarness(adapter, snapshot: snapshot)
    try await bindingValue { harness.keyBindings.load(completion: $0) }
    let model = settings.model
    model.readShortcuts()
    let modifierless = try recorderKeyEvent(keyCode: 13, characters: "w", charactersIgnoringModifiers: "w", flags: [])

    // The refusal names one row of the pane, so typing in its search or toggling one of its
    // filters drops the reason instead of keeping it for a row that may have left the list.
    model.toggleRecording("toggle_sidebar")
    _ = harness.keyBindings.handle(modifierless)
    try await waitUntil { harness.keyBindings.errorCommand == "toggle_sidebar" }
    #expect(harness.keyBindings.error == "a shortcut needs Command, Control or Option")
    model.shortcutQuery = "sidebar"
    #expect(harness.keyBindings.error == nil && harness.keyBindings.errorCommand == nil)

    model.toggleRecording("toggle_sidebar")
    _ = harness.keyBindings.handle(modifierless)
    try await waitUntil { harness.keyBindings.errorCommand == "toggle_sidebar" }
    model.customizedOnly = true
    #expect(harness.keyBindings.error == nil && harness.keyBindings.errorCommand == nil)

    model.toggleRecording("toggle_sidebar")
    _ = harness.keyBindings.handle(modifierless)
    try await waitUntil { harness.keyBindings.errorCommand == "toggle_sidebar" }
    model.conflictingOnly = true
    #expect(harness.keyBindings.error == nil && harness.keyBindings.errorCommand == nil)
    _ = try await bindingValue { adapter.shutdown(completion: $0) }
}
