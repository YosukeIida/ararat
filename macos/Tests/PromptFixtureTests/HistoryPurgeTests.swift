import Foundation
import AraratKit
import Testing
@testable import Ararat

@Test @MainActor
func historyPurgeReloadsAnUnloadedPinOnlyWhileItIsStillSelected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let store = try WorkspaceStore.open(path: directory.appendingPathComponent("workspace.sqlite").path)
    let space = try store.createSpace(windowId: "one", name: "Space", spaceId: "space")
    let pinned = try #require(store.createTab(windowId: "one", url: "https://pin.example/").selectedId)
    let pinnedContainer = try #require(space.spaces.first?.pinnedId)
    _ = try store.moveItem(windowId: "one", id: pinned, container: pinnedContainer, index: 0, openFolder: false)
    let other = try #require(store.createTab(windowId: "one", url: "https://other.example/").selectedId)
    session.queue.sync { session.store = store }
    let selected = try session.queue.sync {
        _ = try store.selectItem(windowId: "one", id: pinned)
        _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine, strips: []))
        return store.snapshot(windowId: "one")
    }
    #expect(selected.selectedId == nil)
    #expect(selected.spaces.flatMap(\.pinned).first { $0.id == pinned }?.unloaded == true)
    #expect(HistoryPurgeCheck.selectedPinnedItem(session: session, windowID: "one", pinned: pinned) == pinned)
    let newer = try session.queue.sync {
        _ = try store.selectItem(windowId: "one", id: other)
        _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 2, rev: 0, cause: .engine, strips: []))
        return store.snapshot(windowId: "one")
    }
    #expect(newer.selectedId == nil)
    #expect(HistoryPurgeCheck.selectedPinnedItem(session: session, windowID: "one", pinned: pinned) == nil)
}

@Test @MainActor
func historyPurgeRemainsPendingOnFailureAndAcknowledgesOnRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let store = try WorkspaceStore.open(path: directory.appendingPathComponent("workspace.sqlite").path)
    _ = try store.createSpace(windowId: "one", name: "Space", spaceId: "space")
    let snapshot = try store.createTab(windowId: "one", url: "https://example.test/")
    let item = try #require(snapshot.selectedId)
    _ = try store.archiveItem(windowId: "one", id: item)
    let purge = try #require(store.pendingHistoryPurges().first)
    session.queue.sync { session.store = store }
    var attempts: [(String, String, UInt64)] = []
    session.purgeHistory = { profile, item, stamp, completion in
        attempts.append((profile, item, stamp))
        completion(attempts.count > 1)
    }
    session.queue.async { session.drainHistoryPurges() }
    for _ in 0..<200 {
        if attempts.count == 1 && session.queue.sync(execute: { (try? store.pendingHistoryPurges().count) == 1 }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(attempts.count == 1)
    #expect(try store.pendingHistoryPurges().count == 1)
    session.queue.async { session.drainHistoryPurges() }
    for _ in 0..<200 {
        if attempts.count == 2 && session.queue.sync(execute: { (try? store.pendingHistoryPurges().isEmpty) == true }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(attempts.count == 2)
    #expect(attempts[0].0 == "Default")
    #expect(attempts[0].1 == item)
    #expect(attempts[0].2 == purge.changedAt)
    #expect(try store.pendingHistoryPurges().isEmpty)
}
