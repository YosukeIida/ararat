import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor
private final class MatrixFakeTab: NSObject {
    @objc dynamic var liveId: String
    @objc dynamic var itemId: String?
    @objc dynamic var isLoading = false
    weak var owner: MatrixFakeHost?
    var profile: String
    init(item: String, live: String, profile: String, owner: MatrixFakeHost) {
        self.itemId = item; self.liveId = live; self.profile = profile; self.owner = owner
    }
    @objc(activateWithCommandId:) func activate(_ command: String) {
        owner?.active = itemId
        owner?.activated.append(command)
    }
}

@MainActor
private final class MatrixFakeHost: NSObject {
    @objc dynamic weak var delegate: AnyObject?
    var entries: [MatrixFakeTab] = []
    var active: String?
    var shownProfile = "Default"
    var closing = false
    var hidden = false
    var activated: [String] = []
    var opened: [String] = []
    var presentationOverride: [String: Any]?
    @objc func isClosing() -> Bool { closing }
    @objc func isClosingAll() -> Bool { closing }
    @objc func profileDirectory() -> String { shownProfile }
    @objc(setProfileDirectory:) func setProfile(_ name: String) -> Bool { shownProfile = name; return true }
    @objc func activeItemId() -> String? { active }
    @objc func tabs() -> [Any] { entries }
    @objc func setWorkspacePageHidden(_ value: Bool) { hidden = value }
    @objc func hasActiveTab() -> Bool { !hidden && active != nil }
    @objc func navigationTarget() -> [String: Any]? { hasActiveTab() ? ["item": active!] : nil }
    @objc(checkPagePresentation:) func presentation(_ live: String) -> [String: Any] {
        if let override = presentationOverride { return override }
        let tab = entries.first { $0.itemId == active }
        let shown = !hidden && tab?.liveId == live
        return ["live": tab?.liveId ?? "", "target": shown, "host": shown, "visible": shown,
                "window": shown, "bounds": shown, "page_hit": shown, "compositor": "c1", "presented": shown]
    }
    @objc(openURL:commandId:itemId:profile:external:untrusted:)
    func open(_ url: String, command: String, item: String, profile: String, external: Bool, untrusted: Bool) -> Bool {
        entries.append(MatrixFakeTab(item: item, live: command, profile: profile, owner: self))
        active = item
        opened.append(command)
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
private func matrixTransaction(_ fake: MatrixFakeHost, window: String, epoch: UInt64, rev: UInt64, command: String?) -> [String: Any] {
    let tabs: [[String: Any]] = fake.entries.map { tab in
        ["profile": tab.profile, "live_id": tab.liveId, "item": tab.itemId as Any? ?? NSNull(),
         "opener": NSNull(), "url": NSNull(), "title": NSNull(), "navigated": false]
    }
    return ["epoch": NSNumber(value: epoch), "rev": NSNumber(value: rev),
            "cause": command.map { ["Command": $0] } as Any? ?? "Engine",
            "strips": [["window": window, "tabs": tabs,
                         "active": fake.entries.first(where: { $0.itemId == fake.active })?.liveId as Any? ?? NSNull()]]]
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
func matrixEmptyAndUnloadedSpacesHideRetainedPage() async throws {
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
        _ = try store.liveApply(transaction: LiveTransaction(epoch: 1, rev: 0, cause: .engine, strips: [LiveStrip(window: "empty", tabs: [], active: nil)]))
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
    for destination in ["unloaded", "empty-space"] {
        let snapshot = try session.queue.sync { try session.store!.showSpaceSelecting(windowId: "empty", spaceId: destination) }
        let space = try #require(snapshot.spaces.first(where: { $0.id == destination }))
        #expect(space.profileName == "Default" && snapshot.selectedId == nil)
        if destination == "unloaded" {
            let row = try #require(space.today.first)
            #expect(row.id == ids.1 && row.unloaded && row.url != nil)
        } else { #expect(space.today.isEmpty && space.pinned.isEmpty && space.favorites.isEmpty) }
        runtime.show(snapshot)
        #expect(fake.hidden && !fake.hasActiveTab() && fake.navigationTarget() == nil)
        #expect(fake.presentation(live)["presented"] as? Bool == false)
        #expect(fake.active == ids.0 && fake.entries.count == 1)
        #expect(session.queue.sync { session.store?.liveTab(item: ids.0) } == live)
    }
    let strip = LiveStrip(window: "empty", tabs: [LiveTab(profile: .default, liveId: live, item: ids.0, opener: nil, navigated: false, url: nil, title: nil)], active: nil)
    let after = try session.queue.sync { () -> WorkspaceSnapshot in
        let store = try #require(session.store)
        #expect(try store.liveApply(transaction: LiveTransaction(epoch: 1, rev: 2, cause: .engine, strips: [strip])).applied)
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
        try await matrixWait { accepted }
        #expect(runtime.matrixAcknowledgedLive == nil && runtime.spaceMatrixPhase == 10)
        #expect(fake.entries.count == 1)
    }
}
