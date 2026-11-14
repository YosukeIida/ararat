import AppKit
import AraratKit
import Testing
@testable import AraratUI

// U27w: Settings › Websites. The engine is the source of the site rows and the core is the
// source of the seven defaults, so these tests drive a fake host for the engine calls and a real
// workspace adapter for the record, as the envelope asks (summary text, merge across profiles,
// the page's rows, reset and clear through a fake host).

@MainActor
private func websitesValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@MainActor
private final class FakeSiteSettingsHost: SiteSettingsHost {
    struct Write: Equatable {
        var profile: String
        var origin: String
        var kind: String
        var setting: SiteState.PermissionSetting?
    }

    var exceptions: [SiteException]
    var writes: [Write] = []
    var clears: [(profile: String, origin: String)] = []
    var clearResult: UInt64 = 0
    var refuses = false

    init(exceptions: [SiteException] = []) { self.exceptions = exceptions }

    func siteExceptions() -> [SiteException] { exceptions }

    func setSiteException(profile: String, origin: String, kind: String,
                          setting: SiteState.PermissionSetting?) -> Bool {
        if refuses { return false }
        writes.append(Write(profile: profile, origin: origin, kind: kind, setting: setting))
        exceptions.removeAll { $0.profile == profile && $0.origin == origin && $0.kind.rawValue == kind }
        if let setting, let parsed = SitePermissionKind(rawValue: kind) {
            exceptions.append(SiteException(profile: profile, origin: origin, kind: parsed, setting: setting))
        }
        return true
    }

    func clearSiteData(profile: String, origin: String, completion: @escaping (UInt64) -> Void) {
        clears.append((profile, origin))
        completion(clearResult)
    }
}

@MainActor
private func websitesSpace(_ id: String, title: String, profile: String, key: String) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: key, pinnedId: "\(id)-pin", todayId: "\(id)-today",
                  favoritesId: nil, archiveAfter: .hours12, profileName: profile,
                  profile: profile == "Default" ? .`default` : .named(profile), id: id, title: title,
                  icon: nil, look: nil, favorites: [], pinned: [], today: [])
}

@MainActor
private func websitesSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: "default", selectedId: nil,
                      spaces: [websitesSpace("default", title: "Work", profile: "Default", key: "default"),
                               websitesSpace("named", title: "Personal", profile: "Profile 1", key: "named")])
}

@MainActor
private func websitesModel(_ snapshot: WorkspaceSnapshot, _ adapter: WorkspaceAdapter) -> SettingsModel {
    SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                  keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
}

// W2: the rows are the union of the engine's exceptions across regular profiles, one per site and
// profile, kinds in the board's order, and the summary names the profile only when the workspace
// has more than one.
@Test @MainActor
func theSiteRowsMergeProfilesAndTheirSummaryNamesTheProfile() throws {
    _ = NSApplication.shared
    let snapshot = websitesSnapshot()
    let adapter = WorkspaceAdapter(windowID: "u27w-rows")
    let model = websitesModel(snapshot, adapter)
    let meet = "https://meet.example.com"
    let news = "https://news.example.org"
    model.siteHost = FakeSiteSettingsHost(exceptions: [
        // Deliberately out of order: the summary must print the board's kinds, not the engine's.
        SiteException(profile: "Default", origin: meet, kind: .microphone, setting: .content("allow")),
        SiteException(profile: "Default", origin: meet, kind: .camera, setting: .content("allow")),
        SiteException(profile: "Profile 1", origin: meet, kind: .camera, setting: .content("block")),
        SiteException(profile: "Default", origin: news, kind: .notifications, setting: .content("block")),
    ])
    model.refreshSiteExceptions()

    #expect(model.siteProfiles == ["Default", "Profile 1"])
    #expect(model.siteRows.count == 3)
    #expect(model.siteRows.map { "\($0.origin)|\($0.profile)" } ==
        ["\(meet)|Default", "\(meet)|Profile 1", "\(news)|Default"])
    let defaultMeet = try #require(model.siteRow(origin: meet, profile: "Default"))
    let summary = SettingsModel.siteSummary(defaultMeet, profiles: model.siteProfiles)
    #expect(summary == "Camera: Allow · Microphone: Allow · Default")
    // One profile: the same row ends at its last kind, as the board's examples do.
    #expect(SettingsModel.siteSummary(defaultMeet, profiles: ["Default"]) == "Camera: Allow · Microphone: Allow")
    let profileMeet = model.siteRow(origin: meet, profile: "Profile 1")!
    #expect(SettingsModel.siteSummary(profileMeet, profiles: model.siteProfiles) == "Camera: Block · Profile 1")
    #expect(SettingsModel.siteSummary(model.siteRow(origin: news, profile: "Default")!,
                                      profiles: model.siteProfiles) == "Notifications: Block · Default")
    // A profile the snapshot does not name still counts, so its row is never ambiguous.
    let other = SiteException(profile: "Profile 2", origin: news, kind: .sound, setting: .content("allow"))
    model.siteHost = FakeSiteSettingsHost(exceptions: [other])
    model.refreshSiteExceptions()
    #expect(model.siteProfiles == ["Default", "Profile 1", "Profile 2"])
    // A kind the engine sends but this build does not name is dropped, not drawn as a row.
    model.siteHost = FakeSiteSettingsHost(exceptions: [
        SiteException(profile: "Default", origin: news, kind: .sound, setting: .content("allow")),
    ])
    model.refreshSiteExceptions()
    #expect(model.siteRows.count == 1 && Array(model.siteRows[0].settings.keys) == [.sound])
}

// W1: the seven defaults, their built-in values, and the choices each kind's menu offers. Pop-ups
// and sound take only Allow and Block, because Chromium's registry lists no Ask for them.
@Test @MainActor
func theSevenDefaultsCarryTheBoardsValuesAndTheirOwnChoices() {
    let defaults = SiteDefaults.board
    #expect(SitePermissionKind.allCases.map { $0.title } ==
        ["Camera", "Microphone", "Location", "Notifications", "Pop-up windows", "Automatic downloads", "Sound"])
    #expect(SitePermissionKind.allCases.map { defaults.value(for: $0) } ==
        [.ask, .ask, .ask, .ask, .block, .ask, .allow])
    // W1 + review fix 2: a defaults menu offers only the values Chromium accepts as a default for
    // that kind (Allow is refused for the camera and the microphone; pop-ups and sound take no
    // Ask), while a site page's exceptions keep Ask/Allow/Block.
    #expect(SitePermissionKind.camera.choices.map(\.title) == ["Ask", "Allow", "Block"])
    #expect(SitePermissionKind.camera.defaultChoices.map(\.title) == ["Ask", "Block"])
    #expect(SitePermissionKind.microphone.defaultChoices.map(\.title) == ["Ask", "Block"])
    #expect(SitePermissionKind.location.defaultChoices.map(\.title) == ["Ask", "Allow", "Block"])
    #expect(SitePermissionKind.notifications.defaultChoices.map(\.title) == ["Ask", "Allow", "Block"])
    #expect(SitePermissionKind.popups.defaultChoices.map(\.title) == ["Allow", "Block"])
    #expect(SitePermissionKind.automaticDownloads.defaultChoices.map(\.title) == ["Ask", "Allow", "Block"])
    #expect(SitePermissionKind.sound.defaultChoices.map(\.title) == ["Allow", "Block"])
    #expect(!SitePermissionKind.camera.acceptsDefault(.allow) && SitePermissionKind.camera.acceptsDefault(.block))
    #expect(!SitePermissionKind.microphone.acceptsDefault(.allow))
    #expect(!SitePermissionKind.popups.acceptsDefault(.ask) && !SitePermissionKind.sound.acceptsDefault(.ask))
    #expect(SitePermissionKind.location.acceptsDefault(.allow) && SitePermissionKind.notifications.acceptsDefault(.allow))
    #expect(SitePermissionKind.popups.choices.map(\.title) == ["Allow", "Block"])
    #expect(SitePermissionKind.sound.choices.map(\.title) == ["Allow", "Block"])
    #expect(SitePermissionKind.notifications.builtInDefault == .ask)
    #expect(SitePermissionKind.popups.builtInDefault == .block)
    #expect(SitePermissionKind.sound.builtInDefault == .allow)
    #expect(defaults.engineRequest == [
        "media-stream-camera": "ask", "media-stream-mic": "ask", "geolocation": "ask",
        "notifications": "ask", "popups": "block", "automatic-downloads": "ask", "sound": "allow",
    ])
    // Replacing one kind leaves the other six alone.
    let changed = defaults.replacing(.notifications, with: .block)
    #expect(changed.notifications == .block && changed.camera == .ask && changed.sound == .allow)
}

// W3: the site page's rows, its Reset and its Clear go through the host in the board's order.
@Test @MainActor
func theSitePageRowsResetAndClearWriteThroughTheHost() throws {
    _ = NSApplication.shared
    let meet = "https://meet.example.com"
    let host = FakeSiteSettingsHost(exceptions: [
        SiteException(profile: "Default", origin: meet, kind: .camera, setting: .content("block")),
        SiteException(profile: "Default", origin: meet, kind: .microphone, setting: .content("allow")),
    ])
    let model = websitesModel(websitesSnapshot(), WorkspaceAdapter(windowID: "u27w-page"))
    model.siteHost = host
    model.refreshSiteExceptions()
    model.openSite(origin: meet, profile: "Default")
    #expect(model.page == .site(meet, "Default"))
    let row = try #require(model.siteRow(origin: meet, profile: "Default"))
    #expect(SitePermissionKind.allCases.filter { row.settings[$0] != nil } == [.camera, .microphone])
    #expect(model.title == "meet.example.com")
    #expect(model.subtitle == "Site settings · Default")
    #expect(model.page.searchKey == "site-\(meet)|Default")

    // One menu's choice writes that origin's exception of that kind in that profile.
    #expect(model.setSitePermission(origin: meet, profile: "Default", kind: .camera, setting: .content("ask")))
    #expect(host.writes.last == FakeSiteSettingsHost.Write(profile: "Default", origin: meet,
                                                          kind: "media-stream-camera",
                                                          setting: .content("ask")))
    #expect(model.siteRow(origin: meet, profile: "Default")?.settings[.camera]?.title == "Ask")

    // Reset removes every kind the site holds, and no kind it does not.
    host.writes.removeAll()
    model.resetSitePermissions(origin: meet, profile: "Default")
    #expect(host.writes.map(\.kind) == ["media-stream-camera", "media-stream-mic"])
    #expect(host.writes.allSatisfy { $0.setting == nil && $0.profile == "Default" && $0.origin == meet })
    #expect(model.siteRow(origin: meet, profile: "Default") == nil && model.page == .site(meet, "Default"))

    // Clear cookies and site data names the same site and profile, and reports when it finished.
    var finished = false
    model.clearSiteData(origin: meet, profile: "Default") { finished = true }
    #expect(host.clears.count == 1 && host.clears[0].origin == meet && host.clears[0].profile == "Default")
    #expect(finished)

    // A site with no exception opens the list, not a page (W4).
    model.openSite(origin: "https://none.example", profile: "Default")
    #expect(model.page == .websites)
    // A refused engine write leaves the row as the engine still reports it.
    host.refuses = true
    #expect(!model.setSitePermission(origin: meet, profile: "Default", kind: .camera, setting: .content("block")))
}

// W1/W2 end to end in the model: a default writes the core's synced record and is handed to the
// engine, a reopened window reads it back from the core, and a site row appears from the host's
// list in the pane's markers.
@Test @MainActor
func theDefaultsWriteTheCoreRecordAndThePaneDrawsTheSevenRows() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "u27w-defaults")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await websitesValue {
        adapter.open(path: directory.appendingPathComponent("websites.sqlite").path, json: { json },
                     windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = websitesModel(snapshot, adapter)
    let host = FakeSiteSettingsHost()
    model.siteHost = host
    var applied: [SiteDefaults] = []
    model.siteDefaultsApplied = { applied.append($0) }
    model.readWebsites()
    try await waitUntil { model.siteProfiles.isEmpty == false }
    #expect(model.siteDefaults == .board)

    model.setSiteDefault(.notifications, .block)
    try await waitUntil { model.siteDefaults.notifications == .block && applied.count == 1 }
    #expect(applied.last?.notifications == .block)
    let stored: SiteDefaults = try await websitesValue { adapter.siteDefaults(completion: $0) }
    #expect(stored.notifications == .block && stored.camera == .ask && stored.popups == .block)

    // A second window reads the record back from the core, as reopening Settings does.
    let reopened = websitesModel(snapshot, adapter)
    reopened.readWebsites()
    try await waitUntil { reopened.siteDefaults.notifications == .block }
    // The model refuses a default its kind cannot take before it reaches the core (which refuses
    // it too), so the menu and Chromium cannot disagree.
    let beforeRefusal = reopened.siteDefaults
    reopened.setSiteDefault(.camera, .allow)
    #expect(reopened.siteDefaults == beforeRefusal)

    // The pane draws the seven defaults with their menus, both group cards, and the empty state.
    reopened.siteHost = FakeSiteSettingsHost()
    reopened.refreshSiteExceptions()
    reopened.navigate(.websites)
    let controller = SettingsWindowController(model: reopened)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil {
        probe.layout()
        return SitePermissionKind.allCases.allSatisfy {
            probe.marker(SettingsModel.rowMarker(SettingsModel.websiteRowID($0))) != nil
                && probe.marker(SettingsModel.websiteMenuMarker($0)) != nil
        } && probe.marker(SettingsModel.websitesEmptyMarker) != nil
    }
    let rowFrames = SitePermissionKind.allCases.compactMap { probe.marker(SettingsModel.rowMarker(SettingsModel.websiteRowID($0))) }
    #expect(rowFrames.count == 7)
    #expect(zip(rowFrames, rowFrames.dropFirst()).allSatisfy { first, second in first.maxY <= second.minY + 1 }, "the board's order, top down")
    #expect(probe.marker(SettingsModel.rowMarker(SettingsModel.websitesDefaultsCardID)) != nil)
    #expect(probe.marker(SettingsModel.rowMarker(SettingsModel.websitesSitesCardID)) != nil)
    #expect(probe.siteDefaults.notifications == .block)

    // An engine exception becomes the pane's row with the summary; its id is the marker.
    let meet = "https://meet.example.com"
    reopened.siteHost = FakeSiteSettingsHost(exceptions: [
        SiteException(profile: "Default", origin: meet, kind: .camera, setting: .content("allow")),
    ])
    reopened.refreshSiteExceptions()
    try await waitUntil {
        probe.layout()
        return probe.siteRows.count == 1
    }
    let siteRow = try #require(probe.siteRows.first)
    #expect(probe.siteSummary(siteRow).hasPrefix("Camera: Allow"))
    #expect(probe.marker(SettingsModel.rowMarker(SettingsModel.websiteSiteRowID(siteRow))) != nil)
    #expect(probe.marker(SettingsModel.websitesEmptyMarker) == nil)

    // Its page: one row per exception with the menu, Reset and Clear (W3).
    probe.openSite(meet, "Default")
    try await waitUntil {
        probe.layout()
        return probe.pageID == "site-\(meet)|Default"
            && probe.marker(SettingsModel.rowMarker(SettingsModel.sitePermissionRowID(.camera))) != nil
    }
    #expect(probe.marker(SettingsModel.sitePermissionMenuMarker(.camera)) != nil)
    #expect(probe.marker(SettingsModel.rowMarker(SettingsModel.siteResetRowID)) != nil)
    #expect(probe.marker(SettingsModel.rowMarker(SettingsModel.siteClearRowID)) != nil)
    #expect(probe.title == "meet.example.com")

    _ = try await websitesValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}
