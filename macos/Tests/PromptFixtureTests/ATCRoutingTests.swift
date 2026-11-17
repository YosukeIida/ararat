import AppKit
import AraratEngineAPI
import AraratKit
import ObjectiveC.runtime
import Testing
@testable import Ararat

@Test @MainActor
func settingsATCMenuLookupRequiresAnExactVisibleEnabledItem() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(withTitle: "Most Recent Space extra", action: nil, keyEquivalent: "")
    let hidden = menu.addItem(withTitle: "Most Recent Space", action: nil, keyEquivalent: "")
    hidden.isHidden = true
    let disabled = menu.addItem(withTitle: "Most Recent Space", action: nil, keyEquivalent: "")
    disabled.isEnabled = false
    #expect(SettingsATCInput.menuItemIndex(in: menu, title: "Most Recent Space") == nil)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Most Recent Space", action: nil, keyEquivalent: "")
    #expect(SettingsATCInput.menuItemIndex(in: menu, title: "Most Recent Space") == 4)
    #expect(SettingsATCInput.menuItemIndex(in: menu, title: "Missing") == nil)
}

@MainActor
private final class ATCMenuTarget: NSObject {
    var calls = 0
    @objc func selectDestination(_ sender: NSMenuItem) { calls += 1 }
}

@Test @MainActor
func settingsATCRowMenuTrackingEndsOnlyForTheObservedMenu() {
    let check = SettingsScreenCheck()
    let menu = NSMenu()
    check.watchAirTrafficRowMenuEnd(menu)
    #expect(check.airTrafficRowMenuTracking == true)
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
    #expect(check.airTrafficRowMenuTracking == true)
    check.phase = 8
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    #expect(check.airTrafficRowMenuTracking == false)
    #expect(check.airTrafficRowMenuEndObserver == nil)
    let entries = check.details["atc_menu_trace"] as? [[String: Any]]
    #expect(entries?.first?["event"] as? String == "row menu tracking ended")
}

@Test @MainActor
func settingsATCMenuTraceCoversTrackingAndObserverDecisionsOnlyInDiagnosticPhases() throws {
    let check = SettingsScreenCheck()
    check.startAirTrafficMenuTrace()
    check.startAirTrafficMenuTrace()
    let menu = NSMenu(title: "Default destination")
    menu.autoenablesItems = false
    let selected = menu.addItem(withTitle: "Little Window", action: nil, keyEquivalent: "")
    selected.state = .on
    let disabled = menu.addItem(withTitle: "Most Recent Space", action: nil, keyEquivalent: "")
    disabled.isEnabled = false
    disabled.isHidden = true
    for phase in [7, 8, 9, 10, 11] {
        check.phase = phase
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    }
    var entries = try #require(check.details["atc_menu_trace"] as? [[String: Any]])
    #expect(entries.compactMap { $0["phase"] as? Int } == [8, 9, 10])
    let items = try #require(entries[0]["items"] as? [[String: Any]])
    #expect(items[0]["title"] as? String == "Little Window")
    #expect(items[0]["selected"] as? Bool == true)
    #expect(items[1]["enabled"] as? Bool == false)
    #expect(items[1]["hidden"] as? Bool == true)
    check.phase = 9
    check.watchAirTrafficMenu(title: disabled.title)
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    #expect(check.airTrafficMenuObserver != nil)
    entries = try #require(check.details["atc_menu_trace"] as? [[String: Any]])
    let decisions = entries.filter { $0["event"] as? String == "observer not matched" }
    #expect(decisions.compactMap { $0["reason"] as? String } == [
        "no exact title", "exact title exists but is disabled, hidden, or a separator"
    ])
    #expect(JSONSerialization.isValidJSONObject(check.details))
    check.stopWatchingAirTrafficMenu()
}

@Test @MainActor
func settingsATCMenuActsOnceDuringTrackingForBothDestinations() throws {
    _ = NSApplication.shared
    for phase in [7, 9] {
        let check = SettingsScreenCheck()
        check.phase = phase
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = ATCMenuTarget()
        let item = menu.addItem(withTitle: "Most Recent Space", action: #selector(ATCMenuTarget.selectDestination(_:)), keyEquivalent: "")
        item.target = target
        check.watchAirTrafficMenu(title: item.title)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        #expect(check.airTrafficMenuObserver != nil)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(check.airTrafficMenuObserver == nil)
        #expect(check.phase == phase && target.calls == 0)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        let deadline = Date(timeIntervalSinceNow: 1)
        while check.phase == phase && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        #expect(target.calls == 1)
        #expect(check.phase == phase + 1)
        #expect(check.conditions["row_destination"] == nil && check.conditions["default_stored"] == nil)
        if phase == 9 {
            let entries = try #require(check.details["atc_menu_trace"] as? [[String: Any]])
            #expect(entries.compactMap { $0["event"] as? String } == [
                "observer not matched", "observer matched", "perform action", "action returned"
            ])
            #expect(entries.last?["selected_index"] as? Int == 0)
        }
    }
}

@Test
func settingsATCKeysKeepTheirPhysicalKeyAndUnicodeTextWithoutPosting() throws {
    let eisu = try #require(SettingsATCInput.events(code: 102, text: "\u{10}"))
    #expect(eisu.map(\.type) == [.keyDown, .keyUp])
    #expect(eisu.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 102 })
    let text = try #require(SettingsATCInput.events(code: 0, text: "abc"))
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 8)
    text[0].keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
    #expect(String(utf16CodeUnits: buffer, count: length) == "abc")
}

@Test @MainActor
func atcProgressReportsItsOwnPhaseBeforeTheWorkspaceIsReady() {
    let owner = Runtime()
    let check = ATCRoutingCheck()
    check.phase = 3
    check.tick(owner)
    #expect(owner.browserCheckPhase == 3)
    #expect(owner.browserCheckAttempts == 1)
    #expect(check.phase == 3)
}

@Test @MainActor
func privateRoutingWaitsForTheInitialTabToBeAdoptedAndActive() throws {
    let store = WorkspaceStore.openPrivate(profile: .default)
    let empty = store.snapshot(windowId: "private-baseline")
    #expect(!ATCRoutingCheck.privateBaselineReady(empty, activeItem: nil))
    let adopted = try store.createTab(windowId: "private-baseline", url: "about:blank")
    let item = try #require(adopted.selectedId)
    #expect(!ATCRoutingCheck.privateBaselineReady(empty, activeItem: item))
    #expect(!ATCRoutingCheck.privateBaselineReady(adopted, activeItem: nil))
    #expect(!ATCRoutingCheck.privateBaselineReady(adopted, activeItem: "other"))
    #expect(ATCRoutingCheck.privateBaselineReady(adopted, activeItem: item))
    let extra = try store.createTab(windowId: "private-baseline", url: "https://unexpected.test/")
    #expect(!ATCRoutingCheck.privateBaselineReady(extra, activeItem: extra.selectedId))
}

@Test @MainActor
func privateRoutingIdentifiesTheNewLittleWindowAcrossOrigins() {
    let owner = Runtime()
    let child = Runtime()
    func little(_ origin: Runtime) -> LittleWindowController {
        LittleWindowController(popup: PopupHost(), origin: origin, profile: "Profile 1",
                               frame: .zero, url: "https://atc-little.test/")
    }
    let old = little(child)
    let opened = little(owner)
    let extra = little(owner)
    let check = ATCRoutingCheck()
    check.littleBeforePrivate = [ObjectIdentifier(old)]
    #expect(check.privateLittleWindow(in: [opened, old]) === opened)
    #expect(check.privateLittleWindow(in: [old]) == nil)
    #expect(check.privateLittleWindow(in: [opened, extra, old]) == nil)
}

@MainActor
private func atcSnapshot() -> WorkspaceSnapshot {
    let spaces = [("a", "Default", Profile.default), ("b", "Profile 1", Profile.named("Profile 1"))].map { id, name, profile in
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: id, pinnedId: "pin-\(id)", todayId: "today-\(id)", favoritesId: nil, archiveAfter: .hours12, profileName: name, profile: profile, id: id, title: id, icon: nil, look: nil, pinnedCollapsed: false, favorites: [], pinned: [], today: [])
    }
    return WorkspaceSnapshot(archive: [], shownSpaceId: "a", selectedId: nil, spaces: spaces)
}

@Test @MainActor
func externalDecisionMapsToTheTargetSpaceAndItsProfile() {
    let snapshot = atcSnapshot()
    #expect(Runtime.externalDestination(.space(.mostRecent), snapshot: snapshot) == .space("a", "Default"))
    #expect(Runtime.externalDestination(.space(.space("b")), snapshot: snapshot) == .space("b", "Profile 1"))
    #expect(Runtime.externalDestination(.space(.space("deleted")), snapshot: snapshot) == nil)
}

@Test @MainActor
func externalLittleWindowDecisionKeepsItsProfile() {
    #expect(Runtime.externalDestination(.littleWindow(.default), snapshot: atcSnapshot()) == .littleWindow("Default"))
    #expect(Runtime.externalDestination(.littleWindow(.named("Unloaded")), snapshot: atcSnapshot()) == .littleWindow("Unloaded"))
}

@Test @MainActor
func externalMostRecentRequiresTheResolvedSpaceInsteadOfSidebarOrder() {
    var snapshot = atcSnapshot()
    snapshot.shownSpaceId = nil
    #expect(Runtime.externalDestination(.space(.mostRecent), snapshot: snapshot) == nil)
}

@Test @MainActor
func externalOpenQueuesBeforeTheWorkspaceIsReadyAndKeepsTrustAndOrder() {
    let owner = Runtime()
    let child = Runtime()
    child.root = owner
    owner.children = [child]
    child.openURLs([("https://first.test/", true), ("https://second.test/", false)])
    #expect(owner.externalURLs.map(\.url) == ["https://first.test/", "https://second.test/"])
    #expect(owner.externalURLs.map(\.untrusted) == [true, false])
    #expect(!owner.openingExternalURL)
    #expect(child.externalURLs.isEmpty)
}

@Test @MainActor
func atcFixtureRoutesThroughTheCoreAndFallsBackAfterDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                                   windowID: "atc", card: NSView(), seedProfiles: true)
    defer { adapter.shutdown() }
    try ATCRoutingCheck.seed(adapter.session, window: "atc")
    try adapter.session.queue.sync {
        let store = adapter.session.store!
        let rules = store.routing()
        #expect(store.route(url: ATCRoutingCheck.coldURL).destination == .space(.space("named")))
        #expect(store.route(url: "https://atc-little.test/").destination == .littleWindow(.named("Profile 1")))
        #expect(store.route(url: "https://other.test/").destination == .littleWindow(.default))
        try store.showSpace(windowId: "atc", spaceId: "default")
        _ = try store.createTab(windowId: "atc", url: "https://default-key.test/")
        #expect(store.route(url: "https://atc-rule-recent.test/").destination == .space(.space("named")))
        #expect(store.routing() == rules)
        _ = try store.liveDeleteSpace(windowId: "atc", spaceId: "named")
        #expect(store.route(url: ATCRoutingCheck.coldURL).destination == .littleWindow(.default))
        #expect(store.routing() == rules)
    }
}

@Test @MainActor
func externalMostRecentWithoutWindowsUsesCoreRecencyAcrossProfiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                                   windowID: "atc-closed", card: NSView(), seedProfiles: true)
    defer { adapter.shutdown() }
    try adapter.session.queue.sync {
        let store = adapter.session.store!
        try store.showSpace(windowId: "atc-closed", spaceId: "named")
        _ = try store.createTab(windowId: "atc-closed", url: "https://latest.test/")
        try store.closeWindow(windowId: "atc-closed", quitting: false)
        #expect(store.keptWindows().isEmpty)
        var snapshot = store.snapshot(windowId: "reopened")
        #expect(snapshot.spaces.first?.id == "default")
        snapshot.shownSpaceId = store.mostRecentSpace()
        #expect(Runtime.externalDestination(.space(.mostRecent), snapshot: snapshot) == .space("named", "Profile 1"))
    }
}

@MainActor
private final class ATCTestWindow: NSWindow {
    var key = false
    override var isKeyWindow: Bool { key }
    override func makeKeyAndOrderFront(_ sender: Any?) {}
}

@MainActor
private final class ATCTestHost: NSObject {
    let value = ATCTestWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    var profile = "Profile 1"
    var activeItem: String?
    override init() {
        super.init()
        value.isReleasedWhenClosed = false
    }
    @objc func window() -> NSWindow { value }
    @objc func profileDirectory() -> String { profile }
    @objc func activeItemId() -> String? { activeItem }
    @objc func isClosing() -> Bool { false }
    @objc func isClosingAll() -> Bool { false }
}

@Test @MainActor
func privateRoutingPhaseTargetsNamedRegardlessOfTheNewestKeptWindow() throws {
    _ = NSApplication.shared
    class_addProtocol(ATCTestHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = Runtime(windowID: "atc-private-target")
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                                   windowID: owner.windowID, card: NSView(), seedProfiles: true)
    defer { adapter.shutdown() }
    owner.adapter = adapter
    let privateWindow = Runtime()
    privateWindow.isPrivateWindow = true
    let privateStore = WorkspaceStore.openPrivate(profile: .default)
    privateWindow.snapshot = try privateStore.createTab(windowId: privateWindow.windowID, url: "about:blank")
    let host = ATCTestHost()
    host.value.key = true
    host.activeItem = privateWindow.snapshot.selectedId
    privateWindow.host = host as AnyObject as? any ARWindowHostAPI
    owner.children = [privateWindow]
    defer { host.value.close() }

    for space in ["default", "named"] {
        try adapter.session.queue.sync {
            let store = adapter.session.store!
            _ = try store.setDefaultDestination(windowId: owner.windowID, destination: .space(.mostRecent))
            try store.showSpace(windowId: space, spaceId: space)
            _ = try store.createTab(windowId: space, url: "https://newest.test/\(space)")
            #expect(store.keptWindows().first?.shownSpace == space)
        }
        let check = ATCRoutingCheck()
        check.phase = 6
        check.tick(owner)
        #expect(check.phase == 7)
        adapter.session.queue.sync {
            #expect(adapter.session.store!.route(url: "https://atc-private-key.test/").destination == .space(.space("named")))
            #expect(adapter.session.store!.route(url: "https://atc-no-window.test/reopen").destination == .space(.space("named")))
        }
    }
}

@Test @MainActor
func externalSpacePrefersTheWindowShowingItThenTheKeyWindowOfItsProfile() {
    _ = NSApplication.shared
    class_addProtocol(ATCTestHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let showing = Runtime()
    let key = Runtime()
    let showingHost = ATCTestHost()
    let keyHost = ATCTestHost()
    showing.host = showingHost as AnyObject as? any ARWindowHostAPI
    key.host = keyHost as AnyObject as? any ARWindowHostAPI
    showing.snapshot = atcSnapshot()
    key.snapshot = atcSnapshot()
    showing.snapshot.shownSpaceId = "b"
    keyHost.value.key = true
    #expect(Runtime.externalWindow(windows: [key, showing], space: "b", profile: "Profile 1") === showing)
    showing.hostClosing = true
    #expect(Runtime.externalWindow(windows: [showing, key], space: "b", profile: "Profile 1") === key)
    key.isPrivateWindow = true
    #expect(Runtime.externalWindow(windows: [showing, key], space: "b", profile: "Profile 1") == nil)
    key.isPrivateWindow = false
    keyHost.profile = "Default"
    #expect(Runtime.externalWindow(windows: [key], space: "b", profile: "Profile 1") == nil)
    keyHost.value.close()
    showingHost.value.close()
}
