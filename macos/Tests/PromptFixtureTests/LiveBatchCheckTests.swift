import Foundation
import Testing
import AraratKit
@testable import Ararat

@Test @MainActor
func liveBatchFixtureBackdatesTodayAndKeepsAProfileNeighbour() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let path = directory.appendingPathComponent("live.sqlite").path
    try LiveBatchCheck.seed(session, path: path, window: "one")
    try session.queue.sync {
        let store = try #require(session.store)
        let snapshot = store.snapshot(windowId: "one")
        #expect(snapshot.shownSpaceId == "default")
        #expect(snapshot.spaces.first { $0.id == "named" }?.profileName == "Profile 1")
        let space = try #require(snapshot.spaces.first { $0.id == "default" })
        #expect(space.archiveAfter == .hours12)
        #expect(snapshot.selectedId == "selected")
        let expired = try #require(space.today.first { $0.id == "expired" })
        let at = try #require(expired.lastSelectedAt)
        #expect(UInt64(Date().timeIntervalSince1970 * 1000) > at + 12 * 3_600_000)
        #expect(try store.liveAutoArchive(windowId: "one", now: at + 12 * 3_600_000) == nil)
        let batch = try #require(try store.liveAutoArchive(windowId: "one", now: at + 12 * 3_600_000 + 1))
        #expect(batch.snapshot.archive.contains { $0.id == "expired" })
        #expect(batch.snapshot.spaces.flatMap(\.pinned).contains { $0.id == "pinned" })
        #expect(batch.snapshot.spaces.flatMap(\.today).contains { $0.id == "selected" })
        #expect(try store.liveAutoArchive(windowId: "one", now: UInt64(Date().timeIntervalSince1970 * 1000) + 13 * 3_600_000) == nil)
    }
}

@Test(arguments: ["auto-archive", "delete-space-live"]) @MainActor
func liveBatchChecksRequireEveryNamedCondition(mode: String) throws {
    let check = LiveBatchCheck()
    #expect(check.diagnostics(mode)["failed_conditions"] as? [String] == LiveBatchCheck.names(mode))
    for name in LiveBatchCheck.names(mode) { check.mark(mode, name, true) }
    #expect((check.diagnostics(mode)["failed_conditions"] as? [String])?.isEmpty == true)
}

@Test @MainActor
func deletedSpaceCheckReadsTheArchivedRowOutsideTheNeighboursProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let path = directory.appendingPathComponent("delete.sqlite").path
    try LiveBatchCheck.seed(session, path: path, window: "one")
    let store = try #require(session.store)
    #expect(!LiveBatchCheck.deletedRowIsArchived(checkRecords(path)))
    let deleted = try store.liveDeleteSpace(windowId: "one", spaceId: "default")
    #expect(deleted.snapshot.shownSpaceId == "named")
    #expect(deleted.snapshot.archive.isEmpty)
    #expect(LiveBatchCheck.deletedRowIsArchived(checkRecords(path)))
    #expect(!LiveBatchCheck.deletedRowIsArchived(nil))
    _ = try store.restoreItem(windowId: "one", id: "selected")
    #expect(!LiveBatchCheck.deletedRowIsArchived(checkRecords(path)))
}
