import AppKit
import AraratKit
import Testing
@testable import AraratUI

// P5b: Settings › General. The default-browser row reads LaunchServices' answer through a seam and
// asks its setter, When Ararat opens and the downloads pair are the synced core record, and the
// downloads record reaches the app's engine handler. The tests drive fakes for the browser status
// and setter, a real workspace adapter for the record, and the pane through the check probe.

@MainActor
private func generalValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

private final class FakeDefaultBrowser: DefaultBrowserStatus, DefaultBrowserSetter {
    var isDefault = false
    var calls = 0
    func requestDefaultBrowser() { calls += 1; isDefault = true }
    func isDefaultBrowser() -> Bool { isDefault }
}

@MainActor
private func generalSpace(_ id: String, title: String) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: id, pinnedId: "\(id)-pin", todayId: "\(id)-today",
                  favoritesId: nil, archiveAfter: .hours12, profileName: "Default",
                  profile: .`default`, id: id, title: title, icon: nil, look: nil,
                  favorites: [], pinned: [], today: [])
}

@MainActor
private func generalSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: "default", selectedId: nil,
                      spaces: [generalSpace("default", title: "Work")])
}

@MainActor
private func generalModel(_ snapshot: WorkspaceSnapshot, _ adapter: WorkspaceAdapter) -> SettingsModel {
    SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                  keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
}

// The built-in record: Restore, Chromium's Downloads folder, no prompt; the folder's own name.
@Test @MainActor
func theGeneralRecordsStartAtTheBoardsValues() {
    #expect(DownloadDevice.board == DownloadDevice(directory: "", askWhereToSave: false))
    #expect(DownloadDevice.board.folderName == "Downloads")
    #expect(DownloadDevice(directory: "/Users/someone/Desktop", askWhereToSave: true).folderName == "Desktop")
    // A folder with a trailing slash still names the folder, and a path with no last component
    // keeps the path rather than reading as the default.
    #expect(DownloadDevice(directory: "/Users/someone/Desktop/", askWhereToSave: false).folderName == "Desktop")
    // The board's two startup choices, in the pane's order and words.
    #expect(SettingsModel.startupLabel(.restoreWindows) == "Restore windows and tabs")
    #expect(SettingsModel.startupLabel(.newWindow) == "Open a new window")
}

@Test @MainActor
func theLaunchPlanAdoptsOrDiscardsTheKeptRecords() {
    let presentation = WindowPresentation(frame: nil, sidebarWidth: nil, sidebarHidden: false)
    let kept = [
        KeptWindow(id: "newest", changedAt: 300, presentation: presentation, shownSpace: "space-personal"),
        KeptWindow(id: "older", changedAt: 200, presentation: presentation, shownSpace: "space-work"),
        KeptWindow(id: "oldest", changedAt: 100, presentation: presentation, shownSpace: "space-work"),
    ]
    let restore = LaunchPlan.forLaunch(startup: .restoreWindows, kept: kept, openIDs: [], reopening: false)
    #expect(restore.adopted?.id == "oldest")
    #expect(restore.restores == Array(kept.reversed()))
    #expect(!restore.discardsKept && restore.shownSpace == nil)

    let reopen = LaunchPlan.forLaunch(startup: .newWindow, kept: kept, openIDs: ["newest"], reopening: true)
    #expect(reopen.adopted?.id == "older")
    #expect(reopen.restores.isEmpty && !reopen.discardsKept)
    let allOpen = LaunchPlan.forLaunch(startup: .restoreWindows, kept: kept, openIDs: Set(kept.map(\.id)), reopening: true)
    #expect(allOpen.adopted == nil && allOpen.restores.isEmpty)

    let fresh = LaunchPlan.forLaunch(startup: .newWindow, kept: kept, openIDs: [], reopening: false)
    #expect(fresh.adopted == nil && fresh.discardsKept && fresh.restores.isEmpty)
    #expect(fresh.shownSpace == "space-personal")
    let none = LaunchPlan.forLaunch(startup: .newWindow, kept: [], openIDs: [], reopening: false)
    #expect(none.adopted == nil && none.discardsKept && none.shownSpace == nil && none.restores.isEmpty)
    let emptyRestore = LaunchPlan.forLaunch(startup: .restoreWindows, kept: [], openIDs: [], reopening: false)
    #expect(emptyRestore.adopted == nil && !emptyRestore.discardsKept && emptyRestore.restores.isEmpty)
}

// The row's two faces and the status refresh: Make Default asks the setter and never the system,
// and the status the app reads on activation turns the row into its sentence.
@Test @MainActor
func makeDefaultAsksTheSetterAndTheStatusTurnsTheRowIntoItsSentence() {
    _ = NSApplication.shared
    let adapter = WorkspaceAdapter(windowID: "p5b-default")
    let model = generalModel(generalSnapshot(), adapter)
    let fake = FakeDefaultBrowser()
    model.defaultBrowserStatus = fake
    model.defaultBrowserSetter = fake
    model.readGeneral()
    #expect(!model.defaultBrowserIsDefault)
    model.makeDefaultBrowser()
    #expect(fake.calls == 1)
    // macOS answers when it likes; the model does not guess, so the row still offers the button
    // until the app reads the status again.
    #expect(!model.defaultBrowserIsDefault)
    model.refreshDefaultBrowser()
    #expect(model.defaultBrowserIsDefault)
}

// When Ararat opens end to end in the model: a write goes to the core's synced record, a reopened
// window reads it back, and the downloads pair reaches the app's engine handler with the folder.
@Test @MainActor
func theGeneralRowsWriteTheCoreRecordAndReachTheEngineHandler() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "p5b-record")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await generalValue {
        adapter.open(path: directory.appendingPathComponent("general.sqlite").path, json: { json },
                     windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = generalModel(snapshot, adapter)
    let fake = FakeDefaultBrowser()
    model.defaultBrowserStatus = fake
    model.defaultBrowserSetter = fake
    var applied: [DownloadDevice] = []
    model.downloadsApplied = { applied.append($0) }
    model.readGeneral()
    try await waitUntil { model.generalLoaded }
    #expect(model.startup == .restoreWindows)
    #expect(model.downloads == .board)

    // A reread clears the flag while it is in flight, so a caller can never read the model's
    // initial value as the stored one.
    model.readGeneral()
    #expect(!model.generalLoaded)
    try await waitUntil { model.generalLoaded }

    model.setStartup(.newWindow)
    try await waitUntil { model.startup == .newWindow }
    let storedSettings: WorkspaceSettings = try await generalValue { adapter.generalWorkspaceSettings(completion: $0) }
    #expect(storedSettings.startup == .newWindow)

    model.setDownloadDirectory(URL(fileURLWithPath: "/Users/someone/Desktop"))
    try await waitUntil { applied.count == 1 }
    #expect(applied.last == DownloadDevice(directory: "/Users/someone/Desktop", askWhereToSave: false))
    #expect(model.downloadFolderName == "Desktop")
    model.setAskWhereToSave(true)
    try await waitUntil { applied.count == 2 }
    #expect(applied.last == DownloadDevice(directory: "/Users/someone/Desktop", askWhereToSave: true))
    let stored: DownloadDevice = try await generalValue { adapter.downloadDevice(completion: $0) }
    #expect(stored == applied.last)

    // A second window reads both records back from the core, as reopening Settings does.
    let reopened = generalModel(snapshot, adapter)
    reopened.readGeneral()
    try await waitUntil { reopened.generalLoaded }
    #expect(reopened.startup == .newWindow && reopened.downloads == stored)

    // A relative folder never reaches the core, so the pane shows the reason rather than a folder
    // Chromium could not save into.
    reopened.setDownloadDirectory(try #require(URL(string: "Desktop")))
    try await waitUntil { reopened.error != nil }
    let unchanged: DownloadDevice = try await generalValue { adapter.downloadDevice(completion: $0) }
    #expect(unchanged == stored)
}

// The pane draws its three E-General rows and their controls, and the registry's search carries
// the same ids and the stored values (the engine-backed downloads rows included).
@Test @MainActor
func theGeneralPaneDrawsItsRowsAndTheSearchCarriesThem() async throws {
    _ = NSApplication.shared
    let adapter = WorkspaceAdapter(windowID: "p5b-pane")
    let directory = try testTemporaryDirectory()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await generalValue {
        adapter.open(path: directory.appendingPathComponent("general-pane.sqlite").path, json: { json },
                     windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = generalModel(snapshot, adapter)
    model.defaultBrowserStatus = FakeDefaultBrowser()
    model.downloadsApplied = { _ in }
    model.navigate(.general)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    let rows = [SettingsModel.defaultBrowserRowID, SettingsModel.startupRowID,
                SettingsModel.warnBeforeQuittingRowID, SettingsModel.searchSuggestionsRowID, SettingsModel.downloadsFolderRowID, SettingsModel.downloadsAskRowID]
    try await waitUntil {
        probe.layout()
        return rows.allSatisfy { probe.marker(SettingsModel.rowMarker($0)) != nil }
    }
    #expect(probe.marker(SettingsModel.makeDefaultButtonMarker) != nil)
    #expect(probe.marker(SettingsModel.startupMenuMarker) != nil)
    #expect(probe.marker(SettingsModel.downloadsFolderMarker) != nil)
    #expect(probe.marker(SettingsModel.downloadsChooseButtonMarker) != nil)
    #expect(probe.marker(SettingsModel.downloadsAskSwitchMarker) != nil)
    #expect(probe.title == "General" && probe.subtitle == "The browser, what opens at launch, and downloads.")
    // The rail puts General first, before Appearance.
    #expect(probe.railPanes.first?.id == "general")
    let searchRows = SettingsRegistry.generalRows(model)
    #expect(searchRows.map(\.title) == ["Default browser", "When Ararat opens", "Warn before quitting",
                                        "Show search suggestions", "Save downloads to", "Ask where to save each file"])
    #expect(searchRows[1].subtitle == "Restore windows and tabs")
    #expect(searchRows[2].subtitle == "On")
    #expect(searchRows[3].subtitle == "On")
    #expect(searchRows[4].subtitle == "Downloads")
    #expect(searchRows[5].subtitle == "Off")
    model.setWarnBeforeQuitting(false)
    try await waitUntil { !model.warnBeforeQuitting }
    model.readGeneral()
    try await waitUntil { model.generalLoaded }
    #expect(!model.warnBeforeQuitting)
}
