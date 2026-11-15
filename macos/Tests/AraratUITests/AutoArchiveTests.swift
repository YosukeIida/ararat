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
func engineBatchEditsReturnArchivedRowsAndTheShownSpaceSuccessor() async throws {
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
    let engine = try EngineAdapter(path: path, windowID: "batch", card: NSView(), session: session)
    let archived: WorkspaceSnapshot? = try await withCheckedThrowingContinuation { continuation in
        engine.autoArchive(now: UInt64.max) { continuation.resume(with: $0) }
    }
    #expect(archived?.archive.contains { $0.id == "tab-spec" } == true)
    let idle: WorkspaceSnapshot? = try await withCheckedThrowingContinuation { continuation in
        engine.autoArchive(now: UInt64.max) { continuation.resume(with: $0) }
    }
    #expect(idle == nil)
    let deleted: WorkspaceSnapshot = try await withCheckedThrowingContinuation { continuation in
        engine.deleteSpace(id: "space-work") { continuation.resume(with: $0) }
    }
    #expect(deleted.shownSpaceId == "space-home")
    #expect(deleted.spaces.count == 1)
}
