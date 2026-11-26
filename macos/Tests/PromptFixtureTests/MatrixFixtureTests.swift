import AppKit
import AraratEngineAPI
@testable import AraratKit
import AraratUI
import ObjectiveC.runtime
import SQLite3
import Testing
@testable import Ararat

@MainActor
private final class MatrixFakeTab: NSObject {
    @objc dynamic var liveId: String
    @objc dynamic var itemId: String?
    @objc dynamic var isLoading = false
    @objc dynamic var crashed = false
    @objc dynamic var networkError = 0
    @objc dynamic var url = "about:blank"
    @objc dynamic var title = ""
    @objc var favicon: NSImage? { nil }
    @objc dynamic var navigationCount: UInt = 0
    @objc var passwordOffer: ARPasswordOfferState { ARPasswordOfferState() }
    var thumbnailVisible = true
    weak var owner: MatrixFakeHost?
    var profile: String
    init(item: String, live: String, profile: String, owner: MatrixFakeHost) {
        self.itemId = item; self.liveId = live; self.profile = profile; self.owner = owner
    }
    @objc(activateWithCommandId:) func activate(_ command: String) {
        owner?.active = itemId
        owner?.activated.append(command)
    }
    @objc(closeWithCommandId:) func close(_ command: String) { owner?.closed.append(command) }
    @objc(captureSnapshot:) func capture(_ completion: @escaping (NSImage?) -> Void) { owner?.captureCompletions.append(completion) }
    @objc(captureSwitcherThumbnailForReserve:retry:completion:)
    func captureThumbnail(_ reserve: Bool, retry: Bool, completion: @escaping (NSImage?, NSNumber?) -> Bool) {
        owner?.thumbnailCompletions.append((retry, { image, failed in
            completion(image, failed && reserve && self.thumbnailVisible ? 0 : nil)
        }))
    }
}

@MainActor
private final class MatrixFakeWindow: NSWindow {
    var keyForTest = false
    override var isKeyWindow: Bool { keyForTest }
}

@MainActor
private final class MatrixFakeHost: NSObject {
    @objc dynamic weak var delegate: AnyObject?
    var entries: [MatrixFakeTab] = []
    var active: String?
    var shownProfile = "Default"
    var closing = false
    var closingAll = false
    var hidden = false
    var activated: [String] = []
    var closed: [String] = []
    var opened: [String] = []
    var backgroundOpened: [String] = []
    var refuseBackground = false
    var splitFrames: [String: NSValue] = [:]
    var splitFrameCalls = 0
    var transferFailures = 0
    var transferAttempts = 0
    var handoffAttempts = 0
    var failHandoffAt = 0
    var refuseHandoff = false
    var closeRequests = 0
    var onSetProfile: (() -> Void)?
    var captureCompletions: [(NSImage?) -> Void] = []
    var thumbnailCompletions: [(retry: Bool, finish: (NSImage?, Bool) -> Bool)] = []
    var remotePlaceholder = false
    var incognitoOpens = 0
    lazy var fakeWindow: MatrixFakeWindow = {
        _ = NSApplication.shared
        return MatrixFakeWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
    }()
    var profileReady = true
    var preparedProfiles: [String] = []
    var deferOpen = false
    var pendingOpens: [String: String] = [:]
    var presentationOverride: [String: Any]?
    @objc func isClosing() -> Bool { closing }
    @objc func isClosingAll() -> Bool { closingAll }
    @objc func window() -> NSWindow { fakeWindow }
    @objc func profileDirectory() -> String { shownProfile }
    @objc(setProfileDirectory:) func setProfile(_ name: String) -> Bool {
        shownProfile = name
        onSetProfile?()
        return true
    }
    @objc func close() { closeRequests += 1 }
    @objc func activeItemId() -> String? { active }
    @objc func tabs() -> [Any] { entries }
    @objc(faviconForPageURL:profileDirectory:completion:)
    func favicon(_ url: String, profile: String, completion: @escaping (NSImage?) -> Void) -> Bool { false }
    @objc func checkCreateIncognito() { incognitoOpens += 1 }
    @objc func setWorkspacePageHidden(_ value: Bool) { hidden = value }
    @objc func refreshWorkspaceWindowTitle() {}
    @objc(setWorkspaceRemote:) func setWorkspaceRemote(_ value: Bool) { remotePlaceholder = value }
    @objc func hasActiveTab() -> Bool { !hidden && active != nil }
    @objc func navigationTarget() -> [String: Any]? { hasActiveTab() ? ["item": active!] : nil }
    @objc(checkPagePresentation:) func presentation(_ live: String) -> [String: Any] {
        if let override = presentationOverride { return override }
        let tab = entries.first { $0.itemId == active }
        let shown = !hidden && tab?.liveId == live
        return ["live": tab?.liveId ?? "", "target": shown, "host": shown, "visible": shown,
                "window": shown, "bounds": shown, "page_hit": shown, "compositor": "c1", "presented": shown]
    }
    @objc(openURL:commandId:itemId:profile:external:untrusted:historyStamp:)
    func open(_ url: String, command: String, item: String, profile: String, external: Bool, untrusted: Bool, historyStamp: UInt64) -> Bool {
        if deferOpen {
            pendingOpens[command] = item
            opened.append(command)
            return true
        }
        entries.append(MatrixFakeTab(item: item, live: command, profile: profile, owner: self))
        active = item
        opened.append(command)
        return true
    }
    @objc(cancelPendingOpen:) func cancelPendingOpen(_ command: String) -> Bool {
        pendingOpens.removeValue(forKey: command) != nil
    }
    @objc(setSplitFrames:frozen:) func setSplitFrames(_ frames: [String: NSValue], frozen: Bool) -> Bool { splitFrameCalls += 1; splitFrames = frames; return true }
    @objc(transferTab:commandId:) func transfer(_ value: AnyObject, command: String) -> Bool {
        transferAttempts += 1
        if transferFailures > 0 { transferFailures -= 1; return false }
        return move(value, activate: true, command: command)
    }
    @objc(handoffTab:activate:) func handoff(_ value: AnyObject, activate: Bool) -> Bool {
        handoffAttempts += 1
        if refuseHandoff || handoffAttempts == failHandoffAt { return false }
        return move(value, activate: activate, command: "handoff")
    }
    private func move(_ value: AnyObject, activate: Bool, command: String) -> Bool {
        guard let tab = value as? MatrixFakeTab, let source = tab.owner else { return false }
        source.entries.removeAll { $0 === tab }
        if source.active == tab.itemId { source.active = source.entries.first?.itemId }
        tab.owner = self
        entries.append(tab)
        if activate {
            active = tab.itemId
            activated.append(command)
        }
        return true
    }
    @objc(prepareTransferProfile:) func prepareProfile(_ profile: String) { preparedProfiles.append(profile) }
    @objc(hasBrowserForProfile:) func hasBrowserForProfile(_ profile: String) -> Bool { profileReady }
    @objc(openBackgroundURL:commandId:itemId:profile:historyStamp:)
    func openBackground(_ url: String, command: String, item: String, profile: String, historyStamp: UInt64) -> Bool {
        if refuseBackground { return false }
        entries.append(MatrixFakeTab(item: item, live: command, profile: profile, owner: self))
        backgroundOpened.append(command)
        return true
    }
}

@MainActor
private func matrixFake() -> (MatrixFakeHost, any ARWindowHostAPI) {
    class_addProtocol(MatrixFakeHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(MatrixFakeTab.self, objc_getProtocol("ARTabAPI")!)
    let fake = MatrixFakeHost()
    return (fake, fake as! any ARWindowHostAPI)
}

@MainActor
private func privateThumbnailFixture(in dir: URL) throws -> (EngineAdapter, MatrixFakeHost, any ARWindowHostAPI, MatrixFakeTab) {
    let session = WorkspaceSession()
    let window = "private-thumbnail"
    let live = "private-live"
    let item = try session.queue.sync {
        let store = WorkspaceStore.openPrivate(profile: .default)
        session.store = store
        let tab = LiveTab(offTheRecord: true, profile: .default, liveId: live, item: nil, opener: nil,
                          navigated: true, url: "https://private.example/", title: "Private")
        let change = try store.liveApply(transaction: LiveTransaction(offTheRecord: true, epoch: 1, rev: 0,
            cause: .chrome, strips: [LiveStrip(window: window, tabs: [tab], active: live)]))
        return try #require(change.adopted.first?.item)
    }
    let adapter = try EngineAdapter(path: dir.appendingPathComponent("workspace.sqlite").path,
                                    windowID: window, card: NSView(), private: true, session: session)
    let (fake, host) = matrixFake()
    let tab = MatrixFakeTab(item: item, live: live, profile: "Default", owner: fake)
    fake.entries = [tab]
    adapter.attach(host)
    return (adapter, fake, host, tab)
}

@Test @MainActor
func privateSwitcherThumbnailStaysInMemoryAndNavigationInvalidatesIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (adapter, fake, host, tab) = try privateThumbnailFixture(in: dir)
    defer { adapter.shutdown() }
    let item = try #require(tab.itemId)
    let live = tab.liveId
    let tabAPI = try #require(tab as? any ARTabAPI)
    let image = NSImage(size: NSSize(width: 156, height: 104))

    try #require(adapter.responds(to: #selector(ARWindowHostDelegate.windowHost(_:captureSwitcherThumbnailsForTabs:))))
    try #require(adapter.responds(to: #selector(ARWindowHostDelegate.windowHost(_:invalidateSwitcherThumbnailForTab:))))
    try #require(adapter.responds(to: #selector(ARWindowHostDelegate.windowHost(_:reserveSwitcherThumbnailForTab:afterDelay:))))
    adapter.windowHost(host, reserveSwitcherThumbnailForTab: tabAPI, afterDelay: 0)
    for _ in 0..<30 where fake.thumbnailCompletions.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(fake.thumbnailCompletions.count == 1)
    _ = fake.thumbnailCompletions.removeFirst().finish(image, false)
    #expect(adapter.switcherThumbnailSource(item: item, live: live) == "reserve")
    adapter.windowHost(host, captureSwitcherThumbnailsForTabs: [tabAPI])
    try #require(fake.thumbnailCompletions.count == 1)
    _ = fake.thumbnailCompletions.removeFirst().finish(nil, false)
    #expect(adapter.switcherThumbnail(item: item, live: live) === image)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

    adapter.windowHost(host, captureSwitcherThumbnailsForTabs: [tabAPI])
    adapter.windowHost(host, invalidateSwitcherThumbnailForTab: tabAPI)
    #expect(adapter.switcherThumbnail(item: item, live: live) == nil)
    try #require(fake.thumbnailCompletions.count == 1)
    _ = fake.thumbnailCompletions.removeFirst().finish(image, false)
    #expect(adapter.switcherThumbnail(item: item, live: live) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

enum SwitcherReserveFailure: CaseIterable {
    case visible, hidden, navigated, navigatedAfterScheduling, replacedAfterScheduling, cached, cachedAfterScheduling
}

@Test(arguments: SwitcherReserveFailure.allCases)
@MainActor
func switcherReserveRetriesOnlyWhileTheSameDocumentIsShownAndUncached(_ scenario: SwitcherReserveFailure) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (adapter, fake, host, tab) = try privateThumbnailFixture(in: dir)
    defer { adapter.shutdown() }
    let tabAPI = try #require(tab as? any ARTabAPI)

    func cachePrehideImage() throws {
        adapter.windowHost(host, captureSwitcherThumbnailsForTabs: [tabAPI])
        try #require(fake.thumbnailCompletions.count == 1)
        _ = fake.thumbnailCompletions.removeFirst().finish(NSImage(size: NSSize(width: 156, height: 104)), false)
    }

    adapter.windowHost(host, reserveSwitcherThumbnailForTab: tabAPI, afterDelay: 0)
    try await matrixWait { fake.thumbnailCompletions.count == 1 }
    let initial = fake.thumbnailCompletions.removeFirst()
    #expect(!initial.retry)
    if scenario == .hidden { tab.thumbnailVisible = false }
    if scenario == .navigated { adapter.windowHost(host, invalidateSwitcherThumbnailForTab: tabAPI) }
    if scenario == .cached { try cachePrehideImage() }
    if scenario == .visible {
        adapter.windowHost(host, reserveSwitcherThumbnailForTab: tabAPI, afterDelay: 0)
    }
    let scheduled = initial.finish(nil, true)
    let expected: [SwitcherReserveFailure] = [.visible, .navigatedAfterScheduling, .replacedAfterScheduling, .cachedAfterScheduling]
    #expect(scheduled == expected.contains(scenario))
    if scenario == .navigatedAfterScheduling { adapter.windowHost(host, invalidateSwitcherThumbnailForTab: tabAPI) }
    if scenario == .replacedAfterScheduling {
        fake.entries = [MatrixFakeTab(item: try #require(tab.itemId), live: tab.liveId, profile: tab.profile, owner: fake)]
    }
    if scenario == .cachedAfterScheduling { try cachePrehideImage() }

    try await Task.sleep(for: .milliseconds(2200))
    guard scenario == .visible else {
        #expect(fake.thumbnailCompletions.isEmpty)
        return
    }
    try #require(fake.thumbnailCompletions.count == 1)
    let retry = fake.thumbnailCompletions.removeFirst()
    #expect(retry.retry)
    #expect(!retry.finish(nil, true))
}

@Test @MainActor
func privateWindowWaitsForTheRegularSeedBaseline() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("workspace.sqlite").path
    let runtime = Runtime(windowID: "regular")
    let session = WorkspaceSession()
    runtime.adapter = try EngineAdapter(path: path, windowID: runtime.windowID, card: NSView(), session: session)
    let seed = try session.queue.sync {
        let store = try #require(session.store)
        return try store.createTab(windowId: runtime.windowID, url: "about:blank")
    }
    let item = try #require(seed.selectedId)
    runtime.snapshot = seed
    runtime.sliceActive = item
    runtime.browserCheckSeedID = item
    runtime.browserCheckPhase = 1
    runtime.quitPath = path
    let (fake, host) = matrixFake()
    let tab = MatrixFakeTab(item: item, live: "live", profile: "Default", owner: fake)
    tab.title = "Settled"
    tab.url = "about:blank?settled"
    fake.entries = [tab]
    fake.active = item

    func tick() { runtime.privateWindowCheckTick(host, screen: false) }
    tick()
    #expect(runtime.privateWindowCheck?.waitName == "regular seed navigation")
    tab.navigationCount = 1
    runtime.quitPath = nil
    tick()
    #expect(runtime.privateWindowCheck?.waitName == "regular rows capture failed")
    runtime.quitPath = path
    tick()
    #expect(runtime.privateWindowCheck?.waitName == "regular seed metadata")
    #expect(runtime.quitBefore == nil && runtime.browserCheckPhase == 1 && fake.incognitoOpens == 0)

    func persistMetadata(revision: UInt64, url: String, title: String?) throws {
        let live = LiveTab(offTheRecord: false, profile: .default, liveId: tab.liveId,
                           item: item, opener: nil, navigated: true, url: url, title: title)
        let strip = LiveStrip(window: runtime.windowID, tabs: [live], active: live.liveId)
        let transaction = LiveTransaction(offTheRecord: false, epoch: 1, rev: revision,
                                          cause: .engine, strips: [strip])
        runtime.snapshot = try session.queue.sync {
            let store = try #require(session.store)
            let applied = try store.liveApply(transaction: transaction).applied
            try #require(applied)
            return store.snapshot(windowId: runtime.windowID)
        }
    }
    try persistMetadata(revision: 0, url: "about:blank", title: tab.title)
    tick()
    #expect(runtime.quitBefore == nil && fake.incognitoOpens == 0)
    try persistMetadata(revision: 1, url: tab.url, title: "")
    tick()
    #expect(runtime.quitBefore == nil && fake.incognitoOpens == 0)
    let staleSnapshot = runtime.snapshot
    try persistMetadata(revision: 2, url: tab.url, title: tab.title)
    let settledSnapshot = runtime.snapshot
    runtime.snapshot = staleSnapshot
    tick()
    #expect(runtime.privateWindowCheck?.waitName == "regular seed snapshot")
    #expect(runtime.quitBefore == nil && fake.incognitoOpens == 0)
    runtime.snapshot = settledSnapshot
    tick()
    let baseline = try #require(runtime.quitBefore)
    #expect(checkStoredTabMetadata(baseline, item: item, url: tab.url, title: tab.title))
    #expect(runtime.browserCheckPhase == 2 && fake.incognitoOpens == 1)

    runtime.browserCheckPhase = 10
    runtime.quitPath = nil
    tick()
    #expect(runtime.privateWindowCheck?.waitName == "regular rows capture failed")
    #expect(runtime.browserCheckPhase == 10 && fake.incognitoOpens == 1)
    runtime.quitPath = path
    try persistMetadata(revision: 3, url: tab.url, title: "Changed after opening")
    tick()
    #expect(runtime.privateWindowCheck?.waitName == "regular rows changed")
    #expect(runtime.quitBefore == baseline && fake.incognitoOpens == 1)
    try persistMetadata(revision: 4, url: tab.url, title: tab.title)
    tick()
    #expect(runtime.privateWindowCheck?.conditions["private_rows_unchanged"] == true)
    #expect(runtime.browserCheckPhase == 11 && fake.incognitoOpens == 2)
}

@Test @MainActor
func synchronousSplitSelectionUpdatesURLAndCopyBeforeActivation() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "focus", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    try session.queue.sync { try session.store!.showSpace(windowId: "focus", spaceId: "named") }
    let runtime = Runtime(windowID: "focus")
    let (fake, host) = matrixFake()
    let tab = MatrixFakeTab(item: "close-split-a", live: "live-a", profile: "Profile 1", owner: fake)
    tab.url = "http://127.0.0.1:1234/search"
    let other = MatrixFakeTab(item: "close-split-b", live: "live-b", profile: "Profile 1", owner: fake)
    fake.entries = [tab, other]
    fake.active = "close-split-b"
    runtime.host = host
    var applied = false
    engine.onTransaction = { _, accepted in applied = accepted }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "focus", epoch: 1, rev: 0, command: nil))
    try await matrixWait { applied }
    let snapshot = try session.queue.sync { try session.store!.selectItem(windowId: "focus", id: "close-split-a") }
    let sidebar = SidebarView(snapshot: snapshot)
    runtime.sidebar = sidebar
    let pasteboard = NSPasteboard(name: .init("split-sync-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    sidebar.pasteboard = pasteboard
    sidebar.focusedPane = ("close-split-b", "http://localhost:1234/search")
    runtime.showAndSelect(.success(snapshot))
    #expect(fake.active == "close-split-b")
    #expect(sidebar.focusedPane?.id == "close-split-a")
    #expect(sidebar.focusedPane?.url == tab.url)
    #expect(sidebar.urlHostForCheck == "127.0.0.1")
    sidebar.copySelectedLinkForCommand()
    #expect(pasteboard.string(forType: .string) == tab.url)
    var published = false
    engine.onSnapshot = { value in
        #expect(value.selectedId == "close-split-a")
        runtime.updateSidebar(value)
        published = true
    }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "focus", epoch: 1, rev: 1, command: nil))
    try await matrixWait { published }
    #expect(fake.active == "close-split-b")
    #expect(sidebar.focusedPane?.id == "close-split-a")
    #expect(sidebar.focusedPane?.url == tab.url)
    #expect(sidebar.urlHostForCheck == "127.0.0.1")
    sidebar.copySelectedLinkForCommand()
    #expect(pasteboard.string(forType: .string) == tab.url)
    tab.url = ""
    runtime.showAndSelect(.success(snapshot))
    #expect(sidebar.focusedPane?.url == "about:blank")
    sidebar.copySelectedLinkForCommand()
    #expect(pasteboard.string(forType: .string) == "about:blank")
    published = false
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "focus", epoch: 1, rev: 2, command: nil))
    try await matrixWait { published }
    #expect(sidebar.focusedPane?.id == "close-split-a")
    #expect(sidebar.focusedPane?.url == "about:blank")
    sidebar.copySelectedLinkForCommand()
    #expect(pasteboard.string(forType: .string) == "about:blank")
    fake.entries = []
    runtime.showAndSelect(.success(snapshot))
    #expect(sidebar.focusedPane?.id == "close-split-a")
    #expect(sidebar.focusedPane?.url == "about:blank")
    sidebar.copySelectedLinkForCommand()
    #expect(pasteboard.string(forType: .string) == "about:blank")
    var empty = snapshot
    empty.selectedId = nil
    runtime.show(empty)
    #expect(sidebar.focusedPane == nil)
    withExtendedLifetime(engine) {}
}

@MainActor
private func matrixWait(polls: Int = 200, _ predicate: () -> Bool) async throws {
    for _ in 0..<polls {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw NSError(domain: "matrix-fixture-timeout", code: 1)
}

@MainActor
private func matrixTransaction(_ fake: MatrixFakeHost, window: String, epoch: UInt64, rev: UInt64, command: String?, crashedItem: String? = nil) -> [String: Any] {
    let tabs: [[String: Any]] = fake.entries.map { tab in
        ["off_the_record": false, "profile": tab.profile, "live_id": tab.liveId, "item": tab.itemId as Any? ?? NSNull(),
         "opener": NSNull(), "url": NSNull(), "title": NSNull(), "navigated": false, "crashed": tab.itemId != nil && tab.itemId == crashedItem]
    }
    return ["off_the_record": false, "epoch": NSNumber(value: epoch), "rev": NSNumber(value: rev),
            "cause": command.map { ["Command": $0] } as Any? ?? "Engine",
            "strips": [["window": window, "tabs": tabs,
                         "active": fake.entries.first(where: { $0.itemId == fake.active })?.liveId as Any? ?? NSNull()]]]
}

@Test @MainActor
func littleWindowHandoffAdoptsTheMovedTabWhenTheDestinationBecomesKey() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let adapter = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "destination", card: NSView(), seedProfiles: true, session: session)
    let (target, host) = matrixFake()
    adapter.attach(host)
    defer { adapter.shutdown() }
    var applied = false
    adapter.onTransaction = { _, accepted in applied = accepted }
    adapter.windowHost(host, didReceiveTransaction: matrixTransaction(target, window: "destination", epoch: 1, rev: 0, command: nil))
    try await matrixWait { applied }
    adapter.beginLittleWindowHandoff()
    let item = try session.queue.sync { try #require(session.store?.createTab(windowId: "destination", url: "https://example.test/").selectedId) }
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: target.window())
    adapter.awaitLittleWindowHandoff(item: item, live: "chrome-moved")
    try await Task.sleep(for: .milliseconds(100))
    #expect(target.opened.isEmpty)
    applied = false
    adapter.windowHost(host, didReceiveTransaction: matrixTransaction(target, window: "destination", epoch: 1, rev: 1, command: nil))
    try await matrixWait { applied }
    #expect(target.opened.isEmpty)
    let tab = MatrixFakeTab(item: item, live: "chrome-moved", profile: "Default", owner: target)
    target.entries.append(tab)
    target.active = item
    applied = false
    adapter.windowHost(host, didReceiveTransaction: matrixTransaction(target, window: "destination", epoch: 1, rev: 2, command: nil))
    try await matrixWait { applied || !target.opened.isEmpty }
    #expect(target.opened.isEmpty)
    #expect(session.queue.sync { session.store?.liveTab(item: item) } == "chrome-moved")
    #expect(applied)
}

@Test @MainActor
func aFailedLittleWindowHandoffReplaysTheKeySelection() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let adapter = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "destination", card: NSView(), seedProfiles: true, session: session)
    let (target, host) = matrixFake()
    adapter.attach(host)
    defer { adapter.shutdown() }
    let item = try session.queue.sync { () -> String in
        let store = try #require(session.store)
        return try #require(store.createTab(windowId: "destination", url: "https://example.test/").selectedId)
    }
    adapter.beginLittleWindowHandoff()
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: target.window())
    #expect(target.opened.isEmpty)
    adapter.endLittleWindowHandoff()
    try await matrixWait { !target.opened.isEmpty }
    #expect(target.entries.first?.itemId == item)
}

private enum LittleWindowOpenInOutcome: CaseIterable {
    case transferred, refused, superseded, createFailed
}

@Test(arguments: LittleWindowOpenInOutcome.allCases) @MainActor
private func littleWindowOpenInTransfersThePageOrRollsBackTheMove(outcome: LittleWindowOpenInOutcome) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let window = "destination"
    let space = "handoff-space"
    let path = dir.appendingPathComponent("db").path
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: path, windowID: window,
                                   card: NSView(), seedProfiles: true, session: session)
    let (target, host) = matrixFake()
    let (source, popupHost) = matrixFake()
    let runtime = Runtime(windowID: window)
    runtime.host = host
    runtime.adapter = engine
    runtime.workspace = WorkspaceAdapter(windowID: window, session: session)
    engine.attach(host)
    engine.onSnapshot = { [weak runtime] snapshot in runtime?.show(snapshot) }
    defer { engine.shutdown() }

    let saved = try session.queue.sync {
        let store = try #require(session.store)
        _ = try store.createSpace(windowId: window, name: "Handoff", spaceId: space)
        let item = try #require(store.createTab(windowId: window, url: "https://saved.example/").selectedId)
        let pinned = try #require(store.snapshot(windowId: window).spaces.first { $0.id == space }?.pinnedId)
        _ = try store.moveItem(windowId: window, id: item, container: pinned, index: 0, openFolder: false)
        _ = try store.closeItem(windowId: window, id: item)
        _ = try store.createSpace(windowId: window, name: "Later", spaceId: "later")
        try store.showSpace(windowId: window, spaceId: "default")
        return item
    }
    func snapshot() -> WorkspaceSnapshot {
        session.queue.sync { session.store!.snapshot(windowId: window) }
    }
    runtime.show(snapshot())
    #expect(snapshot().spaces.first { $0.id == space }?.pinned.first?.unloaded == true)

    let popup = PopupHost()
    popup.rootView.addSubview(popup.card)
    popup.host = popupHost
    let original = MatrixFakeTab(item: "original", live: "chrome-moved", profile: "Default", owner: source)
    original.url = "https://moved.example/"
    source.entries = [original]
    let controller = LittleWindowController(popup: popup, origin: runtime, profile: "Default", frame: .zero,
                                            url: original.url, commandBarVisible: false)
    defer { popup.littleWindow = nil }
    try await matrixWait { controller.model.openEnabled }
    if outcome == .createFailed {
        try session.queue.sync { try session.store!.flush() }
        var connection: OpaquePointer?
        defer {
            target.onSetProfile = nil
            sqlite3_close(connection)
        }
        try #require(sqlite3_open(path, &connection) == SQLITE_OK)
        var preparations = 0
        target.onSetProfile = {
            preparations += 1
            if preparations == 1 {
                #expect(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
            } else {
                #expect(session.queue.sync { session.store?.lastError() } != nil)
                #expect(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            }
        }
        controller.performOpenIn(spaceID: space)
        try await matrixWait(polls: 400) { target.active == saved }
        #expect(preparations == 2)
        #expect(runtime.snapshot.selectedId == saved)
        #expect(snapshot().spaces.first { $0.id == space }?.today.isEmpty == true)
        #expect(target.entries.map(\.itemId) == [saved])
        #expect(target.handoffAttempts == 0)
        #expect(original.itemId == "original" && original.owner === source)
        #expect(source.entries.first === original && source.closeRequests == 0)
        return
    }
    target.refuseHandoff = outcome != .transferred
    target.onSetProfile = { [weak target] in
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: target?.window())
    }
    controller.performOpenIn(spaceID: space)
    try await matrixWait { target.handoffAttempts > 0 }
    let row = try #require(original.itemId)
    #expect(row != "original")
    #expect(target.opened.isEmpty)
    #expect(snapshot().shownSpaceId == space)
    #expect(snapshot().spaces.first { $0.id == space }?.today.contains { $0.id == row } == true)

    if outcome == .transferred {
        #expect(controller.checkOpenedIn?.item == row)
        var applied = false
        engine.onTransaction = { _, accepted in applied = accepted }
        engine.windowHost(host, didReceiveTransaction: matrixTransaction(target, window: window, epoch: 1, rev: 0, command: nil))
        try await matrixWait { applied }
        #expect(target.opened.isEmpty)
        #expect(target.activated == ["handoff"])
        #expect(target.active == row)
        #expect(runtime.snapshot.selectedId == row)
        #expect(session.queue.sync { session.store?.liveTab(item: row) } == original.liveId)
        #expect(session.queue.sync { session.store?.liveTab(item: saved) } == nil)
        return
    }

    if outcome == .superseded {
        runtime.switchWorkspaceSpace("later")
        try await matrixWait {
            original.itemId == "original" && snapshot().spaces.first { $0.id == space }?.today.isEmpty == true
        }
        #expect(snapshot().shownSpaceId == "later")
        #expect(target.opened.isEmpty)
        #expect(target.handoffAttempts == 1)
    } else {
        try await matrixWait(polls: 2400) { original.itemId == "original" && !target.opened.isEmpty }
        #expect(target.entries.map(\.itemId) == [saved])
    }
    #expect(original.owner === source)
    #expect(source.entries.first === original)
    #expect(source.closeRequests == 0)
    #expect(controller.checkOpenedIn == nil)
    #expect(snapshot().spaces.first { $0.id == space }?.today.isEmpty == true)
}

@Test @MainActor
func closeFromAnotherWindowReachesTheOwningHost() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let owner = try EngineAdapter(path: path, windowID: "owner", card: NSView(), seedProfiles: true, session: session)
    let requester = try EngineAdapter(path: path, windowID: "requester", card: NSView(), session: session)
    let (source, sourceHost) = matrixFake()
    let (target, targetHost) = matrixFake()
    owner.attach(sourceHost)
    requester.attach(targetHost)
    let item = try session.queue.sync { () -> String in
        let store = try #require(session.store)
        return try #require(store.snapshot(windowId: "owner").spaces.first(where: { $0.id == "default" })?.today.first).id
    }
    owner.select(id: item, url: "about:blank")
    try await matrixWait { source.opened.count == 1 }
    var applied = false
    owner.onTransaction = { _, accepted in applied = accepted }
    owner.windowHost(sourceHost, didReceiveTransaction: matrixTransaction(source, window: "owner", epoch: 1, rev: 0, command: source.opened[0]))
    try await matrixWait { applied }
    requester.close(id: item)
    try await matrixWait { source.closed.count == 1 }
    #expect(target.closed.isEmpty)
    owner.shutdown()
    requester.shutdown()
}

@Test @MainActor
func selectingRemotePageTransfersItsLiveIdentity() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let owner = try EngineAdapter(path: path, windowID: "owner", card: NSView(), seedProfiles: true, session: session)
    let destination = try EngineAdapter(path: path, windowID: "destination", card: NSView(), session: session)
    let (source, sourceHost) = matrixFake()
    let (target, targetHost) = matrixFake()
    owner.attach(sourceHost); destination.attach(targetHost)
    let item = try session.queue.sync { () -> String in
        let store = try #require(session.store)
        try store.showSpace(windowId: "destination", spaceId: "default")
        return try #require(store.snapshot(windowId: "owner").spaces.first(where: { $0.id == "default" })?.today.first).id
    }
    owner.select(id: item, url: "about:blank")
    try await matrixWait { source.opened.count == 1 }
    var applied = false
    owner.onTransaction = { _, accepted in applied = accepted }
    owner.windowHost(sourceHost, didReceiveTransaction: matrixTransaction(source, window: "owner", epoch: 1, rev: 0, command: source.opened[0]))
    try await matrixWait { applied }
    let live = source.opened[0]
    target.transferFailures = 2
    destination.select(id: item, url: "about:blank")
    try await matrixWait { target.activated.count == 1 }
    #expect(target.transferAttempts == 3)
    #expect(source.entries.isEmpty && target.entries.first?.liveId == live)
    let left = matrixTransaction(source, window: "owner", epoch: 1, rev: 1, command: nil)["strips"] as! [[String: Any]]
    let right = matrixTransaction(target, window: "destination", epoch: 1, rev: 1, command: nil)["strips"] as! [[String: Any]]
    var paired = matrixTransaction(target, window: "destination", epoch: 1, rev: 1, command: target.activated[0])
    paired["strips"] = left + right
    var moved = false
    destination.onTransaction = { _, accepted in moved = accepted }
    destination.windowHost(targetHost, didReceiveTransaction: paired)
    try await matrixWait { moved }
    try session.queue.sync {
        let store = try #require(session.store)
        #expect(store.liveWindow(item: item) == "destination")
        #expect(store.snapshot(windowId: "owner").selectedId == item)
        #expect(store.snapshot(windowId: "destination").selectedId == item)
        #expect(try store.pendingHistoryPurges().isEmpty)
    }
    #expect(source.captureCompletions.count >= 2)
    source.captureCompletions[0](NSImage(size: NSSize(width: 2, height: 2)))
    await Task.yield()
    #expect(session.snapshot(live) == nil)
    source.captureCompletions[1](NSImage(size: NSSize(width: 2, height: 2)))
    try await matrixWait { session.snapshot(live) != nil }
    session.invalidateSnapshot(live)
    let movedTab = try #require(target.entries.first) as! any ARTabAPI
    session.captureSnapshot(movedTab, item: item)
    #expect(target.captureCompletions.count == 1)
    target.captureCompletions[0](nil)
    await Task.yield()
    #expect(session.snapshot(live) == nil)
    session.captureSnapshot(movedTab, item: item)
    #expect(target.captureCompletions.count == 2)
    session.invalidateSnapshot(live)
    target.captureCompletions[1](NSImage(size: NSSize(width: 2, height: 2)))
    await Task.yield()
    #expect(session.snapshot(live) == nil)
    owner.refresh()
    try await matrixWait { source.remotePlaceholder }
    source.transferFailures = 100
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: source.window())
    try await matrixWait { source.transferAttempts > 0 }
    source.closing = true
    try await matrixWait { (owner.checkSelectionState()["pending_commands"] as? [String] ?? []).isEmpty }
    #expect(target.entries.first?.liveId == live)
    #expect(session.queue.sync { session.store?.liveWindow(item: item) } == "destination")
    source.closing = false
    owner.shutdown(); destination.shutdown()
}

@Test @MainActor
func acceptedCloseHandsSharedPageToMostRecentEligibleWindow() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let sourceEngine = try EngineAdapter(path: path, windowID: "source", card: NSView(), seedProfiles: true, session: session)
    let first = try EngineAdapter(path: path, windowID: "first", card: NSView(), session: session)
    let recent = try EngineAdapter(path: path, windowID: "recent", card: NSView(), session: session)
    let (source, sourceHost) = matrixFake()
    let (firstFake, firstHost) = matrixFake()
    let (recentFake, recentHost) = matrixFake()
    sourceEngine.attach(sourceHost); first.attach(firstHost); recent.attach(recentHost)
    let item = try session.queue.sync { () -> String in
        let store = try #require(session.store)
        return try #require(store.snapshot(windowId: "source").spaces.first(where: { $0.id == "default" })?.today.first).id
    }
    sourceEngine.select(id: item, url: "about:blank")
    try await matrixWait { source.opened.count == 1 }
    var applied = false
    sourceEngine.onTransaction = { _, accepted in applied = accepted }
    sourceEngine.windowHost(sourceHost, didReceiveTransaction: matrixTransaction(source, window: "source", epoch: 1, rev: 0, command: source.opened[0]))
    try await matrixWait { applied }
    try session.queue.sync {
        let store = try #require(session.store)
        for window in ["first", "recent"] {
            try store.showSpace(windowId: window, spaceId: "default")
            _ = try store.selectItem(windowId: window, id: item)
        }
    }
    session.noteKey(window: "first"); session.noteKey(window: "recent")
    source.closing = true
    sourceEngine.windowHostWillBeginClosing(sourceHost)
    #expect(source.entries.count == 1 && firstFake.entries.isEmpty && recentFake.entries.isEmpty)
    recentFake.profileReady = false
    var finished: Bool?
    sourceEngine.windowHost(sourceHost, prepareCloseHandoff: { finished = $0 })
    #expect(finished == nil && source.entries.count == 1)
    #expect(recentFake.preparedProfiles == ["Default"])
    recentFake.closing = true
    try await matrixWait { finished != nil }
    #expect(finished == false && source.entries.count == 1 && recentFake.entries.isEmpty)
    recentFake.closing = false
    finished = nil
    sourceEngine.windowHost(sourceHost, prepareCloseHandoff: { finished = $0 })
    recentFake.profileReady = true
    try await matrixWait { finished != nil }
    #expect(finished == true && source.entries.isEmpty && firstFake.entries.isEmpty)
    #expect(recentFake.entries.first?.itemId == item)
    source.closing = false
    sourceEngine.shutdown(); first.shutdown(); recent.shutdown()
}

@Test @MainActor
func cancelledDividerGestureStaysCancelledUntilMouseUp() throws {
    let divider = SplitDividerView(frame: NSRect(x: 0, y: 0, width: 4, height: 100))
    var moves: [CGFloat] = []
    divider.onMove = { delta, _ in moves.append(delta) }
    func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 0), modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    divider.mouseDown(with: try event(.leftMouseDown, 0))
    divider.mouseDragged(with: try event(.leftMouseDragged, 10))
    divider.cancelDrag()
    divider.mouseDragged(with: try event(.leftMouseDragged, 20))
    divider.mouseUp(with: try event(.leftMouseUp, 20))
    #expect(moves == [10])
    divider.mouseDown(with: try event(.leftMouseDown, 20))
    divider.mouseDragged(with: try event(.leftMouseDragged, 25))
    #expect(moves == [10, 5])
}

@Test @MainActor
func partialHandoffFailureKeepsBothPagesAndCancelsClose() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let sourceEngine = try EngineAdapter(path: path, windowID: "source", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    let targetEngine = try EngineAdapter(path: path, windowID: "target", card: NSView(), session: session)
    let (source, sourceHost) = matrixFake()
    let (target, targetHost) = matrixFake()
    sourceEngine.attach(sourceHost); targetEngine.attach(targetHost)
    try session.queue.sync {
        let store = try #require(session.store)
        for window in ["source", "target"] {
            try store.showSpace(windowId: window, spaceId: "named")
            _ = try store.selectItem(windowId: window, id: "close-split-a")
        }
    }
    source.shownProfile = "Profile 1"
    sourceEngine.select(id: "close-split-a", url: "about:blank")
    try await matrixWait { source.opened.count == 1 }
    sourceEngine.windowHost(sourceHost, didReceiveTransaction: matrixTransaction(source, window: "source", epoch: 1, rev: 0, command: source.opened[0]))
    try await matrixWait { source.backgroundOpened.count == 1 }
    sourceEngine.windowHost(sourceHost, didReceiveTransaction: matrixTransaction(source, window: "source", epoch: 1, rev: 1, command: source.backgroundOpened[0]))
    try await matrixWait { session.queue.sync { session.store?.liveTab(item: "close-split-b") != nil } }
    for tab in source.entries { tab.liveId = tab.itemId == "close-split-a" ? "live-a" : "live-b" }
    sourceEngine.windowHost(sourceHost, didReceiveTransaction: matrixTransaction(source, window: "source", epoch: 2, rev: 0, command: nil))
    try await matrixWait { session.queue.sync { session.store?.liveTab(item: "close-split-a") == "live-a" && session.store?.liveTab(item: "close-split-b") == "live-b" } }
    target.failHandoffAt = 2
    source.closing = true
    sourceEngine.windowHostWillBeginClosing(sourceHost)
    var finished: Bool?
    sourceEngine.windowHost(sourceHost, prepareCloseHandoff: { finished = $0 })
    try await matrixWait { finished != nil }
    #expect(finished == false && source.entries.count == 1 && target.entries.count == 1)
    #expect(Set((source.entries + target.entries).compactMap(\.itemId)) == ["close-split-a", "close-split-b"])
    let movedItem = try #require(target.entries.first?.itemId)
    #expect(movedItem == "close-split-a")
    let sourceStrip = matrixTransaction(source, window: "source", epoch: 2, rev: 1, command: nil)["strips"] as! [[String: Any]]
    let targetStrip = matrixTransaction(target, window: "target", epoch: 2, rev: 1, command: nil)["strips"] as! [[String: Any]]
    var paired = matrixTransaction(target, window: "target", epoch: 2, rev: 1, command: nil)
    paired["strips"] = sourceStrip + targetStrip
    paired["cause"] = "Chrome"
    var applied = false
    targetEngine.onTransaction = { _, accepted in applied = accepted }
    targetEngine.windowHost(targetHost, didReceiveTransaction: paired)
    try await matrixWait { applied }
    applied = false
    var later = matrixTransaction(source, window: "source", epoch: 2, rev: 2, command: nil)
    later["cause"] = "Chrome"
    sourceEngine.onTransaction = { _, accepted in applied = accepted }
    sourceEngine.windowHost(sourceHost, didReceiveTransaction: later)
    #expect(!applied)
    try session.queue.sync {
        let store = try #require(session.store)
        #expect(store.liveWindow(item: movedItem) == "target")
        #expect(store.snapshot(windowId: "source").selectedId == "close-split-a")
        #expect(try store.pendingHistoryPurges().isEmpty)
        let rows = store.snapshot(windowId: "source").spaces.flatMap(\.pinned)
        #expect(rows.contains { $0.id == "close-split" })
        #expect(["close-split-a", "close-split-b"].allSatisfy { id in rows.contains { $0.id == id && !$0.unloaded } })
    }
    source.closing = false
    sourceEngine.windowHostClosingAllCancelled(sourceHost)
    sourceEngine.shutdown(); targetEngine.shutdown()
}

@Test @MainActor
func selectingSplitOpensSiblingInBackgroundAndProjectsBothFrames() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let card = NSView(frame: NSRect(x: 0, y: 0, width: 804, height: 600))
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "split", card: card, seedProfiles: true, seedSplitCheck: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    try session.queue.sync {
        let store = try #require(session.store)
        try store.showSpace(windowId: "split", spaceId: "named")
        _ = try store.selectItem(windowId: "split", id: "close-split-a")
    }
    fake.shownProfile = "Profile 1"
    engine.select(id: "close-split-a", url: "about:blank")
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "split", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait { fake.backgroundOpened.count == 1 }
    #expect(fake.active == "close-split-a")
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "split", epoch: 1, rev: 1, command: fake.backgroundOpened[0]))
    try await matrixWait { fake.splitFrames.count == 2 }
    #expect(Set(fake.splitFrames.keys) == ["close-split-a", "close-split-b"])
    #expect(fake.active == "close-split-a")
    engine.close(id: "close-split")
    try await matrixWait { fake.closed.count == 2 }
    #expect(fake.closed[0] != fake.closed[1])
    engine.shutdown()
}

enum ReactivationTarget: CaseIterable {
    case current, gone, superseded
}

@Test(arguments: ReactivationTarget.allCases) @MainActor
func offSpaceReactivationChecksTheWindowInTheStrip(target: ReactivationTarget) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let first = try EngineAdapter(path: path, windowID: "first", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    let second = try EngineAdapter(path: path, windowID: "second", card: NSView(), session: session)
    let (a, aHost) = matrixFake()
    let (b, bHost) = matrixFake()
    first.attach(aHost)
    second.attach(bHost)
    defer { first.shutdown(); second.shutdown() }

    let previous = "close-split-a"
    a.entries = [MatrixFakeTab(item: previous, live: "live-previous", profile: "Profile 1", owner: a)]
    a.active = previous
    var lastApplied: UInt64?
    first.onTransaction = { if $1 { lastApplied = $0.rev } }
    second.onTransaction = first.onTransaction
    first.windowHost(aHost, didReceiveTransaction: matrixTransaction(a, window: "first", epoch: 1, rev: 0, command: nil))
    try await matrixWait { lastApplied == 0 }
    let url = "about:blank?new-selection"
    let item = try session.queue.sync {
        let store = try #require(session.store)
        try store.showSpace(windowId: "first", spaceId: "default")
        return try #require(store.createTab(windowId: "first", url: url).selectedId)
    }
    first.select(id: item, url: url)
    try await matrixWait { a.opened.count == 1 }

    var transaction = matrixTransaction(b, window: "second", epoch: 1, rev: 1, command: nil)
    let offSpace = matrixTransaction(a, window: "first", epoch: 1, rev: 1, command: nil)
    var firstStrip = try #require((offSpace["strips"] as? [[String: Any]])?.first)
    firstStrip["active"] = "live-previous"
    transaction["strips"] = try #require(transaction["strips"] as? [[String: Any]]) + [firstStrip]
    transaction["cause"] = "Chrome"
    var resolutions: [String] = []
    first.checkSelectionDispatch = { stage, _, resume in
        if stage == "resolved" { resolutions.append("first") }
        resume()
    }
    second.checkSelectionDispatch = { stage, _, resume in
        if stage == "resolved" { resolutions.append("second") }
        resume()
    }
    if target == .gone { first.shutdown() }
    second.windowHost(bHost, didReceiveTransaction: transaction)
    if target == .superseded { first.invalidateSelection() }
    try await matrixWait { lastApplied == 1 }
    if target != .current {
        #expect(a.activated.isEmpty)
        #expect(b.activated.isEmpty)
        if target == .gone { first.attach(aHost) }
        transaction["rev"] = NSNumber(value: 2)
        second.windowHost(bHost, didReceiveTransaction: transaction)
        try await matrixWait { lastApplied == 2 }
    }
    try await matrixWait { !a.activated.isEmpty || b.transferAttempts > 0 }
    #expect(a.active == item)
    #expect(a.activated.count == 1)
    #expect(b.transferAttempts == 0)
    #expect(resolutions == ["first"])
}

@Test @MainActor
func closeSuccessorDoesNotDispatchOverAnInFlightClick() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "close-race", card: NSView(), session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    defer { engine.shutdown() }

    let url = "about:blank"
    let (clicked, successor, closed) = try session.queue.sync {
        let store = try #require(session.store)
        let clicked = try #require(store.createTab(windowId: "close-race", url: url + "?clicked").selectedId)
        let successor = try #require(store.createTab(windowId: "close-race", url: url + "?successor").selectedId)
        let closed = try #require(store.createTab(windowId: "close-race", url: url + "?closed").selectedId)
        return (clicked, successor, closed)
    }
    fake.entries = [clicked, successor, closed].map { MatrixFakeTab(item: $0, live: "live-\($0)", profile: "Default", owner: fake) }
    fake.active = closed
    var lastApplied: UInt64?
    engine.onTransaction = { if $1 { lastApplied = $0.rev } }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "close-race", epoch: 1, rev: 0, command: nil))
    try await matrixWait { lastApplied == 0 }

    var heldClick: (() -> Void)?
    var clickCommand: String?
    var resolved: [String] = []
    engine.checkSelectionDispatch = { stage, command, resume in
        if stage == "registered" {
            clickCommand = command
            heldClick = resume
        } else {
            resolved.append(command)
            resume()
        }
    }
    engine.select(id: clicked, url: url + "?clicked")
    try await matrixWait { heldClick != nil }

    fake.entries.removeAll { $0.itemId == closed }
    fake.active = nil
    var close = matrixTransaction(fake, window: "close-race", epoch: 1, rev: 1, command: nil)
    close["cause"] = "Chrome"
    engine.windowHost(host, didReceiveTransaction: close)
    try await matrixWait { lastApplied == 1 }
    #expect(session.queue.sync { session.store?.selectedItem(windowId: "close-race") } == successor)

    let command = try #require(clickCommand)
    let resume = try #require(heldClick)
    resume()
    try await matrixWait { fake.activated.contains(command) }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "close-race", epoch: 1, rev: 2, command: command))
    try await matrixWait { lastApplied == 2 }
    #expect(session.queue.sync { session.store?.selectedItem(windowId: "close-race") } == clicked)
    #expect(fake.active == clicked)
    #expect(fake.activated == [command])
    #expect(resolved == [command])
}

@Test(arguments: [false, true], [false, true]) @MainActor
func aCloseLoadsOnlyAnUnloadedSuccessor(appClose: Bool, unloaded: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "successor", card: NSView(), session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    defer { engine.shutdown() }

    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let (open, neighbour) = try session.queue.sync { () -> (String, String) in
        let store = try #require(session.store)
        _ = try store.importArcSidebar(windowId: "successor", json: String(contentsOf: fixture, encoding: .utf8),
                                       windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
        try store.showSpace(windowId: "successor", spaceId: "space-work")
        // The import leaves tab-spec Unloaded; moving it into Today puts an unloaded row above
        // the row the close removes, which is the successor the rule picks.
        _ = try store.moveItem(windowId: "successor", id: "tab-spec", container: "today-work", index: 0, openFolder: false)
        return (try #require(store.createTab(windowId: "successor", url: "about:blank?open").selectedId), "tab-spec")
    }
    fake.entries = [MatrixFakeTab(item: open, live: "live-open", profile: "Default", owner: fake)]
    fake.active = "live-open"
    var lastApplied: UInt64?
    engine.onTransaction = { if $1 { lastApplied = $0.rev } }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "successor", epoch: 1, rev: 0, command: nil))
    try await matrixWait { lastApplied == 0 }
    try session.queue.sync {
        let store = try #require(session.store)
        if !unloaded {
            _ = try store.selectItem(windowId: "successor", id: neighbour)
            _ = try store.selectItem(windowId: "successor", id: open)
        }
        let row = store.snapshot(windowId: "successor").spaces.flatMap(\.today).first { $0.id == neighbour }
        #expect(row?.unloaded == unloaded)
        #expect(store.liveTab(item: neighbour) == nil)
    }

    var command: String?
    if appClose {
        engine.close(id: open)
        try await matrixWait { fake.closed.count == 1 }
        command = try #require(fake.closed.first)
        #expect(fake.opened.isEmpty)
    }
    fake.entries.removeAll { $0.itemId == open }
    fake.active = nil
    var close = matrixTransaction(fake, window: "successor", epoch: 1, rev: 1, command: command)
    if !appClose { close["cause"] = "Chrome" }
    engine.windowHost(host, didReceiveTransaction: close)
    try await matrixWait { lastApplied == 1 }

    #expect(session.queue.sync { session.store?.selectedItem(windowId: "successor") } == neighbour)
    if unloaded {
        try await matrixWait { !fake.opened.isEmpty }
        let opened = try #require(session.queue.sync { session.store?.liveTab(item: neighbour) })
        #expect(fake.opened == [opened])
        #expect(fake.entries.map(\.itemId) == [neighbour])
        #expect(fake.entries.first?.liveId == opened)
    } else {
        #expect(session.queue.sync { session.store?.liveTab(item: neighbour) } == nil)
        #expect(fake.opened.isEmpty)
    }
}

@Test @MainActor
func addSplitUsesTheCurrentWindowSelectionBeforeTheSidebarRefreshes() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "split", card: NSView(), session: session)
    let runtime = Runtime(windowID: "split")
    runtime.adapter = engine
    let (fake, host) = matrixFake()
    engine.attach(host)
    runtime.host = host
    defer { engine.shutdown() }
    let (previous, current) = try session.queue.sync {
        let store = try #require(session.store)
        let previous = try store.createTab(windowId: "split", url: "about:blank?previous")
        let current = try #require(store.createTab(windowId: "split", url: "about:blank?current").selectedId)
        return (previous, current)
    }
    runtime.snapshot = previous
    #expect(runtime.addSplitViewTarget == current)
    runtime.performWorkspaceCommand("add_split_view")
    try await matrixWait { fake.opened.count == 1 }
    session.queue.sync {
        #expect(session.store?.splitLayout(itemId: current) != nil)
        #expect(previous.selectedId.flatMap { session.store?.splitLayout(itemId: $0) } == nil)
    }
}

private enum SelectionOwnershipChange: CaseIterable {
    case key, nonKey, unrelated
    case arrivingSibling, pendingSelection, singleTab
}

@Test(arguments: SelectionOwnershipChange.allCases) @MainActor
private func ownershipApplyReclaimsTheCurrentKeySelection(change: SelectionOwnershipChange) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let first = try EngineAdapter(path: path, windowID: "first", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    let second = try EngineAdapter(path: path, windowID: "second", card: NSView(), session: session)
    let (a, aHost) = matrixFake()
    let (b, bHost) = matrixFake()
    let left = "close-split-a"
    let right = "close-split-b"
    let other = try session.queue.sync {
        let store = try #require(session.store)
        for window in ["first", "second"] { try store.showSpace(windowId: window, spaceId: "named") }
        let item = try #require(store.createTab(windowId: "first", url: "about:blank?other").selectedId)
        if change == .arrivingSibling {
            let pinned = try #require(store.snapshot(windowId: "first").spaces.first { $0.id == "named" }?.pinnedId)
            _ = try store.moveItem(windowId: "first", id: item, container: pinned, index: 0, openFolder: false)
            _ = try store.makeSplit(windowId: "first", draggedId: item, targetId: right, side: .right)
        }
        return item
    }
    first.attach(aHost); second.attach(bHost)
    defer { first.shutdown(); second.shutdown() }
    let arriving = change == .arrivingSibling
    let selected = change == .singleTab ? other : left
    for item in [left, right, other] {
        let owner = arriving && item != left ? b : a
        owner.entries.append(MatrixFakeTab(item: item, live: "live-\(item)", profile: "Profile 1", owner: owner))
    }
    a.active = selected
    b.active = b.entries.first?.itemId
    func apply(_ rev: UInt64, adapter: EngineAdapter, host: any ARWindowHostAPI) async throws {
        var transaction = matrixTransaction(a, window: "first", epoch: 1, rev: rev, command: nil)
        let source = try #require(transaction["strips"] as? [[String: Any]])
        let destination = try #require(matrixTransaction(b, window: "second", epoch: 1, rev: rev, command: nil)["strips"] as? [[String: Any]])
        transaction["strips"] = source + destination
        transaction["cause"] = "Chrome"
        var applied: Bool?
        adapter.onTransaction = { _, accepted in applied = accepted }
        defer { adapter.onTransaction = nil }
        adapter.windowHost(host, didReceiveTransaction: transaction)
        try await matrixWait { applied != nil }
        try #require(applied == true)
    }
    try await apply(0, adapter: first, host: aHost)
    try session.queue.sync { _ = try session.store?.selectItem(windowId: "first", id: selected) }

    let movedItem = change == .unrelated || change == .singleTab ? other : right
    let source = arriving ? b : a
    let target = arriving ? a : b
    let tab = try #require(source.entries.first { $0.itemId == movedItem })
    try #require(target.handoff(tab, activate: !arriving))
    try #require(first.checkLiveWindow(movedItem) == (arriving ? "second" : "first"))
    a.fakeWindow.keyForTest = true
    if !arriving {
        let beforeKey = try #require(first.checkSelectionState()["generation"] as? Int)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: a.window())
        #expect(first.checkSelectionState()["generation"] as? Int == beforeKey)
    }
    if change == .nonKey { a.fakeWindow.keyForTest = false }
    if change == .pendingSelection {
        var registered = false
        first.checkSelectionDispatch = { stage, _, _ in if stage == "registered" { registered = true } }
        first.select(id: other, url: "about:blank?other")
        try await matrixWait { registered }
        try #require(first.checkInFlightSelection(item: other) != nil)
    }
    let generation = try #require(first.checkSelectionState()["generation"] as? Int)

    try await apply(1, adapter: arriving ? first : second, host: arriving ? aHost : bHost)
    #expect(first.checkLiveWindow(movedItem) == (arriving ? "first" : "second"))
    if change == .key || change == .singleTab {
        try #require(first.checkSelectionState()["generation"] as? Int == generation + 1)
        try await matrixWait { a.activated.count == 1 }
        #expect(a.active == selected)
    } else {
        #expect(first.checkSelectionState()["generation"] as? Int == generation)
        #expect(a.activated.isEmpty)
    }
    if arriving { #expect(first.checkLiveWindow(other) == "second") }
    if change == .pendingSelection { #expect(first.checkInFlightSelection(item: other) != nil) }
}

@Test(arguments: [true, false]) @MainActor
func pendingLoneSelectionUsesTheLastRequestedSplitMode(wholeSplit: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let source = try EngineAdapter(path: path, windowID: "source", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    let target = try EngineAdapter(path: path, windowID: "target", card: NSView(frame: NSRect(x: 0, y: 0, width: 804, height: 600)), session: session)
    let (a, aHost) = matrixFake()
    let (b, bHost) = matrixFake()
    source.attach(aHost); target.attach(bHost)
    defer { source.shutdown(); target.shutdown() }
    try session.queue.sync {
        let store = try #require(session.store)
        for window in ["source", "target"] {
            try store.showSpace(windowId: window, spaceId: "named")
            _ = try store.selectItem(windowId: window, id: "close-split-a")
        }
    }
    a.shownProfile = "Profile 1"; b.shownProfile = "Profile 1"
    source.select(id: "close-split-a", url: "about:blank")
    try await matrixWait { a.opened.count == 1 }
    source.windowHost(aHost, didReceiveTransaction: matrixTransaction(a, window: "source", epoch: 1, rev: 0, command: a.opened[0]))
    try await matrixWait { a.backgroundOpened.count == 1 }
    source.windowHost(aHost, didReceiveTransaction: matrixTransaction(a, window: "source", epoch: 1, rev: 1, command: a.backgroundOpened[0]))
    try await matrixWait { a.splitFrames.count == 2 }
    var held: (() -> Void)?
    target.checkSelectionDispatch = { stage, _, resume in
        if stage == "resolved" { held = resume } else { resume() }
    }
    target.select(id: "close-split-a", url: "about:blank", wholeSplit: false)
    try await matrixWait { held != nil }
    let generation = target.checkSelectionState()["generation"] as? Int
    target.select(id: "close-split-a", url: "about:blank", wholeSplit: false)
    #expect(target.checkSelectionState()["generation"] as? Int == generation)
    target.select(id: "close-split-a", url: "about:blank", wholeSplit: true)
    target.select(id: "close-split-a", url: "about:blank", wholeSplit: wholeSplit)
    #expect(target.checkSelectionState()["generation"] as? Int == generation)
    #expect(b.activated.isEmpty)
    target.checkSelectionDispatch = nil
    let resume = try #require(held)
    resume()
    try await matrixWait { b.activated.count == 1 }
    target.windowHost(bHost, didReceiveTransaction: matrixTransaction(b, window: "target", epoch: 1, rev: 2, command: b.activated[0]))
    if wholeSplit {
        try await matrixWait { b.activated.count == 2 }
        target.windowHost(bHost, didReceiveTransaction: matrixTransaction(b, window: "target", epoch: 1, rev: 3, command: b.activated[1]))
        try await matrixWait { b.entries.count == 2 }
        target.windowHost(bHost, didReceiveTransaction: matrixTransaction(b, window: "target", epoch: 1, rev: 4, command: nil))
        try await matrixWait { Set(b.splitFrames.keys) == ["close-split-a", "close-split-b"] }
        #expect(a.entries.isEmpty)
        #expect(target.checkSplitLayout().split)
        #expect(b.activated.count == 2)
    } else {
        try await matrixWait { target.checkInFlightSelection(item: "close-split-a") == nil }
        #expect(b.activated.count == 1 && b.entries.count == 1)
        #expect(!target.checkSplitLayout().split && b.splitFrames.isEmpty)
        #expect(a.entries.map(\.itemId) == ["close-split-b"])
    }
    #expect(b.active == "close-split-a")
}

@Test @MainActor
func deferredSplitSelectionDoesNotFollowASpaceChange() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "deferred-space", card: NSView(), seedProfiles: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    defer { engine.shutdown() }
    let item = try session.queue.sync {
        try #require(session.store?.snapshot(windowId: "deferred-space").spaces.first { $0.id == "default" }?.today.first?.id)
    }
    engine.select(id: item, url: "about:blank")
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "deferred-space", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait { engine.checkInFlightSelection(item: item) == nil }
    var held: (() -> Void)?
    engine.checkSelectionDispatch = { stage, _, resume in
        if stage == "registered" { held = resume } else { resume() }
    }
    engine.select(id: item, url: "about:blank", wholeSplit: false)
    try await matrixWait { held != nil }
    engine.select(id: item, url: "about:blank", wholeSplit: true)
    let generation = engine.checkSelectionState()["generation"] as? Int
    try session.queue.sync { try #require(session.store).showSpace(windowId: "deferred-space", spaceId: "named") }
    engine.checkSelectionDispatch = nil
    let resume = try #require(held)
    resume()
    try await matrixWait {
        engine.checkInFlightSelection(item: item) == nil &&
            engine.checkSelectionState()["pending_commands"] as? [String] == []
    }
    #expect(engine.checkSelectionState()["generation"] as? Int == generation)
    #expect(fake.activated.isEmpty && fake.opened.count == 1)
    #expect(session.queue.sync { session.store?.snapshot(windowId: "deferred-space").shownSpaceId } == "named")
}

@Test @MainActor
func splitCommandsCreatesAndSelectsItsKeyTabOnceWithoutAnEngineSnapshot() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "setup", card: NSView(), seedProfiles: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    defer { engine.shutdown() }
    let runtime = Runtime(windowID: "setup")
    runtime.adapter = engine; runtime.host = host
    runtime.workspace = WorkspaceAdapter(windowID: "setup", session: session)
    runtime.snapshot = session.queue.sync { session.store!.snapshot(windowId: "setup") }
    runtime.sidebar = SidebarView(snapshot: runtime.snapshot)
    runtime.container = SidebarContainerView(sidebar: try #require(runtime.sidebar), page: NSView())
    let before = runtime.snapshot.spaces.flatMap(\.today).count
    runtime.browserCheckPhase = 27
    runtime.splitCommandsCheckTick(host, screen: false)
    #expect(runtime.browserCheckPhase == 100)
    runtime.splitCommandsCheckTick(host, screen: false)
    try await matrixWait { runtime.browserCheckPhase == 28 && fake.opened.count == 1 }
    let item = try #require(runtime.splitCommandsCheck?.keyTab)
    #expect(runtime.snapshot.selectedId == item && fake.active == item)
    #expect(runtime.snapshot.spaces.flatMap(\.today).contains { $0.id == item })
    #expect(session.queue.sync { session.store!.snapshot(windowId: "setup").spaces.flatMap(\.today).count } == before + 1)
}

@Test @MainActor
func splitRestorationFinishesAfterAllMembersHaveOpened() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("db").path
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: path, windowID: "restore-split", card: NSView(frame: NSRect(x: 0, y: 0, width: 804, height: 600)), seedProfiles: true, seedSplitCheck: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    try session.queue.sync {
        let store = try #require(session.store)
        try store.showSpace(windowId: "restore-split", spaceId: "named")
        _ = try store.selectItem(windowId: "restore-split", id: "close-split-a")
        try store.flush()
    }
    fake.shownProfile = "Profile 1"
    var completed = 0
    session.restoringWindows = ["restore-split"]
    session.finishCrashRecovery = { completed += 1 }
    engine.restoreSelection()
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "restore-split", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait { fake.backgroundOpened.count == 1 }
    #expect(completed == 0)
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "restore-split", epoch: 1, rev: 1, command: fake.backgroundOpened[0]))
    try await matrixWait { completed == 1 }
    #expect(fake.active == "close-split-a")
    engine.shutdown()
}

@Test @MainActor
func failedSplitSiblingOpenKeepsTheFocusedPaneAndPlaceholder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let card = NSView(frame: NSRect(x: 0, y: 0, width: 804, height: 600))
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "split-failure", card: card, seedProfiles: true, seedSplitCheck: true, session: session)
    let (fake, host) = matrixFake()
    fake.refuseBackground = true
    engine.attach(host)
    try session.queue.sync {
        let store = try #require(session.store)
        try store.showSpace(windowId: "split-failure", spaceId: "named")
        _ = try store.selectItem(windowId: "split-failure", id: "close-split-a")
    }
    fake.shownProfile = "Profile 1"
    engine.select(id: "close-split-a", url: "about:blank")
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "split-failure", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait {
        card.subviews.contains { ($0 as? RemotePlaceholderView)?.accessibilityLabel() == "Page unavailable" } &&
        session.queue.sync { session.store?.liveTab(item: "close-split-b") == nil }
    }
    #expect(fake.active == "close-split-a")
    #expect(fake.backgroundOpened.isEmpty)
    engine.shutdown()
}

@Test @MainActor
func closingSplitCancelsItsDeferredMemberOpens() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "split-cancel", card: NSView(), seedProfiles: true, seedSplitCheck: true, session: session)
    let (fake, host) = matrixFake()
    fake.deferOpen = true
    engine.attach(host)
    try session.queue.sync {
        let store = try #require(session.store)
        try store.showSpace(windowId: "split-cancel", spaceId: "named")
        _ = try store.selectItem(windowId: "split-cancel", id: "close-split-a")
    }
    fake.shownProfile = "Profile 1"
    engine.select(id: "close-split-a", url: "about:blank")
    try await matrixWait { fake.opened.count == 1 }
    engine.close(id: "close-split")
    try await matrixWait {
        fake.pendingOpens.isEmpty && session.queue.sync {
            session.store?.liveTab(item: "close-split-a") == nil && session.store?.liveTab(item: "close-split-b") == nil &&
            session.store?.snapshot(windowId: "split-cancel").spaces.flatMap(\.pinned).first(where: { $0.id == "close-split" })?.unloaded == true
        }
    }
    #expect(fake.closed.isEmpty)
    engine.shutdown()
}

@Test @MainActor
func selectingNestedSplitOpensAllThreeMembers() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("db").path
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work",{"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":[],"data":{"itemContainer":{}}},"today",{"id":"today","parentID":null,"childrenIds":["split"],"data":{"itemContainer":{}}},"split",{"id":"split","parentID":"today","childrenIds":["nested","c"],"data":{"splitView":{"layoutOrientation":"horizontal"}}},"nested",{"id":"nested","parentID":"split","childrenIds":["a","b"],"data":{"splitView":{"layoutOrientation":"vertical"}}},"a",{"id":"a","parentID":"nested","childrenIds":[],"data":{"tab":{"savedURL":"https://a.example"}}},"b",{"id":"b","parentID":"nested","childrenIds":[],"data":{"tab":{"savedURL":"https://b.example"}}},"c",{"id":"c","parentID":"split","childrenIds":[],"data":{"tab":{"savedURL":"https://c.example"}}}]}]}}"#
    let store = try WorkspaceStore.open(path: path)
    _ = try store.importArcSidebar(windowId: "nested", json: json, windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
    _ = try store.selectItem(windowId: "nested", id: "a")
    let session = WorkspaceSession()
    session.store = store
    let card = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    let engine = try EngineAdapter(path: path, windowID: "nested", card: card, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    var appliedTransactions = 0
    engine.onTransaction = { _, accepted in if accepted { appliedTransactions += 1 } }
    engine.select(id: "a", url: "https://a.example")
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "nested", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait { fake.backgroundOpened.count == 2 }
    for (index, command) in fake.backgroundOpened.enumerated() {
        engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "nested", epoch: 1, rev: UInt64(index + 1), command: command))
    }
    try await matrixWait { fake.splitFrames.count == 3 && appliedTransactions == 3 }
    #expect(Set(fake.splitFrames.keys) == ["a", "b", "c"])
    let a = try #require(fake.splitFrames["a"]).rectValue
    let b = try #require(fake.splitFrames["b"]).rectValue
    let c = try #require(fake.splitFrames["c"]).rectValue
    #expect(a.minX == b.minX && a.minY >= b.maxY && b.maxX < c.minX)
    #expect(fake.active == "a")
    let divider = try #require(card.subviews.compactMap { $0 as? SplitDividerView }.first { !$0.horizontal })
    func mouse(_ type: NSEvent.EventType, _ y: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: divider.frame.midX, y: y), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    let start = divider.frame.midY
    divider.mouseDown(with: try mouse(.leftMouseDown, start))
    divider.mouseDragged(with: try mouse(.leftMouseDragged, start + 30))
    #expect(fake.splitFrames["c"]?.rectValue == c)
    #expect(fake.splitFrames["a"]?.rectValue != a)
    var stored = false
    engine.onWorkspaceChange = { stored = true }
    divider.mouseUp(with: try mouse(.leftMouseUp, start + 30))
    let callsAtRelease = fake.splitFrameCalls
    try await matrixWait { stored }
    #expect(fake.splitFrameCalls == callsAtRelease)
    let persisted = try session.queue.sync { try #require(session.store?.splitLayout(itemId: "a")) }
    let nested = try #require(persisted.children.first { $0.id == "nested" })
    #expect(nested.children[0].factor != nested.children[1].factor)
    engine.shutdown()
}

@Test @MainActor
func crashedStripKeepsTheLiveRowAndClearsAfterRecovery() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "crash", card: NSView(), seedProfiles: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    let row = try session.queue.sync { () -> (String, String) in
        let snapshot = try #require(session.store).snapshot(windowId: "crash")
        let row = try #require(snapshot.spaces.first(where: { $0.id == "default" })?.today.first)
        return (row.id, try #require(row.url))
    }
    engine.select(id: row.0, url: row.1)
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "crash", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait { session.queue.sync { session.store?.liveTab(item: row.0) == fake.opened[0] } }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "crash", epoch: 1, rev: 1, command: nil, crashedItem: row.0))
    try await matrixWait { engine.crashedItems.contains(row.0) }
    #expect(session.queue.sync { session.store?.liveTab(item: row.0) } == fake.opened[0])
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "crash", epoch: 1, rev: 2, command: nil))
    try await matrixWait { engine.crashedItems.isEmpty }
}

@Test @MainActor
func matrixSequentialCallbacksAndRetentionWithFakeHost() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("workspace.sqlite").path, windowID: "matrix", card: NSView(), seedProfiles: true, session: session)
    let workspace = WorkspaceAdapter(windowID: "matrix", session: session)
    let runtime = Runtime(windowID: "matrix")
    let (fake, host) = matrixFake()
    runtime.adapter = engine; runtime.workspace = workspace; runtime.host = host
    engine.onSnapshot = { [weak runtime] value in runtime?.snapshot = value }
    engine.onTransaction = { [weak runtime] transaction, applied in
        guard let runtime else { return }
        runtime.recordMatrixTransaction(transaction, applied: applied, usableHost: runtime.hasUsableHost)
    }
    engine.attach(host)
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 1, rev: 0, command: nil))
    try await matrixWait { session.queue.sync { session.store?.snapshot(windowId: "matrix").spaces.first?.today.first?.unloaded == true } }
    runtime.commandSpaceMatrixTick(host, screen: false)
    #expect(runtime.spaceMatrixPhase == 9 && runtime.matrixTargets.count == 9)
    for index in 0..<9 {
        runtime.commandSpaceMatrixTick(host, screen: false)
        try await matrixWait { fake.opened.count == index + 1 }
        #expect(runtime.matrixAcknowledgedLive == nil)
        runtime.commandSpaceMatrixTick(host, screen: false)
        #expect(runtime.spaceMatrixPhase == 10 && runtime.matrixSetupIndex == index)
        let command = try #require(runtime.matrixCommand)
        #expect(session.queue.sync { session.store?.liveTab(item: runtime.matrixTargets[index].item) } == command)
        #expect(session.queue.sync { session.store?.itemForLive(liveId: command) } == runtime.matrixTargets[index].item)
        #expect(fake.entries.contains { $0.itemId == runtime.matrixTargets[index].item && $0.liveId == command })
        engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 1, rev: UInt64(index + 1), command: command))
        try await matrixWait { runtime.matrixAcknowledgedLive == command }
        runtime.commandSpaceMatrixTick(host, screen: false)
        if index < 8 { #expect(runtime.spaceMatrixPhase == 9 && runtime.matrixSetupIndex == index + 1) }
    }
    #expect(runtime.matrixRetained(host))
    try await matrixWait { !fake.activated.isEmpty && runtime.matrixCommand == fake.activated.last }
    let command = try #require(runtime.matrixCommand)
    #expect(runtime.matrixReturning && runtime.matrixAcknowledgedLive == nil)
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 1, rev: 10, command: command))
    try await matrixWait { runtime.matrixAcknowledgedLive != nil }
    runtime.commandSpaceMatrixTick(host, screen: false)
    #expect(runtime.spaceMatrixPhase == 1)
    #expect(runtime.spaceMatrixSuggestionPassed.isEmpty && runtime.spaceMatrixMenuPassed.isEmpty && runtime.spaceMatrixCommandsPassed.isEmpty)
    let target = runtime.matrixTargets[8]
    let live = try #require(target.live)
    #expect(runtime.matrixCurrentTargetReady(host, index: 8, live: live))
    runtime.matrixTargets[8] = Runtime.MatrixTarget(space: target.space, item: "wrong", profile: target.profile, url: target.url, live: live)
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live) && !runtime.matrixRetained(host))
    runtime.matrixTargets[8] = Runtime.MatrixTarget(space: target.space, item: target.item, profile: "wrong", url: target.url, live: live)
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live) && !runtime.matrixRetained(host))
    runtime.matrixTargets[8] = Runtime.MatrixTarget(space: target.space, item: target.item, profile: target.profile, url: "wrong", live: live)
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live) && !runtime.matrixRetained(host))
    runtime.matrixTargets[8] = target
    fake.shownProfile = "wrong"
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live))
    fake.shownProfile = target.profile
    fake.active = "wrong"
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live))
    fake.active = target.item
    fake.entries.append(MatrixFakeTab(item: "other", live: live, profile: target.profile, owner: fake))
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live))
    #expect(!runtime.matrixRetained(host))
    fake.entries.removeLast()
    fake.entries.append(MatrixFakeTab(item: target.item, live: "duplicate", profile: target.profile, owner: fake))
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live))
    #expect(!runtime.matrixRetained(host))
    fake.entries.removeLast()
    fake.presentationOverride = ["live": "other", "target": true, "presented": true]
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live))
    fake.presentationOverride = nil
    fake.entries[8].isLoading = true
    #expect(!runtime.matrixCurrentTargetReady(host, index: 8, live: live))
    fake.entries[8].isLoading = false
    runtime.sidebar = SidebarView(snapshot: runtime.snapshot)
    runtime.container = SidebarContainerView(sidebar: try #require(runtime.sidebar), page: NSView())
    runtime.spaceMatrixPhase = 8
    runtime.spaceMatrixCommandIndex = 2
    runtime.spaceMatrixSidebarBefore = "previous-state"
    runtime.commandSpaceMatrixTick(host, screen: false)
    #expect(runtime.spaceMatrixCommandsPassed == ["toggle_sidebar"] && runtime.spaceMatrixCommandIndex == 3)
    runtime.spaceMatrixCommandsPassed = []
    runtime.spaceMatrixPhase = 8
    runtime.spaceMatrixCommandIndex = 2
    let retained = fake.entries.removeFirst()
    let omitted = matrixTransaction(fake, window: "matrix", epoch: 1, rev: 11, command: nil)
    fake.entries.insert(retained, at: 0)
    engine.windowHost(host, didReceiveTransaction: omitted)
    try await matrixWait { session.queue.sync { session.store?.liveTab(item: runtime.matrixTargets[0].item) == nil } }
    #expect(session.queue.sync { session.store?.snapshot(windowId: "matrix").spaces.first?.today.first?.unloaded } == false)
    #expect(fake.entries.contains { $0.itemId == runtime.matrixTargets[0].item })
    #expect(!runtime.matrixRetained(host))
    for (phase, index) in [(6, 2), (7, 2), (8, 2), (7, 10)] {
        runtime.matrixCommandInvariantFailed = false
        runtime.spaceMatrixPhase = phase
        runtime.spaceMatrixCommandIndex = index
        runtime.commandSpaceMatrixTick(host, screen: false)
        #expect(runtime.matrixCommandInvariantFailed && runtime.spaceMatrixCommandsPassed.isEmpty && runtime.spaceMatrixCommandIndex == index)
    }
    #expect(!runtime.matrixFinalValid(host))

    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 1, rev: 12, command: nil))
    try await matrixWait { session.queue.sync { session.store?.liveTab(item: runtime.matrixTargets[0].item) == retained.liveId } }
    #expect(runtime.matrixRetained(host))
    #expect(!runtime.matrixFinalValid(host))
    runtime.matrixCommandInvariantFailed = false
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 2, rev: 0, command: nil))
    try await matrixWait { runtime.matrixEpochChanged }
    runtime.spaceMatrixPhase = 8
    runtime.spaceMatrixCommandIndex = 2
    runtime.commandSpaceMatrixTick(host, screen: false)
    #expect(runtime.matrixCommandInvariantFailed && runtime.spaceMatrixCommandsPassed.isEmpty && runtime.spaceMatrixCommandIndex == 2)
    #expect(!runtime.matrixFinalValid(host))
    runtime.matrixEpochChanged = false
    runtime.matrixEpoch = 2
    runtime.matrixCommandInvariantFailed = false
    let closeCommand = try session.queue.sync { try session.store!.liveClose(item: target.item) }
    fake.entries.removeLast()
    fake.active = nil
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 2, rev: 1, command: closeCommand.id))
    try await matrixWait { session.queue.sync { session.store?.itemForLive(liveId: live) == nil } }
    runtime.snapshot = session.queue.sync { session.store!.snapshot(windowId: "matrix") }
    #expect(runtime.matrixFinalValid(host))
    let background = fake.entries.removeFirst()
    let afterCloseOmission = matrixTransaction(fake, window: "matrix", epoch: 2, rev: 2, command: nil)
    fake.entries.insert(background, at: 0)
    engine.windowHost(host, didReceiveTransaction: afterCloseOmission)
    try await matrixWait { session.queue.sync { session.store?.liveTab(item: runtime.matrixTargets[0].item) == nil } }
    #expect(!runtime.matrixFinalValid(host))
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 2, rev: 3, command: nil))
    try await matrixWait { session.queue.sync { session.store?.liveTab(item: runtime.matrixTargets[0].item) == background.liveId } }
    #expect(runtime.matrixFinalValid(host))
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "matrix", epoch: 3, rev: 0, command: nil))
    try await matrixWait { runtime.matrixEpochChanged }
    #expect(!runtime.matrixFinalValid(host))
}

@Test @MainActor
func matrixC2PresentationRequiresCorrectIdentityAndGeometry() {
    var state: [String: Any] = ["live": "live", "target": true, "presented": true, "compositor": "c2", "window": true, "bounds": true, "page_hit": true]
    #expect(Runtime.matrixPagePresented(state, live: "live", c2: true, screen: true))
    for key in ["window", "bounds", "page_hit", "target", "presented"] {
        var bad = state
        bad[key] = false
        #expect(!Runtime.matrixPagePresented(bad, live: "live", c2: true, screen: true))
    }
    state["compositor"] = "c1"
    #expect(!Runtime.matrixPagePresented(state, live: "live", c2: true, screen: true))
    state["compositor"] = "c2"
    #expect(!Runtime.matrixPagePresented(state, live: "other", c2: true, screen: true))
    state["page_hit"] = false
    #expect(Runtime.matrixPagePresented(state, live: "live", c2: true, screen: false))
}

@Test @MainActor
func matrixActivationHooksRejectSupersededAndClosedSelections() async throws {
    for stage in ["registered", "resolved"] {
        for close in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let session = WorkspaceSession()
            let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "race", card: NSView(), seedProfiles: true, session: session)
            let (fake, host) = matrixFake()
            engine.attach(host)
            let item = try session.queue.sync { () -> String in
                let store = try #require(session.store)
                let row = try #require(store.snapshot(windowId: "race").spaces.first(where: { $0.id == "default" })?.today.first)
                _ = try store.showSpaceSelectingTab(windowId: "race", spaceId: "default", itemId: row.id)
                return row.id
            }
            var applied = false
            engine.onTransaction = { _, accepted in if accepted { applied = true } }
            engine.select(id: item, url: "about:blank")
            try await matrixWait { fake.opened.count == 1 }
            engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "race", epoch: 1, rev: 0, command: fake.opened[0]))
            try await matrixWait { applied }
            var held: (() -> Void)?
            var oldCommand = ""
            engine.checkSelectionDispatch = { current, command, resume in
                if current == stage { held = resume; oldCommand = command }
                else { resume() }
            }
            engine.select(id: item, url: "about:blank")
            try await matrixWait { held != nil }
            engine.checkSelectionDispatch = nil
            if close {
                fake.closing = true
                engine.windowHostWillBeginClosing(host)
            } else {
                engine.invalidateSelection()
                engine.select(id: item, url: "about:blank")
                try await matrixWait { !fake.activated.isEmpty }
            }
            let resume = try #require(held)
            resume()
            try await matrixWait {
                let pending = engine.checkSelectionState()["pending_commands"] as? [String] ?? []
                return !pending.contains(oldCommand)
            }
            #expect(!fake.activated.contains(oldCommand))
            #expect(close ? fake.activated.isEmpty : fake.activated.count == 1)
        }
    }
}

@Test @MainActor
func matrixCommittedSwitchDoesNotDispatchAfterSupersessionOrClose() async throws {
    for close in [false, true] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession()
        let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "switch", card: NSView(), seedProfiles: true, session: session)
        let workspace = WorkspaceAdapter(windowID: "switch", session: session)
        let runtime = Runtime(windowID: "switch")
        let (fake, host) = matrixFake()
        runtime.adapter = engine; runtime.workspace = workspace; runtime.host = host
        engine.attach(host)
        let initial = session.queue.sync { session.store!.snapshot(windowId: "switch") }
        let space = try #require(initial.spaces.first(where: { $0.id == "named" }))
        let row = try #require(space.today.first)
        let target = Runtime.MatrixTarget(space: space.id, item: row.id, profile: space.profileName, url: try #require(row.url))
        runtime.matrixTargets = [target]
        runtime.spaceMatrixIDs = Array(repeating: "placeholder", count: 9)
        runtime.spaceMatrixPhase = 9
        var held: (() -> Void)?
        workspace.checkSpaceSwitchCompletion = { kind, resume in
            if kind == "tab" { held = resume } else { resume() }
        }
        runtime.commandSpaceMatrixTick(host, screen: false)
        try await matrixWait { held != nil }
        #expect(session.queue.sync { session.store?.snapshot(windowId: "switch").selectedId } == row.id)
        runtime.selectionGeneration += 1
        workspace.cancelPendingSpaceSwitches()
        if close { fake.closing = true }
        else { _ = try session.queue.sync { try session.store!.showSpaceSelecting(windowId: "switch", spaceId: "default") } }
        let resume = try #require(held)
        resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fake.opened.isEmpty && runtime.matrixCommand == nil && runtime.matrixAcknowledgedLive == nil)
        #expect(runtime.spaceMatrixPhase == 10)
    }
}

@Test @MainActor
func matrixUnloadedSpaceLoadsItsRowAndEmptySpaceHidesRetainedPage() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "empty", card: NSView(), seedProfiles: true, session: session)
    let runtime = Runtime(windowID: "empty")
    let (fake, host) = matrixFake()
    runtime.host = host; runtime.adapter = engine
    engine.attach(host)
    let ids = try session.queue.sync { () -> (String, String) in
        let store = try #require(session.store)
        try store.showSpace(windowId: "empty", spaceId: "default")
        let first = try #require(store.snapshot(windowId: "empty").spaces.first(where: { $0.id == "default" })?.today.first?.id)
        _ = try store.createSpace(windowId: "empty", name: "Unloaded", spaceId: "unloaded")
        let second = try #require(try store.createTab(windowId: "empty", url: "about:blank?unloaded").selectedId)
        _ = try store.createSpace(windowId: "empty", name: "Empty", spaceId: "empty-space")
        _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine, strips: [LiveStrip(window: "empty", tabs: [], active: nil)]))
        return (first, second)
    }
    let selected = try session.queue.sync { try session.store!.showSpaceSelectingTab(windowId: "empty", spaceId: "default", itemId: ids.0) }
    runtime.show(selected)
    engine.select(id: ids.0, url: "about:blank")
    try await matrixWait { fake.opened.count == 1 }
    var applied = false
    engine.onTransaction = { _, accepted in applied = accepted }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "empty", epoch: 1, rev: 1, command: fake.opened[0]))
    try await matrixWait { applied }
    let live = fake.opened[0]
    // A space whose rows are all Unloaded is eligible (Arc's behaviour, the owner's
    // choice 2026-11-09): the switch picks the window's row for it, the tab this window
    // selected in that space before the engine unloaded everything, and that selection
    // loads it through the ordinary select path (Unloaded -> Open). showAndSelect is the
    // step switchWorkspaceSpace runs after showSpaceSelecting: show the snapshot, then
    // let the adapter open the selected row because it has no live tab yet.
    let unloadedSnapshot = try session.queue.sync { try session.store!.showSpaceSelecting(windowId: "empty", spaceId: "unloaded") }
    let unloadedSpace = try #require(unloadedSnapshot.spaces.first(where: { $0.id == "unloaded" }))
    let unloadedRow = try #require(unloadedSpace.today.first)
    #expect(unloadedSpace.profileName == "Default" && unloadedSnapshot.selectedId == ids.1)
    #expect(unloadedRow.id == ids.1 && unloadedRow.unloaded == false && unloadedRow.url != nil)
    runtime.showAndSelect(.success(unloadedSnapshot), expectedSpace: "unloaded")
    try await matrixWait { fake.opened.count == 2 }
    let unloadedLive = fake.opened[1]
    #expect(fake.active == ids.1 && fake.entries.count == 2 && !fake.hidden && fake.hasActiveTab())
    #expect((fake.navigationTarget()?["item"] as? String) == ids.1)
    #expect(fake.presentation(unloadedLive)["presented"] as? Bool == true)
    #expect(fake.presentation(live)["presented"] as? Bool == false)
    #expect(session.queue.sync { session.store?.liveTab(item: ids.1) } == unloadedLive)
    // An empty space has no eligible row: the switch clears the selection, the retained
    // page of the previous space stays hidden, and the switch issues no engine command of
    // its own, so the unloaded space's live tab is still the active one.
    let emptySnapshot = try session.queue.sync { try session.store!.showSpaceSelecting(windowId: "empty", spaceId: "empty-space") }
    let emptySpace = try #require(emptySnapshot.spaces.first(where: { $0.id == "empty-space" }))
    #expect(emptySpace.profileName == "Default" && emptySnapshot.selectedId == nil)
    #expect(emptySpace.today.isEmpty && emptySpace.pinned.isEmpty && emptySpace.favorites.isEmpty)
    runtime.show(emptySnapshot)
    #expect(fake.hidden && !fake.hasActiveTab() && fake.navigationTarget() == nil)
    #expect(fake.presentation(live)["presented"] as? Bool == false)
    #expect(fake.presentation(unloadedLive)["presented"] as? Bool == false)
    #expect(fake.active == ids.1 && fake.entries.count == 2)
    #expect(session.queue.sync { session.store?.liveTab(item: ids.0) } == live)
    #expect(session.queue.sync { session.store?.liveTab(item: ids.1) } == unloadedLive)
    let strip = LiveStrip(window: "empty", tabs: [LiveTab(offTheRecord: false, profile: .default, liveId: live, item: ids.0, opener: nil, navigated: false, url: nil, title: nil)], active: nil)
    let after = try session.queue.sync { () -> WorkspaceSnapshot in
        let store = try #require(session.store)
        #expect(try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 2, cause: .engine, strips: [strip])).applied)
        return store.snapshot(windowId: "empty")
    }
    #expect(after.shownSpaceId == "empty-space" && after.selectedId == nil)
    #expect(session.queue.sync { session.store?.liveTab(item: ids.0) } == live)
}

@Test @MainActor
func matrixDelayedAcceptedOpenDoesNotAdvanceSupersededOrClosedStage() async throws {
    for close in [false, true] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession()
        let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "delayed", card: NSView(), seedProfiles: true, session: session)
        let workspace = WorkspaceAdapter(windowID: "delayed", session: session)
        let runtime = Runtime(windowID: "delayed")
        let (fake, host) = matrixFake()
        runtime.adapter = engine; runtime.workspace = workspace; runtime.host = host
        engine.onSnapshot = { [weak runtime] value in runtime?.snapshot = value }
        var accepted = false
        engine.onTransaction = { [weak runtime] transaction, applied in
            accepted = applied
            if let runtime { runtime.recordMatrixTransaction(transaction, applied: applied, usableHost: runtime.hasUsableHost) }
        }
        engine.attach(host)
        let snapshot = session.queue.sync { session.store!.snapshot(windowId: "delayed") }
        let space = try #require(snapshot.spaces.first(where: { $0.id == "default" }))
        let row = try #require(space.today.first)
        runtime.matrixTargets = [Runtime.MatrixTarget(space: space.id, item: row.id, profile: space.profileName, url: try #require(row.url))]
        runtime.spaceMatrixIDs = Array(repeating: "placeholder", count: 9)
        runtime.spaceMatrixPhase = 9
        runtime.commandSpaceMatrixTick(host, screen: false)
        try await matrixWait { fake.opened.count == 1 }
        let command = try #require(runtime.matrixCommand)
        #expect((engine.checkSelectionState()["pending_commands"] as? [String] ?? []).isEmpty)
        runtime.selectionGeneration += 1
        workspace.cancelPendingSpaceSwitches()
        if close { fake.closing = true; engine.windowHostWillBeginClosing(host) }
        else {
            _ = try session.queue.sync { try session.store!.showSpaceSelecting(windowId: "delayed", spaceId: "named") }
            engine.invalidateSelection()
        }
        engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "delayed", epoch: 1, rev: 0, command: command))
        if close { #expect(!accepted) }
        else { try await matrixWait { accepted } }
        #expect(runtime.matrixAcknowledgedLive == nil && runtime.spaceMatrixPhase == 10)
        #expect(fake.entries.count == 1)
    }
}

@Test @MainActor
func pendingProfileOpenIsWithdrawnOrRejectedWhenItsCommandChanges() async throws {
    for action in ["selection", "close", "core", "space"] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession()
        let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "pending", card: NSView(), seedProfiles: true, session: session)
        let (fake, host) = matrixFake()
        fake.deferOpen = true
        engine.attach(host)
        let row = try session.queue.sync { () -> (String, String) in
            let store = try #require(session.store)
            _ = try store.showSpaceSelecting(windowId: "pending", spaceId: "named")
            let row = try #require(store.snapshot(windowId: "pending").spaces.first(where: { $0.id == "named" })?.today.first)
            return (row.id, try #require(row.url))
        }
        engine.select(id: row.0, url: row.1)
        try await matrixWait { fake.opened.count == 1 }
        let command = try #require(fake.opened.first)
        #expect(engine.windowHost(host, shouldOpenCommand: command, itemId: row.0))
        if action == "selection" || action == "close" {
            if action == "close" {
                fake.closing = true
                engine.windowHostWillBeginClosing(host)
            } else {
                engine.invalidateSelection()
            }
            #expect(fake.pendingOpens.isEmpty)
            try await matrixWait { session.queue.sync { session.store?.liveTab(item: row.0) == nil } }
        } else if action == "core" {
            _ = session.queue.sync { session.store?.liveCancel(commandId: command) }
            #expect(!engine.windowHost(host, shouldOpenCommand: command, itemId: row.0))
        } else {
            try session.queue.sync { try session.store?.showSpace(windowId: "pending", spaceId: "default") }
            #expect(!engine.windowHost(host, shouldOpenCommand: command, itemId: row.0))
        }
        if action == "core" {
            #expect(session.queue.sync { session.store?.liveTab(item: row.0) } == nil)
        }
    }
}

@Test @MainActor
func restoredSelectionIsRevalidatedWhenDeferredOpenDrains() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "restore", card: NSView(), seedProfiles: true, session: session)
    let (fake, host) = matrixFake()
    fake.deferOpen = true
    let ids = try session.queue.sync { () -> (String, String) in
        let store = try #require(session.store)
        _ = try store.showSpaceSelecting(windowId: "restore", spaceId: "named")
        let first = try #require(store.snapshot(windowId: "restore").selectedId)
        let second = try #require(try store.createTab(windowId: "restore", url: "https://second.example/").selectedId)
        _ = try store.selectItem(windowId: "restore", id: first)
        return (first, second)
    }
    engine.attach(host)
    engine.windowHost(host, didReceiveTransaction: ["off_the_record": false, "epoch": 1, "rev": 0, "cause": "Engine", "strips": []])
    engine.restoreSelection()
    try await matrixWait { fake.opened.count == 1 }
    let command = try #require(fake.opened.first)
    #expect(fake.pendingOpens == [command: ids.0])
    #expect(engine.windowHost(host, shouldOpenCommand: command, itemId: ids.0))
    _ = try session.queue.sync { try session.store!.selectItem(windowId: "restore", id: ids.1) }
    #expect(!engine.windowHost(host, shouldOpenCommand: command, itemId: ids.0))
    let (_, otherHost) = matrixFake()
    #expect(!engine.windowHost(otherHost, shouldOpenCommand: command, itemId: ids.0))
    engine.invalidateSelection()
    #expect(!engine.windowHost(host, shouldOpenCommand: command, itemId: ids.0))
}

@Test @MainActor
func recoveryDoesNotAcknowledgeTheInitialTransactionBeforeSelectionDispatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                                   windowID: "recovery-order", card: NSView(), session: session)
    let (fake, host) = matrixFake()
    var acknowledgements = 0
    var observedInitial = false
    session.restoringWindows = ["recovery-order"]
    session.finishCrashRecovery = { acknowledgements += 1 }
    engine.onTransaction = { transaction, applied in
        if transaction.rev == 0 && applied {
            observedInitial = true
            #expect(acknowledgements == 0)
        }
    }
    engine.attach(host)
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "recovery-order", epoch: 1, rev: 0, command: nil))
    engine.restoreSelection()
    try await matrixWait { observedInitial && acknowledgements == 1 }
}

@Test @MainActor
func metadataFromClosingWindowDoesNotSupersedePendingSelection() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let path = dir.appendingPathComponent("db").path
    let main = try EngineAdapter(path: path, windowID: "main", card: NSView(), seedProfiles: true, session: session)
    let child = try EngineAdapter(path: path, windowID: "child", card: NSView(), session: session)
    let (mainFake, mainHost) = matrixFake()
    let (childFake, childHost) = matrixFake()
    main.attach(mainHost); child.attach(childHost)
    let row = try session.queue.sync { () -> (String, String) in
        let snapshot = try #require(session.store).snapshot(windowId: "main")
        let row = try #require(snapshot.spaces.first?.today.first)
        return (row.id, try #require(row.url))
    }
    var applied = false
    main.onTransaction = { _, ok in applied = ok }
    main.select(id: row.0, url: row.1)
    try await matrixWait { mainFake.opened.count == 1 }
    main.windowHost(mainHost, didReceiveTransaction: matrixTransaction(mainFake, window: "main", epoch: 1, rev: 0, command: mainFake.opened[0]))
    try await matrixWait { applied }
    let childRow = try session.queue.sync { () -> (String, String) in
        let store = try #require(session.store)
        let snapshot = try store.createTab(windowId: "child", url: "https://child.example/")
        return (try #require(snapshot.selectedId), "https://child.example/")
    }
    child.select(id: childRow.0, url: childRow.1)
    try await matrixWait { childFake.opened.count == 1 }
    var childApplied = false
    child.onTransaction = { _, ok in childApplied = ok }
    child.windowHost(childHost, didReceiveTransaction: matrixTransaction(childFake, window: "child", epoch: 1, rev: 1, command: childFake.opened[0]))
    try await matrixWait { childApplied }
    var held: (() -> Void)?
    var command = ""
    main.checkSelectionDispatch = { stage, id, resume in
        if stage == "resolved" { held = resume; command = id } else { resume() }
    }
    main.select(id: row.0, url: row.1)
    try await matrixWait { held != nil }
    let generation = try #require(main.checkSelectionState()["generation"] as? Int)
    var broadcasts = 0
    child.onWorkspaceChange = { broadcasts += 1; main.refresh() }
    childApplied = false
    var metadata = matrixTransaction(childFake, window: "child", epoch: 1, rev: 2, command: nil)
    var strips = metadata["strips"] as! [[String: Any]]
    var tabs = strips[0]["tabs"] as! [[String: Any]]
    tabs[0]["loading"] = true
    tabs[0]["audible"] = true
    strips[0]["tabs"] = tabs
    metadata["strips"] = strips
    child.windowHost(childHost, didReceiveTransaction: metadata)
    try await matrixWait { childApplied }
    #expect(child.rowStates[childRow.0]?.loading == true)
    #expect(child.rowStates[childRow.0]?.audible == true)
    #expect(broadcasts == 0)
    main.select(id: row.0, url: row.1)
    childFake.closing = true
    childApplied = false
    child.windowHost(childHost, didReceiveTransaction: matrixTransaction(childFake, window: "child", epoch: 1, rev: 3, command: nil, crashedItem: childRow.0))
    #expect(!childApplied)
    #expect(main.checkSelectionState()["generation"] as? Int == generation)
    main.checkSelectionDispatch = nil
    let resume = try #require(held)
    resume()
    try await matrixWait { mainFake.activated.contains(command) }
    applied = false
    main.windowHost(mainHost, didReceiveTransaction: matrixTransaction(mainFake, window: "main", epoch: 1, rev: 3, command: command))
    try await matrixWait { applied }
    main.shutdown(); child.shutdown()
}

@Test @MainActor
func closingWindowRejectsQueuedSelectionAndCrashedStripButFinishesClose() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "closing", card: NSView(), seedProfiles: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    let row = try session.queue.sync { () -> (String, String) in
        let store = try #require(session.store)
        let row = try #require(store.snapshot(windowId: "closing").spaces.first?.today.first)
        return (row.id, try #require(row.url))
    }
    var transactions = 0
    engine.onTransaction = { _, accepted in if accepted { transactions += 1 } }
    engine.select(id: row.0, url: row.1)
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "closing", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait { transactions == 1 }
    var held: (() -> Void)?
    var dispatches = 0
    engine.checkSelectionDispatch = { stage, _, resume in
        dispatches += 1
        if stage == "registered" { held = resume } else { resume() }
    }
    engine.select(id: row.0, url: row.1)
    try await matrixWait { held != nil }
    engine.windowHostWillBeginClosing(host)
    engine.select(id: row.0, url: row.1)
    let resume = try #require(held)
    resume()
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "closing", epoch: 1, rev: 1, command: nil, crashedItem: row.0))
    #expect(dispatches == 1)
    #expect(fake.activated.isEmpty)
    #expect(transactions == 1)
    var handedOff: Bool?
    engine.windowHost(host, prepareCloseHandoff: { handedOff = $0 })
    #expect(handedOff == true)
    fake.closing = true
    fake.entries.removeAll()
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "closing", epoch: 1, rev: 1, command: nil))
    try await matrixWait { transactions == 2 }
    #expect(fake.activated.isEmpty)
    #expect(session.queue.sync { session.store?.liveTab(item: row.0) } == nil)
    engine.shutdown()
}

@Test @MainActor
func metadataDoesNotSelectAndInFlightSelectionExposesItsProgress() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "join", card: NSView(), seedProfiles: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    let row = try session.queue.sync { () -> (String, String) in
        let row = try #require(session.store?.snapshot(windowId: "join").spaces.first?.today.first)
        return (row.id, try #require(row.url))
    }
    var applied = false
    engine.onTransaction = { _, ok in applied = ok }
    engine.select(id: row.0, url: row.1)
    try await matrixWait { fake.opened.count == 1 }
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "join", epoch: 1, rev: 0, command: fake.opened[0]))
    try await matrixWait { applied }
    let generation = try #require(engine.checkSelectionState()["generation"] as? Int)
    applied = false
    var metadata = matrixTransaction(fake, window: "join", epoch: 1, rev: 1, command: nil)
    var strips = metadata["strips"] as! [[String: Any]]
    var tabs = strips[0]["tabs"] as! [[String: Any]]
    tabs[0]["loading"] = true; tabs[0]["audible"] = true; tabs[0]["canGoBack"] = true; tabs[0]["canGoForward"] = true
    strips[0]["tabs"] = tabs; metadata["strips"] = strips
    engine.windowHost(host, didReceiveTransaction: metadata)
    try await matrixWait { applied }
    #expect(engine.checkSelectionState()["generation"] as? Int == generation)
    #expect(fake.activated.isEmpty)
    #expect(engine.rowStates[row.0]?.loading == true)
    #expect(engine.rowStates[row.0]?.canGoBack == true)
    #expect(engine.rowStates[row.0]?.canGoForward == true)
    var registered: (() -> Void)?
    var resolved: (() -> Void)?
    engine.checkSelectionDispatch = { stage, _, resume in
        if stage == "registered" { registered = resume } else { resolved = resume }
    }
    engine.select(id: row.0, url: row.1)
    try await matrixWait { registered != nil }
    let early = try #require(engine.checkInFlightSelection(item: row.0))
    let command = try #require(early.command)
    #expect(!early.resolved && !early.activated)
    let resumeRegistered = try #require(registered)
    resumeRegistered()
    try await matrixWait { resolved != nil }
    let middle = try #require(engine.checkInFlightSelection(item: row.0))
    #expect(middle.command == command && middle.resolved && !middle.activated)
    let resumeResolved = try #require(resolved)
    resumeResolved()
    try await matrixWait { fake.activated.contains(command) }
    let active = try #require(engine.checkInFlightSelection(item: row.0))
    #expect(active.command == command && active.activated)
    applied = false
    engine.windowHost(host, didReceiveTransaction: matrixTransaction(fake, window: "join", epoch: 1, rev: 2, command: command))
    try await matrixWait { applied }
    #expect(engine.checkInFlightSelection(item: row.0) == nil)
    engine.shutdown()
}

@Test @MainActor
func privacyFlagsRequireAnExplicitBoolean() {
    #expect(EngineAdapter.privacyFlag([:]) == nil)
    #expect(EngineAdapter.privacyFlag(["off_the_record": true]) == true)
    #expect(EngineAdapter.privacyFlag(["off_the_record": false]) == false)
    #expect(EngineAdapter.privacyFlag(["off_the_record": "true"]) == nil)
}

@Test @MainActor
func privacyFlagsRejectMissingTransactionOrTabFlags() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: dir.appendingPathComponent("db").path, windowID: "flags", card: NSView(), seedProfiles: true, session: session)
    let (fake, host) = matrixFake()
    engine.attach(host)
    var received = 0
    engine.onTransaction = { _, _ in received += 1 }
    var initial = matrixTransaction(fake, window: "flags", epoch: 1, rev: 0, command: nil)
    initial.removeValue(forKey: "off_the_record")
    engine.windowHost(host, didReceiveTransaction: initial)
    #expect(received == 0)
    initial["off_the_record"] = false
    engine.windowHost(host, didReceiveTransaction: initial)
    try await matrixWait { received == 1 }
    let row = try session.queue.sync { () -> String in
        let store = try #require(session.store)
        return try #require(store.snapshot(windowId: "flags").spaces.first?.today.first?.id)
    }
    fake.entries.append(MatrixFakeTab(item: row, live: "live", profile: "Default", owner: fake))
    var transaction = matrixTransaction(fake, window: "flags", epoch: 1, rev: 1, command: nil)
    var strips = transaction["strips"] as! [[String: Any]]
    var tabs = strips[0]["tabs"] as! [[String: Any]]
    tabs[0].removeValue(forKey: "off_the_record")
    strips[0]["tabs"] = tabs
    transaction["strips"] = strips
    engine.windowHost(host, didReceiveTransaction: transaction)
    #expect(received == 1)
    tabs[0]["off_the_record"] = false
    strips[0]["tabs"] = tabs
    transaction["strips"] = strips
    engine.windowHost(host, didReceiveTransaction: transaction)
    try await matrixWait { received == 2 }
    engine.shutdown()
}

@Test @MainActor
func settingsSpaceDeletionFollowsTheNeighboursProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("db").path, windowID: "settings-delete", card: NSView(), seedProfiles: true, session: session)
    defer { engine.shutdown() }
    let (fake, host) = matrixFake()
    let runtime = Runtime(windowID: "settings-delete")
    runtime.host = host
    runtime.snapshot = try session.queue.sync {
        try #require(session.store).showSpaceSelecting(windowId: "settings-delete", spaceId: "default")
    }
    let renamed = try session.queue.sync {
        try #require(session.store).renameSpace(windowId: "settings-delete", spaceId: "default", name: "Renamed")
    }
    runtime.showWorkspaceEdit(renamed)
    #expect(runtime.snapshot == renamed)
    #expect(fake.shownProfile == "Default")
    let deleted = try session.queue.sync {
        try #require(session.store).liveDeleteSpace(windowId: "settings-delete", spaceId: "default").snapshot
    }
    runtime.showWorkspaceEdit(deleted)
    let neighbour = try #require(deleted.spaces.first { $0.id == deleted.shownSpaceId })
    #expect(neighbour.profileName != "Default")
    #expect(fake.shownProfile == neighbour.profileName)
    #expect(runtime.snapshot == deleted)
}

@Test @MainActor
func backgroundSpaceDeletionLeavesSelectionAndProfileAlone() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("db").path, windowID: "background-delete", card: NSView(), seedProfiles: true, session: session)
    defer { engine.shutdown() }
    let (fake, host) = matrixFake()
    let runtime = Runtime(windowID: "background-delete")
    runtime.host = host
    runtime.snapshot = try session.queue.sync {
        try #require(session.store).showSpaceSelecting(windowId: "background-delete", spaceId: "default")
    }
    let selected = runtime.snapshot.selectedId
    fake.shownProfile = "untouched"
    let deleted = try session.queue.sync {
        try #require(session.store).liveDeleteSpace(windowId: "background-delete", spaceId: "named").snapshot
    }
    runtime.showWorkspaceEdit(deleted)
    #expect(runtime.snapshot == deleted)
    #expect(runtime.snapshot.selectedId == selected)
    #expect(runtime.snapshot.shownSpaceId == "default")
    #expect(fake.shownProfile == "untouched")
    #expect(fake.activated.isEmpty && fake.opened.isEmpty)
}
