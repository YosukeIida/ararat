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
