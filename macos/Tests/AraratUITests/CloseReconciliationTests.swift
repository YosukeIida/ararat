import Foundation
import AppKit
import Testing
@testable import AraratKit

@Test
func cancelledCloseSelectsTheSplitMemberInTheForcedProfile() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let store = try WorkspaceStore.open(path: directory.appendingPathComponent("close.sqlite").path)
    _ = try store.importArcSidebar(windowId: "one", json: json, windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
    try store.showSpace(windowId: "one", spaceId: "space-work")
    _ = try store.selectItem(windowId: "one", id: "split-1")
    try store.showSpace(windowId: "one", spaceId: "space-home")
    _ = try store.createTab(windowId: "one", url: "https://home.example")
    let restored = try EngineAdapter.snapshotAfterCloseCancellation(store: store, windowID: "one", forcedProfile: "Default")
    #expect(restored.shownSpaceId == "space-work" && restored.selectedId == "tab-a")
    _ = try store.showSpaceSelectingTab(windowId: "one", spaceId: "space-work", itemId: "tab-spec")
    try store.showSpace(windowId: "one", spaceId: "space-home")
    let accepted = try EngineAdapter.snapshotAfterCloseCancellation(store: store, windowID: "one", forcedProfile: "Default")
    #expect(accepted.shownSpaceId == "space-work" && accepted.selectedId == "tab-spec")
}

@Test
@MainActor
func splitCloseCheckFixtureSelectsTheNamedSpaceSplitMember() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("split-close.sqlite").path,
                                    windowID: "one", card: NSView(), seedProfiles: true, seedSplitCheck: true)
    try adapter.session.queue.sync {
        let store = try #require(adapter.session.store)
        try store.showSpace(windowId: "one", spaceId: "named")
        _ = try store.selectItem(windowId: "one", id: "close-split")
        try store.showSpace(windowId: "one", spaceId: "default")
        let selected = try store.showSpaceSelecting(windowId: "one", spaceId: "named")
        #expect(selected.shownSpaceId == "named" && selected.selectedId == "close-split-a")
    }
}

@Test(arguments: [false, true]) @MainActor
func missingBulkAndSplitTabsSettleTheirClosesAndDrainHeldPurges(split: Bool) async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let engine = try EngineAdapter(path: directory.appendingPathComponent("missing.sqlite").path,
                                   windowID: "one", card: NSView(), session: session)
    let store = try #require(session.store)
    _ = try store.createSpace(windowId: "one", name: "Work", spaceId: "work")
    let first = try #require(store.createTab(windowId: "one", url: "https://a.example/").selectedId)
    let second = try #require(store.createTab(windowId: "one", url: "https://b.example/").selectedId)
    let change = try store.makeSplit(windowId: "one", draggedId: second, targetId: first, side: .right)
    let ids = [first, second]
    let tabs = try ids.map { id -> LiveTab in
        let command = try store.liveOpen(item: id, url: "https://example.test/")
        return LiveTab(offTheRecord: false, profile: .default, liveId: command.id, item: id,
                       opener: nil, navigated: true, url: "https://example.test/", title: nil)
    }
    _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine,
        strips: [LiveStrip(window: "one", tabs: tabs, active: tabs.first?.liveId)]))
    var submitted = Set<String>()
    session.purgeHistory = { _, item, _, completion in submitted.insert(item); completion(true) }
    if split {
        engine.close(id: change.split)
    } else {
        let batch = try store.liveClearToday(windowId: "one", spaceId: "work")
        #expect(try store.pendingHistoryPurges().isEmpty)
        session.closeLiveTargets(batch.targets, report: { _ in })
    }
    try await waitUntil { submitted == Set(ids) && session.queue.sync { (try? store.pendingHistoryPurges().isEmpty) == true } }
    #expect(try store.pendingHistoryPurges().isEmpty)
    #expect(ids.allSatisfy { store.liveTab(item: $0) == nil })
    engine.shutdown()
}
