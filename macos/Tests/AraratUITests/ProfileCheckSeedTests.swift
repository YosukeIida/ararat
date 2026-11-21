import AppKit
import AraratKit
import Foundation
import Testing

@Test @MainActor func profileCheckSeedCreatesTwoProfilesWithOneRowEach() throws {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    let adapter = try EngineAdapter(path: path, windowID: "check", card: NSView(), seedProfiles: true)
    let snapshot = adapter.session.queue.sync { adapter.session.store!.snapshot(windowId: "check") }
    #expect(snapshot.spaces.count == 2)
    #expect(snapshot.spaces.map(\.today.count) == [1, 1])
    #expect(snapshot.spaces.map(\.profileName) == ["Default", "Profile 1"])
}

@Test @MainActor func dockCheckSeedHasTwelveSpacesAndForeignDropTarget() throws {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    let adapter = try EngineAdapter(path: path, windowID: "dock-check", card: NSView(), seedDock: true)
    let snapshot = adapter.session.queue.sync { adapter.session.store!.snapshot(windowId: "dock-check") }
    #expect(snapshot.shownSpaceId == "default")
    #expect(snapshot.spaces.count == 13)
    #expect(snapshot.spaces.prefix(12).allSatisfy { $0.profileKey == snapshot.spaces[0].profileKey && $0.look != nil })
    #expect(snapshot.spaces.last?.id == "named")
    #expect(snapshot.spaces.last?.profileKey != snapshot.spaces[0].profileKey)
    #expect(snapshot.spaces[1].id == "dock-0")
    #expect(snapshot.spaces[1].today.contains { $0.url == "about:blank?dock-drag" })
    #expect(snapshot.spaces[0].favorites.map(\.url) == ["about:blank?dock-favorite-default"])
    #expect(snapshot.spaces[1].favorites.map(\.url) == ["about:blank?dock-favorite-dock-0"])
}
