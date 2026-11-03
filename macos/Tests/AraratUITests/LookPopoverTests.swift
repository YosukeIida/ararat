import AppKit
import AraratKit
import SwiftUI
import SQLite3
import Testing
@testable import AraratUI
@testable import AraratHarness

@MainActor
private func lookValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private final class LookPreview { var look: Look? }

@MainActor
private final class LookFixture {
    let preview = LookPreview()
    let directory: URL
    let adapter: WorkspaceAdapter
    let settings: SettingsModel
    let editor: LookEditorModel
    let sidebar: SidebarView?
    init(sidebarPreview: Bool = false) async throws {
        _ = NSApplication.shared
        let adapter = WorkspaceAdapter(windowID: "look-editor")
        let directory = try testTemporaryDirectory()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
        let json = try String(contentsOf: fixture, encoding: .utf8)
        var snapshot = try await lookValue { adapter.open(path: directory.appendingPathComponent("look.sqlite").path, json: { json }, windowsJSON: { nil }, completion: $0) }
        if snapshot.spaces.count < 2 { snapshot = try await lookValue { adapter.createSpace(name: "Second", completion: $0) } }
        snapshot = try await lookValue { adapter.setSpaceLook(id: snapshot.spaces[0].id, look: nil, completion: $0) }
        let sidebar = sidebarPreview ? SidebarView(snapshot: snapshot) : nil
        sidebar?.showSpace(at: 0)
        let preview = self.preview
        let publish: (WorkspaceSnapshot) -> Void = { snapshot in
            if let sidebar { sidebar.applySelection(snapshot: snapshot) }
            else { preview.look = snapshot.spaces[0].look }
        }
        let settings = SettingsModel(snapshot: snapshot, adapter: adapter, publish: publish, resetWidth: {}, preview: { id, look, active in
            if let sidebar { sidebar.previewLook(spaceID: id, look: look, active: active) }
            else { preview.look = look }
        })
        self.adapter = adapter
        self.directory = directory
        self.settings = settings
        self.sidebar = sidebar
        editor = LookEditorModel(settings: settings, space: snapshot.spaces[0])
        sidebar?.onLookChanged = { [preview] from, to, fraction in preview.look = fraction < 0.5 ? from : to }
    }
    func stored() async throws -> WorkspaceSnapshot { try await lookValue { adapter.snapshot(completion: $0) } }
    func writes() async throws -> Int {
        _ = try await stored()
        var database: OpaquePointer?
        let path = directory.appendingPathComponent("look.sqlite").path
        try #require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, "SELECT count(*) FROM journal WHERE kind = 'space'", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
    func close() async throws {
        _ = try await lookValue { adapter.shutdown(completion: $0) }
        try FileManager.default.removeItem(at: directory)
    }
}

@Test @MainActor
func lookCoordinatesAndTransparencyKeepArcTermsAndRoundForDisplay() {
    for x in [0.0, 0.2, 0.5, 1.0] {
        let white = LookEditorModel.color(x: x, y: 0)
        let black = LookEditorModel.color(x: x, y: 1)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)
        let color = LookEditorModel.color(x: x, y: 0.5)
        #expect(color.x == x && color.y == 0.5)
        let maximum = max(color.red, color.green, color.blue), minimum = min(color.red, color.green, color.blue)
        #expect(abs((maximum + minimum) / 2 - 0.5) < 0.000001)
        #expect(abs((maximum - minimum) - 0.65) < 0.000001)
    }
    let red = LookEditorModel.color(x: 0, y: 0.5), green = LookEditorModel.color(x: 1.0 / 3, y: 0.5), blue = LookEditorModel.color(x: 2.0 / 3, y: 0.5)
    #expect(red.red > red.green && green.green > green.blue && blue.blue > blue.red)
    #expect(LookEditorModel.color(x: 0, y: 0.5).red == LookEditorModel.color(x: 1, y: 0.5).red)
    for x in [0.0, 0.5, 1.0] {
        let top = LookEditorModel.fieldColor(x: x, y: 0), bottom = LookEditorModel.fieldColor(x: x, y: 1)
        #expect(top.y == 0.05 && abs(bottom.y - 0.95) < 0.000001)
        #expect(min(top.red, top.green, top.blue) < 1)
        #expect(max(bottom.red, bottom.green, bottom.blue) > 0)
        #expect(abs(LookEditorModel.fieldY(top.y)) < 0.000001 && abs(LookEditorModel.fieldY(bottom.y) - 1) < 0.000001)
    }
    for percent in [0.0, 10, 55.55, 90, 100] {
        #expect(abs(LookEditorModel.transparency(opacity: LookEditorModel.opacity(transparency: percent)) - percent) < 0.000001)
    }
    #expect(LookEditorModel.opacity(transparency: 0) == 1)
    #expect(LookEditorModel.opacity(transparency: 100) == 0)
    #expect(LookEditorModel.transparency(opacity: 0) == 100)
    #expect(LookEditorModel.transparency(opacity: 1) == 0)
    #expect(LookEditorModel.color(x: -1, y: 2).x == 0)
    #expect(LookEditorModel.color(x: -1, y: 2).y == 1)
}

@Test @MainActor
func lookDragPreviewsWithoutWritingAndCommitsExactlyOnce() async throws {
    let fixture = try await LookFixture(sidebarPreview: true)
    let editor = fixture.editor
    let count = try await fixture.writes()
    #expect(editor.look == LookEditorModel.defaultLook)
    #expect(try await fixture.stored().spaces[0].look == nil)
    #expect(try await fixture.writes() == count)
    editor.begin()
    editor.end()
    #expect(try await fixture.writes() == count)
    editor.moveHandle(0, dx: 0.1, dy: 0.1)
    editor.moveHandle(0, dx: 0, dy: 0)
    editor.end()
    #expect(try await fixture.writes() == count)
    #expect(fixture.preview.look == nil)
    for frame in 1...20 { editor.moveHandle(0, dx: Double(frame) / 100, dy: -0.1) }
    #expect(editor.editing)
    #expect(try await fixture.writes() == count)
    #expect(try await fixture.stored().spaces[0].look == nil)
    #expect(fixture.preview.look == editor.look)
    #expect(fixture.settings.snapshot.spaces[0].look == nil)
    let final = editor.look
    editor.end()
    editor.end()
    #expect(try await fixture.writes() == count + 1)
    #expect(try await fixture.stored().spaces[0].look == final)
    #expect(fixture.settings.snapshot.spaces[0].look == final)
    editor.moveHandle(0, dx: -0.3, dy: 0.2)
    editor.dismiss()
    #expect(editor.look == final && !editor.editing)
    #expect(fixture.preview.look == final)
    #expect(try await fixture.stored().spaces[0].look == final)
    #expect(try await fixture.writes() == count + 1)
    try await fixture.close()
}

@Test @MainActor
func lookHandleLimitsPresetsModesAndResetReachTheCore() async throws {
    let fixture = try await LookFixture()
    let model = fixture.editor
    let initial = try await fixture.writes()
    model.remove()
    #expect(try await fixture.writes() == initial)
    model.add()
    #expect(model.look.colors.count == 2 && model.selected == 1)
    #expect(abs(model.look.colors[1].x - (0.6 + 1.0 / 3)) < 0.000001)
    #expect(model.look.colors[1].y == 0.5)
    model.add()
    model.add()
    #expect(model.look.colors.count == 3)
    #expect(try await fixture.writes() == initial + 2)
    model.remove()
    model.remove()
    model.remove()
    #expect(model.look.colors.count == 1 && model.selected == 0)
    #expect(try await fixture.writes() == initial + 4)
    #expect(LookEditorModel.presets.count == 18)
    for index in 0..<18 {
        model.preset(index)
        #expect(model.look.colors.count == (index < 9 ? 1 : 2))
        #expect(try await fixture.stored().spaces[0].look?.colors == LookEditorModel.presets[index])
    }
    for mode: Appearance in [.light, .dark, .auto] {
        model.change { $0.appearance = mode }
        #expect(try await fixture.stored().spaces[0].look?.appearance == mode)
    }
    model.reset()
    #expect(try await fixture.stored().spaces[0].look == nil)
    #expect(fixture.preview.look == nil)
    #expect(model.look == LookEditorModel.defaultLook)
    try await fixture.close()
}

@Test @MainActor
func lookSlidersWriteOnReleaseAndGlassClearsWhenTransparencyMoves() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    let count = try await fixture.writes()
    editor.begin()
    for value in 0...100 { editor.setTransparency(Double(value)) }
    #expect(editor.transparencyLabel == "Transparency 100%")
    #expect(editor.look.opacity == 0)
    #expect(try await fixture.writes() == count)
    editor.end()
    #expect(try await fixture.stored().spaces[0].look?.opacity == 0)
    #expect(try await fixture.writes() == count + 1)
    editor.toggleGlass()
    #expect(try await fixture.stored().spaces[0].look?.glass == true)
    editor.toggleGlass()
    #expect(try await fixture.stored().spaces[0].look?.glass == false)
    editor.toggleGlass()
    editor.setTransparency(89.6)
    #expect(editor.transparencyLabel == "Transparency 90%")
    #expect(try await fixture.stored().spaces[0].look?.glass == false)
    let before = try await fixture.writes()
    editor.begin()
    for value in 0...10 { editor.change { $0.grain = Double(value) / 10 } }
    #expect(try await fixture.writes() == before)
    editor.end()
    #expect(try await fixture.writes() == before + 1)
    #expect(try await fixture.stored().spaces[0].look?.grain == 1)
    try await fixture.close()
}

@Test @MainActor
func lookUseForAllWritesEverySpaceAndKeepsTheSelection() async throws {
    let fixture = try await LookFixture()
    fixture.editor.preset(12)
    let before = try await fixture.stored()
    let count = try await fixture.writes()
    fixture.editor.useForAll()
    let after = try await fixture.stored()
    #expect(try await fixture.writes() == count + before.spaces.count)
    #expect(after.spaces.allSatisfy { $0.look == fixture.editor.look })
    #expect(after.shownSpaceId == before.shownSpaceId && after.selectedId == before.selectedId)
    try await fixture.close()
}

@Test @MainActor
func lookCoreErrorsAreVisibleAndRestoreTheLastPersistedLook() async throws {
    let fixture = try await LookFixture()
    fixture.editor.change { $0.grain = 2 }
    _ = try await fixture.stored()
    #expect(fixture.editor.error != nil && fixture.settings.error != nil)
    #expect(fixture.editor.look == LookEditorModel.defaultLook)
    #expect(fixture.preview.look == nil)
    try await fixture.close()
}

@Test @MainActor
func lookPopoverHostsOffscreenAndDropsAnUnfinishedGestureOnClose() async throws {
    let fixture = try await LookFixture()
    let anchor = LookPopoverAnchor(settings: fixture.settings, space: fixture.settings.snapshot.spaces[0])
    anchor.preparePopover()
    let editor = try #require(anchor.editor)
    let controller = try #require(anchor.popover.contentViewController)
    let host = controller.view
    host.layoutSubtreeIfNeeded()
    await Task.yield()
    #expect(abs(host.fittingSize.width - 288) < 1)
    #expect(!anchor.popover.isShown && host.window?.isVisible != true)
    let count = try await fixture.writes()
    editor.moveHandle(0, dx: 0.1, dy: 0)
    anchor.popoverWillClose(Notification(name: NSPopover.willCloseNotification, object: anchor.popover))
    #expect(!editor.editing)
    #expect(try await fixture.writes() == count)
    #expect(fixture.preview.look == nil)
    anchor.popover.contentViewController = nil
    try await fixture.close()
}

@Test @MainActor
func settingsPaletteInsertionBeforeOrAfterStoredIconKeepsTheNewGrapheme() {
    #expect(SettingsModel.iconDraft("😀🔬", stored: "🔬") == "😀")
    #expect(SettingsModel.iconDraft("🔬😀", stored: "🔬") == "😀")
    #expect(SettingsModel.iconDraft("👨‍👩‍👧‍👦🔬", stored: "🔬") == "👨‍👩‍👧‍👦")
    #expect(SettingsModel.iconDraft("🔬🔬", stored: "🔬") == "🔬")
    #expect(SettingsModel.iconDraft("👩‍💻😀", stored: "👩") == "😀")
}

@Test @MainActor
func selectedRowCloseKeycapResolvesAgainstTheRealHarnessMenu() throws {
    _ = NSApplication.shared
    let oldMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = oldMenu }
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "close-keycap"))
    NSApp.mainMenu = harness.makeMenu()
    let row = SidebarRowView(row: Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "row", title: "Tab", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil), selected: true, action: { _ in })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [], backing: .buffered, defer: false)
    window.contentView = row
    defer { window.contentView = nil }
    let tooltip = SidebarTooltip()
    tooltip.modifierFlags = { [] }
    var now = 0.0
    tooltip.clock = { now }
    tooltip.capture(in: row)
    tooltip.update(target: row.closeButton, point: NSPoint(x: 20, y: 20))
    now = 1.6
    tooltip.update(target: row.closeButton, point: NSPoint(x: 20, y: 20))
    #expect(tooltip.keycaps.map(\.stringValue) == ["⌘", "W"])
    #expect(!window.isVisible)
}

@Test @MainActor
func harnessLaunchOptionsAreInitializedWithoutRunningMain() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("owned.sqlite").path
    let options = HarnessOptions(checkOnly: true, headless: true, databasePath: path, fixturePath: "fixture.json")
    let harness = HarnessDelegate(adapter: WorkspaceAdapter(windowID: "options"), options: options)
    #expect(harness.options.checkOnly && harness.options.headless)
    #expect(harness.options.databasePath == path && harness.options.fixturePath == "fixture.json")
    try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
    #expect(harness.options.removeTemporaryDatabase())
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test @MainActor
func palettePickBeforeStoredIconCommitsThroughTheHostedField() async throws {
    _ = NSApplication.shared
    var committed = "🔬"
    let host = NSHostingView(rootView: SettingsField(value: "🔬", label: "Space icon", characterPalette: true) { committed = $0 })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil }
    func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
    try await waitUntil { host.layoutSubtreeIfNeeded(); return !fields(host).isEmpty }
    let field = try #require(fields(host).first)
    field.stringValue = "😀🔬"
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    try await waitUntil { committed == "😀" }
    #expect(!window.isVisible)
}

@Test @MainActor
func importedLookKeepsItsRGBAndPositionsUntilAHandleMoves() async throws {
    let fixture = try await LookFixture()
    let imported = Look(colors: [LookColor(red: 0.1, green: 0.2, blue: 0.3, x: 0.9, y: 0.8)], opacity: 0.31, grain: 0.2, glass: true, appearance: .dark)
    let snapshot = try await lookValue { fixture.adapter.setSpaceLook(id: fixture.editor.spaceID, look: imported, completion: $0) }
    fixture.settings.update(snapshot: snapshot)
    let editor = LookEditorModel(settings: fixture.settings, space: snapshot.spaces[0])
    #expect(editor.look == imported)
    editor.change { $0.appearance = .light }
    #expect(try await fixture.stored().spaces[0].look?.colors == imported.colors)
    editor.moveHandle(0, dx: -0.1, dy: -0.1)
    editor.end()
    let stored = try #require(try await fixture.stored().spaces[0].look)
    #expect(abs(stored.colors[0].x - 0.8) < 0.000001 && abs(stored.colors[0].y - 0.71) < 0.000001)
    #expect(stored.colors[0] == LookEditorModel.fieldColor(x: 0.9 - 0.1, y: LookEditorModel.fieldY(0.8) - 0.1))
    #expect(stored.opacity == imported.opacity && stored.grain == imported.grain && stored.glass == imported.glass)
    try await fixture.close()
}

@Test @MainActor
func anEarlierWriteReplyKeepsTheNextDragPreviewWithoutPersistingIt() async throws {
    let fixture = try await LookFixture()
    let editor = fixture.editor
    let initial = try await fixture.writes()
    editor.change { $0.grain = 0.3 }
    let submitted = editor.look
    editor.moveHandle(0, dx: -0.1, dy: 0.1)
    let preview = editor.look
    #expect(try await fixture.stored().spaces[0].look == submitted)
    #expect(fixture.preview.look == preview)
    #expect(try await fixture.writes() == initial + 1)
    editor.end()
    #expect(try await fixture.stored().spaces[0].look == preview)
    #expect(try await fixture.writes() == initial + 2)
    try await fixture.close()
}


@Test @MainActor
func lookOnlyPreviewKeepsRowsAndScrollPresentationAndSurvivesCommittedPublishes() async throws {
    let fixture = try await LookFixture(sidebarPreview: true)
    let sidebar = try #require(fixture.sidebar)
    let snapshot = try await fixture.stored()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { sidebar.finishScrollPresentation(); window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    let panel = SidebarPanelView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    var received: Look?
    sidebar.onLookChanged = { from, to, fraction in
        panel.updateLook(from, to, fraction: fraction)
        received = fraction < 0.5 ? from : to
    }
    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -100, wheel3: 0))
    event.timestamp = 100_000_000_000
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    let sampling = try #require(sidebar.lookSampling)
    #expect(sidebar.spaceShown == 1)
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let row = try #require(descendants(sidebar).compactMap { $0 as? SidebarRowView }.first)
    let title = try #require(descendants(row).compactMap { $0 as? NSTextField }.first)
    let dockButtons = descendants(sidebar).compactMap { $0 as? SpaceDockView }.flatMap(\.subviews)
    title.stringValue = "Preview must not reload this row"
    row.needsLayout = true
    let superview = row.superview
    let editor = LookEditorModel(settings: fixture.settings, space: snapshot.spaces[1])
    editor.begin()
    editor.change { $0.colors = [LookEditorModel.color(x: 0.2, y: 0.4)] }
    #expect(sidebar.lookSampling === sampling)
    #expect(descendants(sidebar).compactMap { $0 as? SpaceDockView }.flatMap(\.subviews).elementsEqual(dockButtons, by: { $0 === $1 }))
    #expect(row.superview === superview && row.needsLayout)
    #expect(title.stringValue == "Preview must not reload this row")
    #expect(received == editor.look)
    let color = try #require(panel.gradient.backgroundColor)
    #expect(abs(color.alpha - editor.look.opacity) < 0.000001)
    sidebar.applySelection(snapshot: snapshot)
    #expect(received == editor.look)
    editor.dismiss()
    #expect(received == snapshot.spaces[1].look)
    sidebar.applySelection(snapshot: snapshot)
    #expect(received == snapshot.spaces[1].look)
    #expect(!window.isVisible)
    try await fixture.close()
}

@Test @MainActor
func settingsTabCountExcludesPinnedRows() async throws {
    let fixture = try await LookFixture()
    let space = try #require(fixture.settings.snapshot.spaces.first)
    #expect(space.pinned.contains { $0.kind == .tab || $0.kind == .split })
    #expect(fixture.settings.tabCount(space) == space.today.filter { $0.kind == .tab || $0.kind == .split }.count)
    try await fixture.close()
}

@Test @MainActor
func submittedLookSurvivesAnOlderPublishUntilTheLatestReply() async throws {
    let fixture = try await LookFixture(sidebarPreview: true)
    let old = fixture.settings.snapshot
    fixture.editor.begin()
    fixture.editor.setTransparency(20)
    fixture.editor.end()
    let first = fixture.editor.look
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == first)
    fixture.editor.change { $0.grain = 0.8 }
    let latest = fixture.editor.look
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == latest)
    fixture.editor.dismiss()
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == latest)
    _ = try await fixture.stored()
    #expect(fixture.preview.look == latest)
    fixture.sidebar?.applySelection(snapshot: old)
    #expect(fixture.preview.look == nil)
    try await fixture.close()
}
