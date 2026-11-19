import AppKit
import Sparkle
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

@Test @MainActor
func sparkleRelaunchDelegateBypassesQuitConfirmationUntilTheCycleEnds() {
    let updates = AppUpdates(channels: [])
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updates, userDriverDelegate: nil)

    func shouldAsk() -> Bool {
        let source = QuitConfirmation.source(poweringOff: false, quitReason: nil,
                                             sparkleRelaunching: updates.isRelaunching, checkBypass: false)
        return QuitConfirmation.shouldAsk(source: source, warn: true, visible: [.regular])
    }

    let delegate: any SPUUpdaterDelegate = updates
    #expect(shouldAsk())
    delegate.updaterWillRelaunchApplication?(controller.updater)
    #expect(!shouldAsk())
    delegate.updater?(controller.updater, didFinishUpdateCycleFor: .updates, error: nil)
    #expect(shouldAsk())
}
