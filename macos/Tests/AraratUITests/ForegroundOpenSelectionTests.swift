import Foundation
import AraratKit
import Testing

@Test
func hiddenEmptyWindowSelectsForegroundOpenAfterUnselectedPinDrop() throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore.open(path: directory.appendingPathComponent("workspace.sqlite").path)
    _ = try store.createSpace(windowId: "one", name: "Work", spaceId: "work")
    let old = try #require(store.createTab(windowId: "one", url: "https://old.example/").selectedId)
    let opened = try #require(store.createTab(windowId: "one", url: "https://opened.example/").selectedId)
    _ = try store.selectItem(windowId: "one", id: old)
    _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 0, cause: .engine, strips: []))
    let command = try store.liveOpen(item: opened, url: "https://opened.example/")
    let drop = try store.moveItem(windowId: "one", id: opened, container: "work:pinned", index: 0, openFolder: false)
    #expect(drop.selectedId == nil)
    #expect(store.selectedItem(windowId: "one") == old)
    let tab = LiveTab(offTheRecord: false, profile: .default, liveId: command.id, item: opened,
                      opener: nil, navigated: false, url: nil, title: nil)
    let completion = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 1,
        cause: .command(command.id), strips: [LiveStrip(window: "one", tabs: [tab], active: command.id)]))
    #expect(completion.applied)
    #expect(store.selectedItem(windowId: "one") == opened)
    #expect(store.snapshot(windowId: "one").selectedId == opened)
    _ = try store.liveApply(transaction: LiveTransaction(offTheRecord: false, epoch: 1, rev: 2,
        cause: .engine, strips: [LiveStrip(window: "one", tabs: [tab], active: nil)]))
    #expect(store.selectedItem(windowId: "one") == opened)
}
