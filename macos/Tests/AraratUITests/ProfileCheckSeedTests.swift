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
