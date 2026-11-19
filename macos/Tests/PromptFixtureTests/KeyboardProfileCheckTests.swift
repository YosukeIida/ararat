import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor
private final class KeyboardProfileTab: NSObject {
    @objc dynamic var itemId: String? = "restored"
    @objc dynamic var liveId = "live"
    @objc dynamic var url = "http://127.0.0.1:1234/keyboard"
    @objc dynamic var isLoading = false
    @objc dynamic var navigationCount = 1
}

@MainActor
private final class KeyboardProfileHost: NSObject {
    let tab = KeyboardProfileTab()
    var actions: [Int] = []
    var shortcutCount = 0
    var pagePresented = false
    @objc func profileDirectory() -> String { "Profile 1" }
    @objc(hasBrowserForProfile:) func hasBrowser(_ profile: String) -> Bool { true }
    @objc func activeItemId() -> String? { tab.itemId }
    @objc func hasActiveTab() -> Bool { false }
    @objc func tabs() -> [Any] { [tab] }
    @objc func checkPagePresentation(_ liveId: String) -> [String: Any] { ["presented": pagePresented && liveId == tab.liveId] }
    @objc func extensionActions() -> [[String: Any]] { [["id": "kmgaadhbnkendcanjninlfmfgehagggl"]] }
    @objc(checkExtensionAction:) func checkAction(_ command: Int) { actions.append(command) }
    @objc func checkReassignedAction() -> Bool { shortcutCount += 1; return true }
    @objc func checkExtensionActionState() -> [String: Any] { [:] }
}

@Test @MainActor
func keyboardNoTabCaptureWaitsForThePresentedPageToLeave() {
    _ = NSApplication.shared
    class_addProtocol(KeyboardProfileHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(KeyboardProfileTab.self, objc_getProtocol("ARTabAPI")!)
    let fake = KeyboardProfileHost()
    fake.tab.itemId = "seed"
    fake.pagePresented = true
    let runtime = Runtime(windowID: "keyboard-no-tab")
    runtime.browserCheckSeedID = "seed"
    runtime.promptFixturePort = 1234
    runtime.browserCheckPhase = 36411
    runtime.keyboardArchiveSiblingSpace = "sibling"
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "named", pinnedId: "pinned", todayId: "today",
                              favoritesId: nil, archiveAfter: .hours12, profileName: "Profile 1", profile: .named("Profile 1"),
                              id: "sibling", title: "Adjacent", icon: nil, look: nil, pinnedCollapsed: false,
                              favorites: [], pinned: [], today: [])
    runtime.snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space])
    let sidebar = SidebarView(snapshot: runtime.snapshot)
    runtime.sidebar = sidebar

    runtime.keyboardCheckTick(fake as! any ARWindowHostAPI, screen: true)

    #expect(runtime.browserCheckPhase == 36411)
    #expect(runtime.keyboardCaptureCondition == "no_tab_state")
    #expect(runtime.keyboardResults["capture_wait"] as? String == "no_tab_state")
    #expect(runtime.keyboardResults["no_tab_state"] as? Bool == false)
    #expect(!sidebar.libraryOpen)
}

@Test @MainActor
func keyboardEmptyArchiveCaptureWaitsForTheArchivePageToDrawItsEmptyState() {
    _ = NSApplication.shared
    class_addProtocol(KeyboardProfileHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(KeyboardProfileTab.self, objc_getProtocol("ARTabAPI")!)
    let fake = KeyboardProfileHost()
    fake.tab.itemId = "seed"
    let runtime = Runtime(windowID: "keyboard-archive-empty")
    runtime.browserCheckSeedID = "seed"
    runtime.promptFixturePort = 1234
    runtime.browserCheckPhase = 3657
    let sidebar = SidebarView(snapshot: runtime.snapshot)
    sidebar.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
    runtime.sidebar = sidebar
    sidebar.setLibraryOpen(true, downloads: true)

    runtime.keyboardCheckTick(fake as! any ARWindowHostAPI, screen: true)

    #expect(runtime.browserCheckPhase == 3657)
    #expect(runtime.keyboardCaptureCondition == "archive_empty_state")
    #expect(runtime.keyboardResults["capture_wait"] as? String == "archive_empty_state")
    #expect(runtime.keyboardResults["archive_empty_state"] as? Bool == false)
    #expect(sidebar.libraryOpen)
    sidebar.setLibraryOpen(true)
    sidebar.layoutSubtreeIfNeeded()
    #expect(sidebar.checkArchiveEmptyStateVisible)
}

@Test @MainActor
func profileReloadShortcutWaitsForTheRequestedTabToFinishOpening() {
    class_addProtocol(KeyboardProfileHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(KeyboardProfileTab.self, objc_getProtocol("ARTabAPI")!)
    let fake = KeyboardProfileHost()
    let host = fake as! any ARWindowHostAPI
    let runtime = Runtime(windowID: "keyboard-profile-check")
    runtime.browserCheckPhase = 55

    func tickWaiting() {
        runtime.keyboardProfileCheckTick(host, port: 1234, screen: false)
        #expect(runtime.browserCheckPhase == 55)
        #expect(fake.actions.isEmpty)
        #expect(fake.shortcutCount == 0)
    }

    tickWaiting()
    fake.tab.itemId = "requested"
    fake.tab.url = "http://127.0.0.1:1234/keyboard?profile-reload"
    fake.tab.isLoading = true
    tickWaiting()
    fake.tab.isLoading = false
    fake.tab.navigationCount = 0
    tickWaiting()
    fake.tab.navigationCount = 1
    runtime.keyboardProfileCheckTick(host, port: 1234, screen: false)
    #expect(runtime.browserCheckPhase == 56)
    #expect(fake.actions == [5])
    #expect(fake.shortcutCount == 1)
}

@Test @MainActor
func keyboardArchiveCheckRemovesItsSiblingBeforeTheProfileReload() async throws {
    _ = NSApplication.shared
    class_addProtocol(KeyboardProfileHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(KeyboardProfileTab.self, objc_getProtocol("ARTabAPI")!)
    let runtime = Runtime(windowID: "keyboard-archive-cleanup")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    try LiveBatchCheck.seed(session, path: directory.appendingPathComponent("keyboard.sqlite").path, window: runtime.windowID)
    runtime.adapter = try EngineAdapter(path: directory.appendingPathComponent("keyboard.sqlite").path,
                                        windowID: runtime.windowID, card: NSView(), session: session)
    runtime.workspace = WorkspaceAdapter(windowID: runtime.windowID, session: session)
    let store = try #require(session.store)
    try store.showSpace(windowId: runtime.windowID, spaceId: "named")
    let other = try #require(store.createTab(windowId: runtime.windowID, url: "https://other.test").selectedId)
    _ = try store.createSpace(windowId: runtime.windowID, name: "Archive restore sibling", spaceId: "sibling")
    runtime.keyboardOtherItem = other
    runtime.keyboardArchiveSiblingSpace = "sibling"
    runtime.snapshot = store.snapshot(windowId: runtime.windowID)
    runtime.browserCheckSeedID = "seed"
    runtime.promptFixturePort = 1234
    runtime.browserCheckPhase = 3657
    let fake = KeyboardProfileHost()
    fake.tab.itemId = "seed"
    runtime.keyboardCheckTick(fake as! any ARWindowHostAPI, screen: false)
    for _ in 0..<100 where runtime.browserCheckPhase != 366 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.browserCheckPhase == 366)
    let current = session.queue.sync { store.snapshot(windowId: runtime.windowID) }
    #expect(!current.spaces.contains { $0.id == "sibling" })
    #expect(current.shownSpaceId == "named")
    try store.showSpace(windowId: runtime.windowID, spaceId: "default")
    #expect(store.recentSpaceForProfile(windowId: runtime.windowID, profile: .named("Profile 1")) == "named")
}

@Test(arguments: [false, true]) @MainActor
func keyboardClearArchiveOnlyRequestsConfirmationOnScreen(screen: Bool) async throws {
    _ = NSApplication.shared
    class_addProtocol(KeyboardProfileHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(KeyboardProfileTab.self, objc_getProtocol("ARTabAPI")!)
    let runtime = Runtime(windowID: "keyboard-clear-archive")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    runtime.adapter = try EngineAdapter(path: directory.appendingPathComponent("keyboard.sqlite").path,
                                        windowID: runtime.windowID, card: NSView(), session: session)
    runtime.workspace = WorkspaceAdapter(windowID: runtime.windowID, session: session)
    let store = try #require(session.store)
    let archived = try #require(store.createTab(windowId: runtime.windowID, url: "https://closed.test").selectedId)
    runtime.snapshot = try store.archiveItem(windowId: runtime.windowID, id: archived)
    runtime.keyboardArchiveSplitID = archived
    runtime.browserCheckSeedID = "seed"
    runtime.promptFixturePort = 1234
    runtime.browserCheckPhase = 3654
    let sidebar = SidebarView(snapshot: runtime.snapshot)
    runtime.sidebar = sidebar
    var confirmations = 0
    sidebar.onClearArchive = { confirmations += 1 }
    let fake = KeyboardProfileHost()
    fake.tab.itemId = "seed"

    runtime.keyboardCheckTick(fake as! any ARWindowHostAPI, screen: screen)
    if !screen {
        for _ in 0..<100 where runtime.browserCheckPhase != 3656 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #expect(confirmations == (screen ? 1 : 0))
    #expect(runtime.browserCheckPhase == (screen ? 3655 : 3656))
    let current = session.queue.sync { store.snapshot(windowId: runtime.windowID) }
    #expect(current.archive.isEmpty == !screen)
    #expect(runtime.snapshot.archive.isEmpty == !screen)
}
