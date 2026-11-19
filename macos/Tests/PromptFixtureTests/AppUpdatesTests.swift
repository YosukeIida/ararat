import AppKit
import Testing
@testable import Ararat

@Test @MainActor
func updaterRequiresAConfiguredFeedAndPublicKey() throws {
    let menu = NSMenu()
    AppUpdates.install(in: menu, owner: nil, info: [:])
    let item = try #require(menu.items.first)
    #expect(item.title == "Check for Updates…")
    #expect(!item.isEnabled)
    #expect(item.action == nil)

    let key = Data(repeating: 0, count: 32).base64EncodedString()
    var info = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key]
    #expect(AppUpdates.channels(for: info) == [])
    info["AraratUpdateChannel"] = "nightly"
    #expect(AppUpdates.channels(for: info) == ["nightly"])
    info["SUFeedURL"] = "http://example.com/appcast.xml"
    #expect(AppUpdates.channels(for: info) == nil)
    info["SUFeedURL"] = "http://localhost:8765/appcast.xml"
    #expect(AppUpdates.channels(for: info) == ["nightly"])
    info["SUPublicEDKey"] = "invalid"
    #expect(AppUpdates.channels(for: info) == nil)
}
