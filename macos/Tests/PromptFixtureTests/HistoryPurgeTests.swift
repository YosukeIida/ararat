import Foundation
import AraratKit
import Testing

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
