import AppKit
import AraratEngineAPI
import AraratKit
import ObjectiveC.runtime
import Testing
@testable import Ararat

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
func externalMostRecentCanUseTheFirstSpaceBeforeAWindowHasSelection() {
    var snapshot = atcSnapshot()
    snapshot.shownSpaceId = nil
    #expect(Runtime.externalDestination(.space(.mostRecent), snapshot: snapshot) == .space("a", "Default"))
    snapshot.spaces = []
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
        #expect(store.routing() == rules)
        _ = try store.liveDeleteSpace(windowId: "atc", spaceId: "named")
        #expect(store.route(url: ATCRoutingCheck.coldURL).destination == .littleWindow(.default))
        #expect(store.routing() == rules)
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
