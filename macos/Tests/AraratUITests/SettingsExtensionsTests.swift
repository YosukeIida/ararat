import AppKit
import AraratKit
import Testing
@testable import AraratUI

// U27x: Settings › Extensions. The engine is the source of the rows (X2, X3) and the registry
// observer is its change signal (X5), so these tests drive a fake host for the engine calls, as
// the envelope asks: the summary text per state, disabled and needs-review rows, the menu items,
// profile switching, and the writes read back from the host.

@MainActor
private final class FakeExtensionSettingsHost: ExtensionSettingsHost {
    struct Write: Equatable {
        var profile: String
        var identifier: String
        var value: String
    }

    var rowsByProfile: [String: [SettingsExtension]]
    var writes: [Write] = []
    var reviews: [String] = []
    var removals: [String] = []
    var handler: (() -> Void)?
    var refuses = false
    var loadingProfiles: Set<String> = []
    var reviewResult = true
    var uninstallResult = ""

    func uninstall(profile: String, identifier: String) -> String {
        removals.append(identifier)
        if uninstallResult.isEmpty {
            rowsByProfile[profile]?.removeAll { $0.id == identifier }
        }
        return uninstallResult
    }

    init(rowsByProfile: [String: [SettingsExtension]]) {
        self.rowsByProfile = rowsByProfile
    }

    func extensions(profile: String) -> ExtensionProfileList {
        if loadingProfiles.contains(profile) { return .loading }
        return ExtensionProfileList(loading: false, rows: rowsByProfile[profile] ?? [])
    }

    private func update(_ profile: String, _ identifier: String, _ change: (inout SettingsExtension) -> Void) -> String {
        if refuses { return "unknown" }
        guard var rows = rowsByProfile[profile], let index = rows.firstIndex(where: { $0.id == identifier }) else {
            return "unknown"
        }
        change(&rows[index])
        rowsByProfile[profile] = rows
        return "done"
    }

    func setEnabled(profile: String, identifier: String, enabled: Bool) -> String {
        writes.append(Write(profile: profile, identifier: identifier, value: "enabled=\(enabled)"))
        // X2 (design): an extension Chromium does not let the user switch offers no switch.
        guard rowsByProfile[profile]?.first(where: { $0.id == identifier })?.canDisable == true else {
            return refuses ? "unknown" : "policy"
        }
        // X3: Chromium disables an extension for a permissions increase; only the prompt may
        // enable it again, so the plain switch answers "review".
        if enabled, rowsByProfile[profile]?.first(where: { $0.id == identifier })?.needsReview == true {
            return "review"
        }
        return update(profile, identifier) { $0.enabled = enabled; $0.needsReview = false }
    }

    func setSiteAccess(profile: String, identifier: String, access: ExtensionSiteAccess) -> String {
        writes.append(Write(profile: profile, identifier: identifier, value: access.rawValue))
        return update(profile, identifier) { $0.siteAccess = access }
    }

    func setPinned(profile: String, identifier: String, pinned: Bool) -> String {
        writes.append(Write(profile: profile, identifier: identifier, value: "pinned=\(pinned)"))
        return update(profile, identifier) { $0.pinned = pinned }
    }

    func review(profile: String, identifier: String, window: NSWindow?,
                completion: @escaping (Bool) -> Void) {
        reviews.append(identifier)
        if reviewResult {
            _ = update(profile, identifier) { $0.enabled = true; $0.needsReview = false }
        }
        completion(reviewResult)
    }

    func setChangeHandler(_ handler: (() -> Void)?) { self.handler = handler }

    /// Simulates an install elsewhere: the engine's observer calls the model's refresh (X5).
    func change(_ profile: String, to rows: [SettingsExtension]) {
        rowsByProfile[profile] = rows
        handler?()
    }
}

@MainActor
private func extensionSpace(_ id: String, title: String, profile: String) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: profile == "Default" ? "default" : "named",
                  pinnedId: "\(id)-pin", todayId: "\(id)-today", favoritesId: nil,
                  archiveAfter: .hours12, profileName: profile,
                  profile: profile == "Default" ? .default : .named(profile),
                  id: id, title: title, icon: nil, look: nil, favorites: [], pinned: [], today: [])
}

@MainActor
private func extensionSnapshot() -> WorkspaceSnapshot {
    WorkspaceSnapshot(archive: [], shownSpaceId: "default", selectedId: nil,
                      spaces: [extensionSpace("default", title: "Work", profile: "Default"),
                               extensionSpace("named", title: "Personal", profile: "Profile 1")])
}

@MainActor
private func extensionModel(_ snapshot: WorkspaceSnapshot) -> SettingsModel {
    let adapter = WorkspaceAdapter(windowID: "u27x")
    return SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                         keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
}

private func aRow(_ id: String, name: String = "Ararat windows check", enabled: Bool = true,
                  needsReview: Bool = false, siteAccess: ExtensionSiteAccess = .onAllSites,
                  pinned: Bool = false, canPin: Bool = true, canDisable: Bool = true,
                  removable: Bool = true) -> SettingsExtension {
    SettingsExtension(id: id, name: name, enabled: enabled, needsReview: needsReview,
                      siteAccess: siteAccess, pinned: pinned, canPin: canPin,
                      canDisable: canDisable, removable: removable)
}

// X2/X3: the row's second line is "Needs new permissions" for a permissions increase, "Off" for a
// disabled extension and the site access otherwise; the row draws its name's letter without one.
@Test @MainActor
func theExtensionRowSummaryFollowsChromiumsStates() {
    #expect(aRow("a").summary == "On all sites")
    #expect(aRow("a", siteAccess: .onClick).summary == "On click")
    #expect(aRow("a", siteAccess: .onSpecificSites).summary == "On specific sites")
    #expect(aRow("a", enabled: false, siteAccess: .onClick).summary == "Off")
    #expect(aRow("a", enabled: false, needsReview: true, siteAccess: .onClick).summary == "Needs new permissions")
    #expect(aRow("a", name: "uBlock Origin Lite").letter == "U")
    #expect(aRow("a", name: "").letter == "?")
    // An extension that requests no site access has no second line and no site menu.
    #expect(aRow("a", siteAccess: .noSiteAccess).summary.isEmpty)
    #expect(aRow("a", enabled: false, siteAccess: .noSiteAccess).summary == "Off")
    #expect(ExtensionSiteAccess.writable.map(\.title) == ["On all sites", "On click"])
    // The raw values are the engine's words.
    #expect(ExtensionSiteAccess.allCases.map(\.rawValue) == ["none", "all", "specific", "click"])
}

// X2: the … menu offers the writable site access, the pin the action allows, Manage Extension and
// Remove… only when Chromium allows the removal; a specific-sites state appears as the current one.
@Test @MainActor
func theExtensionMenuFollowsTheRowsCapabilities() {
    let pinned = SettingsModel.extensionMenu(aRow("a", pinned: true))
    #expect(pinned == [.siteAccess(.onAllSites), .siteAccess(.onClick), .separator, .unpin,
                       .manage, .separator, .remove])
    #expect(pinned.map(\.title) == ["On all sites", "On click", "", "Unpin from Sidebar",
                                    "Manage Extension", "", "Remove…"])
    let unpinned = SettingsModel.extensionMenu(aRow("a", canPin: false, removable: false))
    #expect(unpinned == [.siteAccess(.onAllSites), .siteAccess(.onClick), .separator, .manage])
    let specific = SettingsModel.extensionMenu(aRow("a", siteAccess: .onSpecificSites))
    #expect(specific.prefix(3) == [.siteAccess(.onAllSites), .siteAccess(.onClick), .siteAccess(.onSpecificSites)])
    // An extension with no site access offers none: the menu starts at the pin.
    let none = SettingsModel.extensionMenu(aRow("a", siteAccess: .noSiteAccess))
    #expect(none == [.pin, .manage, .separator, .remove])
}

// X1: the chooser lists the regular profiles the workspace names, starts on the profile of the
// window that opened Settings, and switching profiles switches the rows.
@Test @MainActor
func theChooserStartsOnTheWindowProfileAndSwitchesLists() {
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: [
        "Default": [aRow("windows", name: "Ararat windows check")],
        "Profile 1": [aRow("one", name: "Ararat URL field action one")],
    ])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "named")
    #expect(model.extensionProfiles == ["Default", "Profile 1"])
    #expect(model.extensionProfile == "Profile 1")
    #expect(model.extensions.map(\.id) == ["one"])
    model.selectExtensionProfile("Default")
    #expect(model.extensionProfile == "Default")
    #expect(model.extensions.map(\.id) == ["windows"])
    // A profile the chooser does not name is ignored, and the default profile is taken when the
    // window's space is not among them.
    model.selectExtensionProfile("Profile 9")
    #expect(model.extensionProfile == "Default")
    model.readExtensions(shownSpaceID: "missing")
    #expect(model.extensionProfile == "Default")
    // A profile with nothing installed shows the empty list, and the pane says so.
    host.rowsByProfile["Default"] = []
    model.refreshExtensions()
    #expect(model.extensions.isEmpty)
}

// X1: a profile that exists but is not loaded yet answers "loading"; the pane keeps the rows it
// has and never draws the empty state for it.
@Test @MainActor
func theLoadingProfileKeepsItsRowsAndDoesNotReadAsEmpty() {
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: ["Default": [aRow("windows")]])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "default")
    #expect(model.extensions.count == 1)
    // A refresh while the engine loads the profile keeps the row and marks loading.
    host.loadingProfiles = ["Default"]
    model.extensionsChanged()
    #expect(model.extensionsLoading && model.extensions.map(\.id) == ["windows"])
    // Choosing another profile clears the old rows; while it loads the list is loading and empty.
    host.loadingProfiles = ["Profile 1"]
    model.selectExtensionProfile("Profile 1")
    #expect(model.extensionsLoading && model.extensions.isEmpty)
    host.loadingProfiles = []
    host.rowsByProfile["Profile 1"] = [aRow("one")]
    model.extensionsChanged()
    #expect(!model.extensionsLoading && model.extensions.map(\.id) == ["one"])
}

// X2: the switch, the site access and the pin write through the host and the row is read back.
@Test @MainActor
func theSwitchSiteAccessAndPinGoThroughTheEngine() throws {
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: ["Default": [aRow("windows")]])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "default")
    let row = try #require(model.extensionRow(id: "windows"))

    #expect(model.setExtensionEnabled(row.id, enabled: false))
    #expect(host.writes.last == FakeExtensionSettingsHost.Write(profile: "Default", identifier: "windows",
                                                               value: "enabled=false"))
    #expect(model.extensionRow(id: "windows")?.enabled == false)
    #expect(model.extensionRow(id: "windows")?.summary == "Off")

    #expect(model.setExtensionSiteAccess(row.id, access: .onClick))
    #expect(host.writes.last?.value == "click")
    #expect(model.extensionRow(id: "windows")?.siteAccess == .onClick)
    // "On specific sites" is never written: the site picker stays Chromium's page.
    #expect(!model.setExtensionSiteAccess(row.id, access: .onSpecificSites))

    #expect(model.toggleExtensionPin(row.id))
    #expect(host.writes.last?.value == "pinned=true")
    #expect(model.extensionRow(id: "windows")?.pinned == true)

    // An extension with no site access takes no site write at all.
    host.rowsByProfile["Default"] = (host.rowsByProfile["Default"] ?? []) + [aRow("plain", name: "Ararat URL field action one", siteAccess: .noSiteAccess)]
    model.refreshExtensions()
    #expect(!model.setExtensionSiteAccess("plain", access: .onClick))

    // A refused engine write leaves the row as the engine still reports it and names why.
    host.refuses = true
    #expect(!model.setExtensionEnabled(row.id, enabled: true))
    #expect(model.extensionRow(id: "windows")?.enabled == false)
    #expect(model.error != nil)

    // An extension Chromium does not let the user switch offers no write either.
    host.refuses = false
    host.rowsByProfile["Default"] = [aRow("locked", canDisable: false)]
    model.refreshExtensions()
    #expect(!model.setExtensionEnabled("locked", enabled: false))
}

// X3: a row Chromium disabled for new permissions offers Review… instead of the switch; accepting
// Chromium's prompt enables it, and a refusal leaves it disabled.
@Test @MainActor
func theReviewRowOpensThePromptAndAccepts() {
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: [
        "Default": [aRow("windows", enabled: false, needsReview: true)],
    ])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "default")
    #expect(model.extensions.first?.needsReview == true)
    #expect(model.extensions.first?.summary == "Needs new permissions")
    #expect(!model.setExtensionEnabled("windows", enabled: true))
    #expect(model.error != nil)
    model.error = nil

    model.reviewExtension("windows")
    #expect(host.reviews == ["windows"])
    #expect(model.extensionRow(id: "windows")?.enabled == true)
    #expect(model.extensionRow(id: "windows")?.needsReview == false)

    // A cancelled prompt leaves the row as it was and shows no error.
    host.rowsByProfile["Default"] = [aRow("windows", enabled: false, needsReview: true)]
    host.reviewResult = false
    model.refreshExtensions()
    model.reviewExtension("windows")
    #expect(model.extensionRow(id: "windows")?.enabled == false)
    #expect(model.extensionRow(id: "windows")?.needsReview == true)
}

// X2/design B/X5: Remove… asks in the sheet the window presents; Cancel keeps the row, Remove calls
// the engine's uninstall, a removal reported elsewhere ends the sheet, and the observer signal
// re-reads the pane.
@Test @MainActor
func removalAsksInTheSheetAndTheChangeSignalKeepsThePaneCurrent() async throws {
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: [
        "Default": [aRow("windows"), aRow("one", name: "Ararat URL field action one")],
    ])
    model.extensionHost = host
    host.setChangeHandler { [weak model] in model?.extensionsChanged() }
    var presented: [SettingsExtension] = []
    var dismissed = 0
    model.presentRemoveSheet = { presented.append($0) }
    model.dismissRemoveSheet = { dismissed += 1 }
    model.readExtensions(shownSpaceID: "default")
    #expect(model.extensions.count == 2)

    // The sheet's copy, shared by the pane, the check and this test.
    #expect(SettingsModel.removeSheetTitle(for: "Ararat windows check") == "Remove \"Ararat windows check\"?")
    #expect(SettingsModel.removeSheetText == "This removes the extension and its data from this profile.")

    // Remove… only asks; nothing is uninstalled until the sheet's Remove button.
    model.requestRemoveExtension("windows")
    #expect(presented.map(\.id) == ["windows"] && model.pendingRemoval?.id == "windows")
    #expect(host.removals.isEmpty)
    model.cancelRemoveExtension()
    #expect(model.pendingRemoval == nil && host.removals.isEmpty)
    #expect(model.extensions.count == 2)

    // The sheet's Remove button goes through the engine's uninstall and the list is read back.
    model.requestRemoveExtension("windows")
    model.confirmRemoveExtension("windows")
    #expect(host.removals == ["windows"] && model.pendingRemoval == nil)
    #expect(model.extensions.map(\.id) == ["one"])

    // An uninstall the engine refuses keeps the row and shows the engine's answer.
    host.uninstallResult = "forced"
    model.confirmRemoveExtension("one")
    #expect(model.extensionRow(id: "one") != nil && model.error != nil)
    host.uninstallResult = ""

    // A removal reported elsewhere (X5) ends an open sheet for that extension.
    model.error = nil
    model.requestRemoveExtension("one")
    #expect(model.pendingRemoval?.id == "one")
    host.change("Default", to: [])
    try await waitUntil { dismissed == 1 }
    #expect(model.pendingRemoval == nil && model.extensions.isEmpty)
}

// The AppKit sheet tests share the process.s sheets and windows, so they are serialized.
@Suite(.serialized)
struct RemoveSheetChecks {
/// The sheet itself (design's wording and buttons): Cancel is the default and answers Return, Remove
/// is destructive, and cancelling keeps the row.
@Test @MainActor
func theRemoveSheetHasTheDesignsTextAndCancelDefault() async throws {
    _ = NSApplication.shared
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: ["Default": [aRow("windows")]])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "default")
    let controller = SettingsWindowController(model: model, orderWindowFront: { _ in })
    controller.setExtensionSettings(host: host, manage: { _, _ in })
    let window = try #require(controller.window)
    var alert: NSAlert?
    var answer: ((NSApplication.ModalResponse) -> Void)?
    controller.presentSheet = { sheet, _, completion in alert = sheet; answer = completion }
    defer { window.contentViewController = nil }

    model.requestRemoveExtension("windows")
    try await waitUntil { alert != nil }
    let sheet = try #require(alert?.window)
    #expect(sheet.title == SettingsModel.removeSheetTitle(for: "Ararat windows check"))
    func buttons(_ view: NSView) -> [NSButton] {
        view.subviews.compactMap { $0 as? NSButton } + view.subviews.flatMap(buttons)
    }
    let found = buttons(try #require(sheet.contentView))
    let remove = try #require(found.first { $0.title == "Remove" })
    // Return answers Cancel (AppKit's default button cell), and Remove is destructive.
    #expect(sheet.defaultButtonCell?.title == "Cancel")
    #expect(remove.hasDestructiveAction)

    answer?(.alertFirstButtonReturn)
    try await waitUntil { model.pendingRemoval == nil }
    #expect(model.extensions.map(\.id) == ["windows"])
    #expect(host.removals.isEmpty)
}

// H1: the sheet's Esc belongs to the sheet alone. An Esc aimed at the alert cancels; one aimed at
// the Settings window itself (or any other window) passes through and leaves the sheet up.
@Test @MainActor
func theRemoveSheetAnswersOnlyItsOwnEsc() async throws {
    _ = NSApplication.shared
    func esc(for window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                         isARepeat: false, keyCode: 53)
    }
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: ["Default": [aRow("windows")]])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "default")
    let controller = SettingsWindowController(model: model, orderWindowFront: { _ in })
    controller.setExtensionSettings(host: host, manage: { _, _ in })
    let window = try #require(controller.window)
    var alert: NSAlert?
    controller.presentSheet = { sheet, _, _ in alert = sheet }
    defer { window.contentViewController = nil }

    model.requestRemoveExtension("windows")
    try await waitUntil { alert != nil }
    let sheet = try #require(alert?.window)

    // Esc typed in the Settings window itself is returned untouched and does not end the sheet.
    let untouched = try #require(esc(for: window))
    #expect(controller.handleRemoveSheetKey(untouched, targetWindow: window) === untouched)
    #expect(alert?.window === sheet && model.pendingRemoval?.id == "windows")

    // Esc aimed at the sheet cancels it; the extension stays.
    #expect(controller.handleRemoveSheetKey(try #require(esc(for: sheet)), targetWindow: sheet) == nil)
    try await waitUntil { model.pendingRemoval == nil }
    #expect(model.extensions.map(\.id) == ["windows"])
    #expect(host.removals.isEmpty)
}

// H2: a Settings window closed with the sheet up clears the sheet state, and Remove… works again.
@Test @MainActor
func closingSettingsWithTheRemoveSheetUpClearsIt() async throws {
    _ = NSApplication.shared
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: ["Default": [aRow("windows")]])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "default")
    let controller = SettingsWindowController(model: model, orderWindowFront: { _ in })
    controller.setExtensionSettings(host: host, manage: { _, _ in })
    let window = try #require(controller.window)
    var alert: NSAlert?
    var answer: ((NSApplication.ModalResponse) -> Void)?
    controller.presentSheet = { sheet, _, completion in alert = sheet; answer = completion }
    defer { window.contentViewController = nil }

    model.requestRemoveExtension("windows")
    try await waitUntil { alert != nil }
    window.close()
    try await waitUntil { model.pendingRemoval == nil && window.attachedSheet == nil }
    #expect(model.extensions.map(\.id) == ["windows"])

    // The next Remove… is not refused by leftover state.
    controller.open(shownSpaceID: "default")
    #expect(!window.isVisible)
    alert = nil
    model.requestRemoveExtension("windows")
    try await waitUntil { alert != nil }
    #expect(alert?.window.isVisible == false)
    answer?(.alertFirstButtonReturn)
    try await waitUntil { model.pendingRemoval == nil }
    #expect(model.extensions.map(\.id) == ["windows"])
}
}  // struct RemoveSheetChecks

// The pane draws the chooser, the Installed card and a row's switch or Review…, and the empty
// state; the search reaches the profile row and the extensions.
@Test @MainActor
func theExtensionsPaneDrawsItsRowsAndMarkers() async throws {
    _ = NSApplication.shared
    let model = extensionModel(extensionSnapshot())
    let host = FakeExtensionSettingsHost(rowsByProfile: [
        "Default": [aRow("windows"), aRow("review", name: "Ararat review fixture",
                                         enabled: false, needsReview: true, canPin: false),
                    aRow("locked", name: "Ararat policy fixture", canDisable: false)],
    ])
    model.extensionHost = host
    model.readExtensions(shownSpaceID: "default")
    model.navigate(.extensions)
    let controller = SettingsWindowController(model: model, orderWindowFront: { _ in })
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil {
        probe.layout()
        return probe.marker(SettingsModel.rowMarker(SettingsModel.extensionsProfileRowID)) != nil
            && probe.marker(SettingsModel.extensionsProfileMenuMarker) != nil
            && probe.marker(SettingsModel.rowMarker(SettingsModel.extensionsListCardID)) != nil
            && probe.marker(SettingsModel.extensionSwitchMarker("windows")) != nil
            && probe.marker(SettingsModel.extensionReviewMarker("review")) != nil
            && probe.marker(SettingsModel.extensionMenuMarker("windows")) != nil
    }
    #expect(probe.marker(SettingsModel.extensionSwitchMarker("review")) == nil)
    // X2 (design): an extension Chromium does not let the user switch draws no switch.
    #expect(probe.marker(SettingsModel.extensionSwitchMarker("locked")) == nil)
    #expect(probe.title == "Extensions")
    #expect(probe.subtitle == "Added and managed per profile.")

    // The search finds the profile row and both extensions, and Return opens the pane on the row.
    let rows = model.rows
    #expect(rows.contains { $0.id == SettingsModel.extensionsProfileRowID })
    #expect(rows.contains { $0.id == SettingsModel.extensionRowID("windows") })
    #expect(rows.contains { $0.id == SettingsModel.extensionRowID("review") })

    // While an existing profile loads, the card says it is loading, not that it is empty. (A
    // reload with rows already shown keeps them; a first load has nothing to keep.)
    host.rowsByProfile["Profile 1"] = []
    host.loadingProfiles = ["Profile 1"]
    model.selectExtensionProfile("Profile 1")
    try await waitUntil {
        probe.layout()
        return probe.marker(SettingsModel.extensionsLoadingMarker) != nil
            && probe.marker(SettingsModel.extensionsEmptyMarker) == nil
    }

    // With nothing installed, and no load running, the card says so.
    host.loadingProfiles = []
    model.refreshExtensions()
    try await waitUntil {
        probe.layout()
        return probe.marker(SettingsModel.extensionsEmptyMarker) != nil
    }
}
