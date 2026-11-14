import AppKit
import AraratKit
import Testing
@testable import AraratUI

// U27p: Settings › Privacy. The record is the synced core's, the engine host applies it to every
// regular profile, and the clear sheet's range and types reach the host for the profile the sheet
// names. The tests drive a fake host for the engine calls and a real workspace adapter for the
// record, as the Websites and Extensions tests do.

@MainActor
private func privacyValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private final class FakePrivacyHost: PrivacySettingsHost {
    var applied: [PrivacySettings] = []
    var clears: [(profile: String, range: ClearBrowsingRange, types: ClearBrowsingTypes)] = []
    var failed: UInt64 = 0
    var calls = 0

    func applyPrivacy(_ settings: PrivacySettings) { applied.append(settings) }

    func clearBrowsingData(profile: String, range: ClearBrowsingRange, types: ClearBrowsingTypes,
                           completion: @escaping (UInt64) -> Void) {
        calls += 1
        clears.append((profile, range, types))
        completion(failed)
    }
}

@MainActor
private func privacySpace(_ id: String, title: String, profile: String) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: id, pinnedId: "\(id)-pin", todayId: "\(id)-today",
                  favoritesId: nil, archiveAfter: .hours12, profileName: profile,
                  profile: profile == "Default" ? .`default` : .named(profile), id: id, title: title,
                  icon: nil, look: nil, favorites: [], pinned: [], today: [])
}

@MainActor
private func privacySnapshot(profile: String = "Default") -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: "default", selectedId: nil,
                      spaces: [privacySpace("default", title: "Work", profile: profile)])
}

@MainActor
private func privacyModel(_ snapshot: WorkspaceSnapshot, _ adapter: WorkspaceAdapter) -> SettingsModel {
    SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                  keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
}

// P2/P3: the built-in record is the board's (Block, on, One year), the menu words are the board's,
// and the engine request names the three values.
@Test @MainActor
func thePrivacyRecordCarriesTheBoardsValuesAndTheEngineRequest() {
    #expect(PrivacySettings.board.thirdPartyCookies == .block)
    #expect(PrivacySettings.board.globalPrivacyControl)
    #expect(PrivacySettings.board.historyRetention == .year)
    #expect([ThirdPartyCookies.block, .allow].map(\.label) == ["Block", "Allow"])
    #expect([HistoryRetention.week, .month, .threeMonths, .year, .forever].map(\.label) ==
        ["One week", "One month", "Three months", "One year", "Forever"])
    #expect([HistoryRetention.week, .month, .threeMonths, .year, .forever].map(\.days) == [7, 30, 90, 365, nil])
    let request = PrivacySettings.board.engineRequest
    #expect(request["cookies"] as? String == "block")
    #expect(request["gpc"] as? Bool == true)
    #expect(request["history_days"] as? Int == 365)
    var forever = PrivacySettings.board
    forever.historyRetention = .forever
    #expect(forever.engineRequest["history_days"] as? Int == 0)
    // P4's range: the four bounded choices and All time's nil start.
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(ClearBrowsingRange.allCases.map(\.title) ==
        ["Last hour", "Last 24 hours", "Last 7 days", "Last 4 weeks", "All time"])
    #expect(ClearBrowsingRange.lastHour.start(now: now) == now.addingTimeInterval(-3600))
    #expect(ClearBrowsingRange.last4Weeks.start(now: now) == now.addingTimeInterval(-28 * 86400))
    #expect(ClearBrowsingRange.allTime.start(now: now) == nil)
    #expect(ClearBrowsingTypes.all.rawValue == 7 && ClearBrowsingTypes.ordered.map(\.1) ==
        ["History", "Cookies and other site data", "Cached images and files"])
}

// P2/P3 end to end in the model: a write goes to the core's synced record and to the host, a
// reopened window reads it back from the core, and the pane draws its four rows with no
// Protection card (P1).
@Test @MainActor
func thePrivacyRowsWriteTheCoreRecordAndTheHostAppliesIt() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "u27p-record")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await privacyValue {
        adapter.open(path: directory.appendingPathComponent("privacy.sqlite").path, json: { json },
                     windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = privacyModel(snapshot, adapter)
    let host = FakePrivacyHost()
    model.privacyHost = host
    model.readPrivacy(shownSpaceID: snapshot.shownSpaceId)
    try await waitUntil { model.privacyLoaded }
    #expect(model.privacy == .board)
    #expect(model.privacyProfile == "Default")
    // R2-3: a reread clears the flag while it is in flight and sets it again on the answer, so a
    // caller can never compare the model's initial value with a core value.
    model.readPrivacy(shownSpaceID: snapshot.shownSpaceId)
    #expect(!model.privacyLoaded)
    try await waitUntil { model.privacyLoaded }

    model.setThirdPartyCookies(.allow)
    try await waitUntil { host.applied.count == 1 }
    #expect(host.applied.last?.thirdPartyCookies == .allow)
    model.setGlobalPrivacyControl(false)
    try await waitUntil { host.applied.count == 2 }
    model.setHistoryRetention(.week)
    try await waitUntil { host.applied.count == 3 }
    #expect(host.applied.last == PrivacySettings(thirdPartyCookies: .allow, globalPrivacyControl: false,
                                                 historyRetention: .week))
    let stored: PrivacySettings = try await privacyValue { adapter.privacySettings(completion: $0) }
    #expect(stored == host.applied.last)

    // A second window reads the record back from the core, as reopening Settings does.
    let reopened = privacyModel(snapshot, adapter)
    reopened.readPrivacy(shownSpaceID: snapshot.shownSpaceId)
    try await waitUntil { reopened.privacy.thirdPartyCookies == .allow }
    #expect(reopened.privacy.historyRetention == .week && reopened.privacy.globalPrivacyControl == false)

    // The pane draws the four rows and their controls; the Protection card is absent (P1).
    reopened.privacyHost = host
    reopened.navigate(.privacy)
    let controller = SettingsWindowController(model: reopened)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    let rows = [SettingsModel.privacyClearRowID, SettingsModel.privacyCookiesRowID,
                SettingsModel.privacyGPCRowID, SettingsModel.privacyHistoryRowID]
    try await waitUntil {
        probe.layout()
        return rows.allSatisfy { probe.marker(SettingsModel.rowMarker($0)) != nil }
    }
    #expect(probe.marker(SettingsModel.privacyClearButtonMarker) != nil)
    #expect(probe.marker(SettingsModel.privacyCookiesMenuMarker) != nil)
    #expect(probe.marker(SettingsModel.privacyGPCSwitchMarker) != nil)
    #expect(probe.marker(SettingsModel.privacyHistoryMenuMarker) != nil)
    #expect(probe.marker(SettingsModel.rowMarker("privacy-protection")) == nil)
    #expect(probe.title == "Privacy" && probe.subtitle == "What Ararat keeps and what sites can see.")
    // The registry's search rows carry the pane's words and the stored values.
    let searchRows = SettingsRegistry.privacyRows(reopened)
    #expect(searchRows.map(\.title) == ["Clear browsing data", "Third-party cookies",
                                        "Ask sites not to sell or share my data", "Keep history for"])
    #expect(searchRows[1].subtitle == "For every site · Allow")
    #expect(searchRows[3].subtitle == "One week")
}

// P4: the sheet names the profile of the window that opened Settings and sends exactly the range
// and types chosen; a sheet with no type checked sends nothing.
@Test @MainActor
func theClearSheetMapsTheRangeAndTypesToTheRequest() async throws {
    _ = NSApplication.shared
    let adapter = WorkspaceAdapter(windowID: "u27p-sheet")
    let snapshot = privacySnapshot(profile: "Profile 1")
    let model = privacyModel(snapshot, adapter)
    let host = FakePrivacyHost()
    model.privacyHost = host
    model.readPrivacy(shownSpaceID: "default")
    #expect(model.privacyProfile == "Profile 1")

    model.openClearSheet()
    #expect(model.clearSheetShown)
    // The sheet's defaults: Last hour with all three types, then a narrower choice.
    #expect(model.clearRange == .lastHour && model.clearTypes == .all)
    model.clearRange = .last7Days
    model.clearTypes = [.history, .cookies]
    model.confirmClearSheet()
    #expect(host.clears.count == 1)
    #expect(host.clears.first?.profile == "Profile 1")
    #expect(host.clears.first?.range == .last7Days)
    #expect(host.clears.first?.types == [.history, .cookies])
    #expect(!model.clearSheetShown && !model.clearing)

    // Nothing checked: Clear does nothing and the sheet stays open.
    model.openClearSheet()
    model.clearTypes = []
    model.confirmClearSheet()
    #expect(host.clears.count == 1 && model.clearSheetShown)

    // A failed type bitmask reaches the pane's error line; the sheet has already closed.
    model.clearTypes = .all
    host.failed = 1
    model.confirmClearSheet()
    #expect(host.clears.count == 2)
    #expect(model.error == "Some data could not be cleared.")
    #expect(!model.clearSheetShown)

    // Cancel closes the sheet without touching the host.
    model.openClearSheet()
    model.cancelClearSheet()
    #expect(!model.clearSheetShown && host.clears.count == 2)
}
