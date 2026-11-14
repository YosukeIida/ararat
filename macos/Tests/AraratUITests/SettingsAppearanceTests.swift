import AppKit
import AraratKit
import Testing
@testable import AraratUI

// U27d: the Appearance pane's two switches write the workspace's synced settings record (the
// New Tab row's own record, D5, and the new Tooltips one, D4), the reopened window reads them
// back, and the pane's Look row pushes the shown space's page.
@MainActor
private func settingsAppearanceValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private func settingsAppearanceSpace(_ id: String, title: String, today: [Row] = []) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: UInt32(today.count), profileKey: "default", pinnedId: "\(id)-pin",
                  todayId: "\(id)-today", favoritesId: "\(id)-fav", archiveAfter: .hours12, profileName: "Default",
                  profile: .`default`, id: id, title: title, icon: nil, look: nil, favorites: [], pinned: [], today: today)
}

@Test @MainActor
func theAppearancePaneWritesBothSwitchesAndReopenReadsThem() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "u27d-appearance")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await settingsAppearanceValue {
        adapter.open(path: directory.appendingPathComponent("appearance.sqlite").path, json: { json },
                     windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    var rows: [Bool] = []
    var tips: [Bool] = []
    model.newTabRow = { rows.append($0) }
    model.tooltips = { tips.append($0) }
    // The pane's rows, in the board's order, and the search finds each one under Appearance.
    #expect(model.rows.filter { $0.pane == .appearance }.map(\.id) ==
        [SettingsModel.themeRowId, SettingsModel.lookRowId, SettingsModel.newTabRowId, SettingsModel.tooltipsRowId])
    #expect(model.rows.filter { $0.pane == .appearance }.map(\.title) == ["Theme", "Look", "New Tab row", "Tooltips"])
    model.query = "tooltips"
    #expect(model.resultGroups.map { $0.pane.id.rawValue } == ["appearance"]
        && model.results.map(\.id) == [SettingsModel.tooltipsRowId])
    model.query = ""
    #expect(model.newTabRowShown && model.tooltipsShown)

    model.setNewTabRowShown(false)
    try await waitUntil { model.newTabRowShown == false && !rows.isEmpty }
    #expect(rows == [false])
    model.setTooltipsShown(false)
    try await waitUntil { model.tooltipsShown == false && !tips.isEmpty }
    #expect(tips == [false])
    // The writes reached the core, not only the model.
    let storedRow: Bool = try await settingsAppearanceValue { adapter.newTabRowShown(completion: $0) }
    let storedTips: Bool = try await settingsAppearanceValue { adapter.tooltipsShown(completion: $0) }
    #expect(storedRow == false && storedTips == false)

    // A second window's model on the same workspace reads both values back on open.
    let reopened = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                                 keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    reopened.readAppearance()
    try await waitUntil { reopened.newTabRowShown == false && reopened.tooltipsShown == false }

    // The pane draws the board's rows: the Theme card, the Look link, then the Sidebar card's
    // two switches.
    reopened.navigate(.appearance)
    let controller = SettingsWindowController(model: reopened)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil {
        probe.layout()
        return [SettingsModel.themeRowId, SettingsModel.lookRowId, SettingsModel.newTabRowId, SettingsModel.tooltipsRowId]
            .allSatisfy { probe.marker(SettingsModel.rowMarker($0)) != nil }
            && probe.marker(SettingsModel.themeControlMarker) != nil
            && probe.marker(SettingsModel.newTabRowSwitchMarker) != nil
            && probe.marker(SettingsModel.tooltipsSwitchMarker) != nil
    }
    let themeRow = try #require(probe.marker(SettingsModel.rowMarker(SettingsModel.themeRowId)))
    let look = try #require(probe.marker(SettingsModel.rowMarker(SettingsModel.lookRowId)))
    let row = try #require(probe.marker(SettingsModel.rowMarker(SettingsModel.newTabRowId)))
    let tipsRow = try #require(probe.marker(SettingsModel.rowMarker(SettingsModel.tooltipsRowId)))
    #expect(themeRow.maxY <= look.minY + 1 && look.maxY <= row.minY + 1 && row.maxY <= tipsRow.minY + 1,
            "the board's order, top down")
    #expect((probe.marker(SettingsModel.themeControlMarker)?.height ?? 0) >= 16)
    #expect((probe.marker(SettingsModel.newTabRowSwitchMarker)?.height ?? 0) >= 16)
    #expect(probe.newTabRowShown == false && probe.tooltipsShown == false)

    // The Look row opens the shown space's page in Spaces, where the Look card's popover is.
    let shownSpace = try #require(snapshot.shownSpaceId)
    probe.openLook()
    try await waitUntil { probe.pageID == "space-\(shownSpace)" }
    #expect(probe.highlightedRowID == SettingsModel.lookRowId)

    _ = try await settingsAppearanceValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

// U27k: the Theme writes the shared synced record, the app applies it, a reopened pane reads it
// back from the core, and a Look whose mode is Auto takes its text from the resolved appearance.
@Test @MainActor
func theThemeWritesTheSyncedRecordAndSetsTheWholeAppearance() async throws {
    _ = NSApplication.shared
    defer { NSApp.appearance = nil }
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "u27k-theme")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await settingsAppearanceValue {
        adapter.open(path: directory.appendingPathComponent("theme.sqlite").path, json: { json },
                     windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    var applied: [Theme] = []
    model.themeApplied = { applied.append($0) }
    // System by default, the pane's first row, and the row names the choice.
    #expect(model.theme == .system)
    #expect(model.rows.filter { $0.pane == .appearance }.first?.id == SettingsModel.themeRowId)
    #expect(model.rows.filter { $0.pane == .appearance }.first?.subtitle.contains("System") == true)

    // Each value in AppKit's terms: System leaves the app to the Mac, Light and Dark force one.
    #expect(Theme.system.appearance == nil)
    #expect(Theme.light.appearance?.name == .aqua)
    #expect(Theme.dark.appearance?.name == .darkAqua)
    // What the app does with a written value: every window inherits it.
    NSApp.appearance = Theme.dark.appearance
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [], backing: .buffered, defer: false)
    defer { window.contentView = nil }
    #expect(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

    // A space's Look still colours only the sidebar; an Auto look takes its text from the
    // resolved appearance. A 10 % grey over the dark window is dark enough for light text, the
    // same value over the light window dark enough for dark text.
    let panel = SidebarPanelView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    panel.reduceTransparency = { false }
    let content = NSView()
    panel.addSubview(content)
    let auto = Look(colors: [LookColor(red: 0.45, green: 0.45, blue: 0.45, x: 0.5, y: 0.5)],
                    opacity: 0.1, grain: 0, glass: false, appearance: .auto)
    panel.updateLook(auto, auto, fraction: 0)
    #expect(content.appearance?.name == .darkAqua)
    NSApp.appearance = Theme.light.appearance
    panel.updateLook(auto, auto, fraction: 0)
    #expect(content.appearance?.name == .aqua)
    NSApp.appearance = nil

    // The write reached the core, not only the model.
    model.setTheme(.dark)
    try await waitUntil { model.theme == .dark && applied == [.dark] }
    let storedDark: Theme = try await settingsAppearanceValue { adapter.theme(completion: $0) }
    #expect(storedDark == .dark)
    #expect(model.rows.filter { $0.pane == .appearance }.first?.subtitle.contains("Dark") == true)

    // A second window's model on the same workspace reads the stored value on open.
    let reopened = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                                 keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    reopened.readAppearance()
    try await waitUntil { reopened.theme == .dark }

    model.setTheme(.light)
    try await waitUntil { model.theme == .light && applied == [.dark, .light] }
    model.setTheme(.system)
    try await waitUntil { model.theme == .system && applied == [.dark, .light, .system] }
    let stored: Theme = try await settingsAppearanceValue { adapter.theme(completion: $0) }
    #expect(stored == .system)

    _ = try await settingsAppearanceValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

@Test @MainActor
func theTooltipGateSilencesHeaderAndNativeTooltipsUntilItIsTurnedBackOn() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: false)
    defer { window.contentView = nil }
    let button = NSButton(title: "Back", target: nil, action: nil)
    button.toolTip = "Go Back"
    window.contentView?.addSubview(button)
    let tooltip = SidebarTooltip()
    var now = 0.0
    tooltip.clock = { now }
    tooltip.modifierFlags = { [] }
    tooltip.capture(in: button)
    tooltip.update(target: button, point: .zero)
    now = 2
    tooltip.update(target: button, point: .zero)
    #expect(tooltip.text == "Go Back")
    // Off: a shown tooltip goes, and a native toolTip set after capture is still stripped into
    // the map (so AppKit cannot draw its own) while nothing is shown. A row's mute or close
    // button sets its toolTip the same way.
    tooltip.isEnabled = false
    #expect(tooltip.text == nil)
    button.toolTip = "Mute Tab"
    tooltip.update(target: button, point: .zero)
    #expect(tooltip.text == nil)
    #expect(tooltip.target(at: button) === button)
    #expect(button.toolTip == nil)
    #expect(tooltip.text == nil)
    // Back on, the stripped text is what the same hover shows.
    tooltip.isEnabled = true
    now = 4
    tooltip.update(target: button, point: .zero)
    #expect(tooltip.text == "Mute Tab")

    // The header's own gate: the Back control's tooltip with its keycaps, gone when off.
    let header = SidebarHeaderView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    window.contentView?.addSubview(header)
    header.layoutSubtreeIfNeeded()
    let on = header.checkTooltip("back")
    #expect(on.0 == "Go Back" && on.1 == ["⌘", "["])
    header.tooltipsShown = false
    let off = header.checkTooltip("back")
    #expect(off.0 == nil)
    header.tooltipsShown = true
    #expect(header.checkTooltip("back").0 == "Go Back")
}

@Test @MainActor
func hidingTheNewTabRowFromThePaneClosesTheTodayRowsUpByFortyOne() throws {
    _ = NSApplication.shared
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "a", title: "A",
                  url: "https://a.example", depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let space = settingsAppearanceSpace("work", title: "Work", today: [row])
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space]))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 700)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    let before = try #require(sidebar.checkRowFrame("a")).minY
    #expect(sidebar.newTabRowForCheck != nil)
    // What the pane's switch writes reaches the sidebar as this value (U27d).
    sidebar.newTabRowShown = false
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.newTabRowForCheck == nil)
    let after = try #require(sidebar.checkRowFrame("a")).minY
    #expect(abs((before - after) - SidebarMetrics.newTabRowHeight) < 0.5, "before \(before) after \(after)")
    #expect(SidebarMetrics.newTabRowHeight == 41)
}
