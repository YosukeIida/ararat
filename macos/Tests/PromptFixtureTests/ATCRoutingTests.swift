import AppKit
import AraratEngineAPI
import AraratKit
import ObjectiveC.runtime
import Testing
@testable import Ararat

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
}

@MainActor
private final class ATCTestHost: NSObject {
    let value = ATCTestWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    var profile = "Profile 1"
    override init() {
        super.init()
        value.isReleasedWhenClosed = false
    }
    @objc func window() -> NSWindow { value }
    @objc func profileDirectory() -> String { profile }
    @objc func isClosing() -> Bool { false }
    @objc func isClosingAll() -> Bool { false }
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
