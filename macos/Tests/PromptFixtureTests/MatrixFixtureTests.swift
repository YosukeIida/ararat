import AppKit
import AraratEngineAPI
@testable import AraratKit
import AraratUI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor
private final class MatrixFakeTab: NSObject {
    @objc dynamic var liveId: String
    @objc dynamic var itemId: String?
    @objc dynamic var isLoading = false
    @objc dynamic var crashed = false
    @objc dynamic var networkError = 0
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
    var captureCompletions: [(NSImage?) -> Void] = []
    var remotePlaceholder = false
    private lazy var fakeWindow: NSWindow = {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
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
    @objc(setProfileDirectory:) func setProfile(_ name: String) -> Bool { shownProfile = name; return true }
    @objc func activeItemId() -> String? { active }
    @objc func tabs() -> [Any] { entries }
    @objc func setWorkspacePageHidden(_ value: Bool) { hidden = value }
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
        if handoffAttempts == failHandoffAt { return false }
        return move(value, activate: activate, command: "handoff")
    }
    private func move(_ value: AnyObject, activate: Bool, command: String) -> Bool {
        guard let tab = value as? MatrixFakeTab, let source = tab.owner else { return false }
        source.entries.removeAll { $0 === tab }
        if source.active == tab.itemId { source.active = source.entries.first?.itemId }
        tab.owner = self
        entries.append(tab)
        if activate { active = tab.itemId }
        activated.append(command)
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
private func matrixWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
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
    #expect(a.minX == b.minX && a.maxY <= b.minY && b.maxX < c.minX)
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
