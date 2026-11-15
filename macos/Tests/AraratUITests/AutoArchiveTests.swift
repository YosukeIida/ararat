import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func archiveValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@Test @MainActor
func archiveSettingsReadWriteSearchAndExternalUpdatesUseTheShownProfile() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "archive-settings")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await archiveValue { adapter.open(path: directory.appendingPathComponent("settings.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    #expect(model.archiveAfter == .hours12)
    model.query = "Archive Today"
    let row = try #require(model.results.first)
    #expect(row.id == "archive-after" && row.pane == .tabs)
    #expect(row.subtitle.contains(model.archiveSpace?.profileName ?? "Default"))
    model.select(row)
    #expect(model.page == .tabs && model.highlighted == row.id)
    for value: ArchiveAfter in [.hours24, .days7, .days30, .hours12] {
        model.setArchiveAfter(value)
        try await waitUntil { model.archiveAfter == value }
        let stored = try await archiveValue { adapter.snapshot(completion: $0) }
        #expect(stored.spaces.first { $0.id == snapshot.shownSpaceId }?.archiveAfter == value)
    }
    let id = try #require(model.archiveSpace?.id)
    let external = try await archiveValue { adapter.setArchiveAfter(spaceID: id, value: .days7, completion: $0) }
    model.update(snapshot: external)
    #expect(model.archiveAfter == .days7)
    _ = try await archiveValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

@Test @MainActor
func archiveLaunchAndTimerTickUseInjectedClockAndPublishSidebarAndLibrary() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "archive-timer")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"folder-docs\"", with: "\"parentID\": \"today-work\"")
    let snapshot = try await archiveValue { adapter.open(path: directory.appendingPathComponent("timer.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let tabs = snapshot.spaces.flatMap(\.today).filter { $0.kind == .tab }
    let expiredID = try #require(tabs.first?.id)
    let sidebar = SidebarView(snapshot: snapshot)
    var clock = try #require(tabs.first?.lastSelectedAt) + 12 * 3_600_000
    var received: WorkspaceSnapshot?
    let archive = AutoArchive(adapter: adapter, now: { clock }) { result in
        if case .success(let value) = result { received = value; sidebar.applySelection(snapshot: value) }
    }
    archive.start()
    _ = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(received == nil)
    #expect(archive.timer?.timeInterval == 60 && archive.timer?.tolerance == 20)
    received = nil
    clock += 1
    archive.tick()
    try await waitUntil { received?.archive.contains { $0.id == expiredID } == true }
    #expect(received?.spaces.flatMap(\.today).contains { $0.id == expiredID } == false)
    #expect(!sidebar.selectRow(id: expiredID))
    sidebar.setLibraryOpen(true)
    #expect(sidebar.libraryOpen)
    let library = try #require(archiveDescendants(sidebar).compactMap { $0 as? LibraryView }.first)
    #expect(library.filteredEntries.contains { $0.id == expiredID })
    received = nil
    archive.tick()
    _ = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(received == nil)
    archive.stop()
    _ = try await archiveValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

@MainActor
private func archiveDescendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + archiveDescendants($0) } }

@Test(arguments: ["quiet", "window", "ended", "cancelled"]) @MainActor
func lostScrollEndDefersOnlyPublishUntilQuietOrWindowMove(recovery: String) async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "archive-lost-end")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"folder-docs\"", with: "\"parentID\": \"today-work\"")
    let snapshot = try await archiveValue { adapter.open(path: directory.appendingPathComponent("lost-end.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let tab = try #require(snapshot.spaces.flatMap(\.today).first { $0.kind == .tab })
    let sidebar = SidebarView(snapshot: snapshot)
    var gestureClock = 100.0
    sidebar.pullClock = { gestureClock }
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -10, wheel2: 0, wheel3: 0))
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    #expect(!sidebar.canPublishAutoArchive)
    let clock = try #require(tab.lastSelectedAt) + 12 * 3_600_000 + 1
    var received: WorkspaceSnapshot?
    let archive = AutoArchive(adapter: adapter, now: { clock }, canPublish: { sidebar.canPublishAutoArchive }) { result in
        if case .success(let value) = result { received = value }
    }
    sidebar.onAutoArchiveReady = { [weak archive] in archive?.publishDeferred() }
    archive.tick()
    let archived = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(archived.archive.contains { $0.id == tab.id })
    #expect(received == nil)
    gestureClock += 1.99
    #expect(!sidebar.canPublishAutoArchive)
    if recovery == "window" { sidebar.viewDidMoveToWindow() }
    else if recovery == "quiet" {
        gestureClock += 0.02
        #expect(sidebar.canPublishAutoArchive)
        gestureClock -= 0.02
        #expect(!sidebar.canPublishAutoArchive)
        gestureClock += 0.02
    } else {
        let phase = recovery == "ended" ? CGScrollPhase.ended : .cancelled
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        if recovery == "ended" {
            gestureClock += SidebarMetrics.momentumQuiet
            sidebar.stepMomentumQuiet()
        }
    }
    #expect(sidebar.canPublishAutoArchive)
    if recovery == "quiet" || recovery == "window" { archive.tick() }
    try await waitUntil { received != nil }
    #expect(received?.archive.contains { $0.id == tab.id } == true)
    _ = try await archiveValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

@Test @MainActor
func lostMomentumEndStillPublishesAfterTheStalenessWindow() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "archive-lost-momentum")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"folder-docs\"", with: "\"parentID\": \"today-work\"")
    let snapshot = try await archiveValue { adapter.open(path: directory.appendingPathComponent("lost-momentum.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let tab = try #require(snapshot.spaces.flatMap(\.today).first { $0.kind == .tab })
    let sidebar = SidebarView(snapshot: snapshot)
    var gestureClock = 100.0
    sidebar.pullClock = { gestureClock }
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -10, wheel2: 0, wheel3: 0))
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    #expect(!sidebar.canPublishAutoArchive)
    let clock = try #require(tab.lastSelectedAt) + 12 * 3_600_000 + 1
    var received: WorkspaceSnapshot?
    let archive = AutoArchive(adapter: adapter, now: { clock }, canPublish: { sidebar.canPublishAutoArchive }) { result in
        if case .success(let value) = result { received = value }
    }
    sidebar.onAutoArchiveReady = { [weak archive] in archive?.publishDeferred() }
    archive.tick()
    let archived = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(archived.archive.contains { $0.id == tab.id })
    #expect(received == nil)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.begin.rawValue))
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.continuous.rawValue))
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    #expect(!sidebar.canPublishAutoArchive)
    gestureClock += 2.01
    #expect(sidebar.canPublishAutoArchive)
    #expect(received == nil)
    archive.tick()
    try await waitUntil { received != nil }
    #expect(received?.archive.contains { $0.id == tab.id } == true)
    _ = try await archiveValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

@Test @MainActor
func deliverDuringThePendingQuietParksAndTheQuietStepPublishesItOnce() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "archive-quiet-deliver")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"folder-docs\"", with: "\"parentID\": \"today-work\"")
    let snapshot = try await archiveValue { adapter.open(path: directory.appendingPathComponent("quiet-deliver.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let tab = try #require(snapshot.spaces.flatMap(\.today).first { $0.kind == .tab })
    let sidebar = SidebarView(snapshot: snapshot)
    var gestureClock = 100.0
    sidebar.pullClock = { gestureClock }
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -10, wheel2: 0, wheel3: 0))
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    #expect(!sidebar.canPublishAutoArchive)
    let clock = try #require(tab.lastSelectedAt) + 12 * 3_600_000 + 1
    var received: WorkspaceSnapshot?
    var publishes = 0
    let archive = AutoArchive(adapter: adapter, now: { clock }, canPublish: { sidebar.canPublishAutoArchive }) { result in
        if case .success(let value) = result { received = value; publishes += 1 }
    }
    sidebar.onAutoArchiveReady = { [weak archive] in archive?.publishDeferred() }
    archive.tick()
    let archived = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(archived.archive.contains { $0.id == tab.id })
    #expect(received == nil)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    archive.tick()
    _ = try await archiveValue { adapter.snapshot(completion: $0) }
    // A publish that lands during the quiet is delivered behind the first round trip; the
    // second one gives it room to land before the park is judged.
    _ = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(received == nil)
    #expect(publishes == 0)
    gestureClock += SidebarMetrics.momentumQuiet
    sidebar.stepMomentumQuiet()
    try await waitUntil { publishes == 1 }
    #expect(publishes == 1)
    #expect(received?.archive.contains { $0.id == tab.id } == true)
    // A pending quiet must not block past the staleness window.
    sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    #expect(!sidebar.canPublishAutoArchive)
    gestureClock += 1.99
    #expect(!sidebar.canPublishAutoArchive)
    gestureClock += 0.02
    #expect(sidebar.canPublishAutoArchive)
    _ = try await archiveValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

@Test @MainActor
func archiveReplyDuringAGestureWaitsForNextTickAndPublishesAFreshSnapshot() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "archive-deferred")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"folder-docs\"", with: "\"parentID\": \"today-work\"")
    let snapshot = try await archiveValue { adapter.open(path: directory.appendingPathComponent("deferred.sqlite").path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let tab = try #require(snapshot.spaces.flatMap(\.today).first { $0.kind == .tab })
    let pin = try #require(snapshot.spaces.flatMap(\.favorites).first { $0.kind == .tab })
    let clock = try #require(tab.lastSelectedAt) + 12 * 3_600_000 + 1
    var busy = true
    var received: WorkspaceSnapshot?
    let archive = AutoArchive(adapter: adapter, now: { clock }, canPublish: { !busy }) { result in
        if case .success(let value) = result { received = value }
    }
    archive.tick()
    let skipped = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(skipped.archive.contains { $0.id == tab.id } && received == nil)
    busy = false
    archive.tick()
    busy = true
    let archived = try await archiveValue { adapter.snapshot(completion: $0) }
    #expect(archived.archive.contains { $0.id == tab.id })
    #expect(received == nil)
    _ = try await archiveValue { adapter.select(id: pin.id, completion: $0) }
    busy = false
    archive.tick()
    try await waitUntil { received != nil }
    #expect(received?.selectedId == pin.id)
    #expect(received?.archive.contains { $0.id == tab.id } == true)
    archive.stop()
    _ = try await archiveValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}

@Test @MainActor
func workspaceBatchEditsPublishCommittedSnapshotsWhenLiveTabsAreMissing() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let path = directory.appendingPathComponent("live-batch.sqlite").path
    let store = try WorkspaceStore.open(path: path)
    session.store = store
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
        .replacingOccurrences(of: "\"parentID\": \"folder-docs\"", with: "\"parentID\": \"today-work\"")
    _ = try store.importArcSidebar(windowId: "batch", json: json, windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
    var reports: [String] = []
    let adapter = WorkspaceAdapter(windowID: "batch", session: session, report: { reports.append(String(describing: $0)) })
    let archivedLive = try store.liveOpen(item: "tab-spec", url: "https://archive.test/")
    let archived: WorkspaceSnapshot? = try await archiveValue { adapter.autoArchive(now: UInt64.max, completion: $0) }
    #expect(archived?.archive.contains { $0.id == "tab-spec" } == true)
    #expect(store.liveTab(item: "tab-spec") == nil)
    #expect(reports.count == 1)
    #expect(reports.first?.contains(archivedLive.id) == true)
    let idle: WorkspaceSnapshot? = try await archiveValue { adapter.autoArchive(now: UInt64.max, completion: $0) }
    #expect(idle == nil)
    #expect(reports.count == 1)
    let created = try store.createTab(windowId: "batch", url: "https://delete.test/")
    let deletedID = try #require(created.selectedId)
    let deletedLive = try store.liveOpen(item: deletedID, url: "https://delete.test/")
    let deleted = try await archiveValue { adapter.deleteSpace(id: "space-work", completion: $0) }
    #expect(deleted.archive.contains { $0.id == deletedID })
    #expect(deleted.shownSpaceId == "space-home")
    #expect(deleted.spaces.count == 1)
    #expect(store.liveTab(item: deletedID) == nil)
    #expect(reports.count == 2)
    #expect(reports.last?.contains(deletedLive.id) == true)
}

@Test @MainActor
func engineRefreshesHoldArchivedRowsInEveryWindowAndResumeWithFreshSnapshots() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("held-engine.sqlite").path
    let session = WorkspaceSession()
    let first = try EngineAdapter(path: path, windowID: "first", card: NSView(), seedSingleCheck: true, session: session)
    let second = try EngineAdapter(path: path, windowID: "second", card: NSView(), session: session)
    let workspace = WorkspaceAdapter(windowID: "first", session: session)
    let store = try #require(session.store)
    _ = try store.createTab(windowId: "first", url: "https://protected.example/")
    let before = store.snapshot(windowId: "first")
    let row = try #require(before.spaces.flatMap(\.today).first { $0.url?.contains("Ararat One") == true })
    let space = try #require(before.shownSpaceId)
    try store.showSpace(windowId: "second", spaceId: space)
    var ready = false
    var attempts = 0
    var received: [String: WorkspaceSnapshot] = [:]
    for (id, engine) in [("first", first), ("second", second)] {
        engine.canPublishSnapshot = { attempts += 1; return ready }
        engine.onSnapshot = { received[id] = $0 }
    }
    let clock = try #require(row.lastSelectedAt) + 12 * 3_600_000 + 1
    let archive = AutoArchive(adapter: workspace, now: { clock }, canPublish: { ready }) { result in
        if case .success = result { first.refresh(); second.refresh() }
    }
    let otherArchive = AutoArchive(adapter: WorkspaceAdapter(windowID: "second", session: session), now: { clock }, canPublish: { ready }) { _ in second.refresh() }
    archive.onPublishReady = { first.publishDeferredSnapshot() }
    otherArchive.onPublishReady = { second.publishDeferredSnapshot() }
    archive.tick()
    let archived = try await archiveValue { workspace.snapshot(completion: $0) }
    #expect(archived.archive.contains { $0.id == row.id })
    otherArchive.tick()
    first.refresh()
    second.refresh()
    try await waitUntil { attempts >= 2 }
    #expect(received.isEmpty)
    let newer = try store.createTab(windowId: "first", url: "https://newer.example/")
    let added = try #require(newer.selectedId)
    ready = true
    archive.tick()
    otherArchive.tick()
    try await waitUntil { received.count == 2 }
    for snapshot in received.values {
        #expect(snapshot.archive.contains { $0.id == row.id })
        #expect(snapshot.spaces.flatMap(\.today).contains { $0.id == added })
    }
    first.onSnapshot = nil
    second.onSnapshot = nil
    first.shutdown()
    second.shutdown()
}

@Test(arguments: ["reveal", "gesture", "momentum"]) @MainActor
func engineHeldSnapshotPublishesWhenSidebarMotionExpires(motion: String) async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = try EngineAdapter(path: directory.appendingPathComponent("motion.sqlite").path,
                                   windowID: "motion", card: NSView(), seedSingleCheck: true)
    defer { engine.shutdown() }
    let store = try #require(engine.session.store)
    let sidebar = SidebarView(snapshot: store.snapshot(windowId: "motion"))
    var clock = 100.0
    sidebar.pullClock = { clock }
    let list = try #require(archiveDescendants(sidebar).compactMap { $0 as? SidebarScrollView }.first)
    list.clock = { clock }
    list.reduceMotion = { false }
    var received: WorkspaceSnapshot?
    var attempts = 0
    engine.canPublishSnapshot = { attempts += 1; return sidebar.canPublishAutoArchive }
    engine.onSnapshot = { received = $0 }
    sidebar.onAutoArchiveReady = { engine.publishDeferredSnapshot() }
    if motion == "reveal" {
        list.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        list.documentView?.frame = NSRect(x: 0, y: 0, width: 200, height: 1000)
        list.reveal(NSRect(x: 0, y: 800, width: 100, height: 30))
        #expect(list.isRevealing)
    } else {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -10, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        if motion == "momentum" {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.begin.rawValue))
            sidebar.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        }
    }
    #expect(!sidebar.canPublishAutoArchive)
    let next = try store.createTab(windowId: "motion", url: "https://held.example/")
    engine.refresh()
    try await waitUntil { attempts > 0 }
    #expect(received == nil)
    if motion == "reveal" {
        clock += 0.23
        list.stepReveal()
    } else {
        clock += 1.99
        sidebar.stepGestureExpiry()
        #expect(!sidebar.canPublishAutoArchive && received == nil)
        clock += 0.02
        sidebar.stepGestureExpiry()
    }
    #expect(sidebar.canPublishAutoArchive)
    try await waitUntil { received?.selectedId == next.selectedId }
    engine.onSnapshot = nil
    sidebar.onAutoArchiveReady = nil
}
