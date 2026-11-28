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
    info["AraratUpdateChannel"] = "preview"
    #expect(AppUpdates.channels(for: info) == ["preview"])
    info["SUFeedURL"] = "http://example.com/appcast.xml"
    #expect(AppUpdates.channels(for: info) == nil)
    info["SUFeedURL"] = "http://localhost:8765/appcast.xml"
    #expect(AppUpdates.channels(for: info) == ["preview"])
    info["SUPublicEDKey"] = "invalid"
    #expect(AppUpdates.channels(for: info) == nil)
}

@Test @MainActor
func previewUpdaterRejectsUntaggedStableItems() throws {
    let updates = AppUpdates(channels: ["preview"])
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updates,
                                                  userDriverDelegate: nil)
    var properties: [String: Any] = [
        "title": "Ararat", "sparkle:version": "1.2",
        "enclosure": ["url": "https://example.com/Ararat.zip"],
    ]
    let untagged = try #require(SUAppcastItem(dictionary: properties))
    do {
        try updates.updater(controller.updater, shouldProceedWithUpdate: untagged, updateCheck: .updates)
        Issue.record("Preview accepted an untagged update")
    } catch let error as NSError {
        #expect(error.domain == "AraratUpdates")
    }

    properties["sparkle:channel"] = "preview"
    let preview = try #require(SUAppcastItem(dictionary: properties))
    try updates.updater(controller.updater, shouldProceedWithUpdate: preview, updateCheck: .updates)
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

@Test @MainActor
func sparkleDelegateTracksCheckResultsAndInstallsThePendingUpdateOnce() throws {
    let updates = AppUpdates(channels: [])
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updates, userDriverDelegate: nil)
    let updater = controller.updater
    let properties: [String: Any] = [
        "title": "Ararat 1.2", "sparkle:version": "1.2",
        "enclosure": ["url": "https://example.com/Ararat.zip"],
    ]
    let item = try #require(SUAppcastItem(dictionary: properties))

    try updates.updater(updater, mayPerform: .updates)
    #expect(updates.state == .checking)
    updates.updater(updater, willDownloadUpdate: item, with: NSMutableURLRequest(url: try #require(item.fileURL)))
    #expect(updates.state == .downloading("1.2", nil))

    var installs = 0
    #expect(updates.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { installs += 1 }) == true)
    #expect(updates.state == .ready("1.2"))
    updates.restartToUpdate()
    updates.restartToUpdate()
    #expect(installs == 1)

    var criticalProperties = properties
    criticalProperties["sparkle:criticalUpdate"] = [String: String]()
    let critical = try #require(SUAppcastItem(dictionary: criticalProperties))
    #expect(!updates.updater(updater, willInstallUpdateOnQuit: critical, immediateInstallationBlock: {}))

    let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue),
                        userInfo: [NSLocalizedDescriptionKey: "Download failed"])
    updates.updater(updater, didFinishUpdateCycleFor: .updates, error: error)
    #expect(updates.state == .failed("Download failed"))

    try updates.updater(updater, mayPerform: .updates)
    let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
    updates.updater(updater, didFinishUpdateCycleFor: .updates, error: noUpdate)
    if case .upToDate = updates.state {} else { Issue.record("Expected the up-to-date state") }

    let incompatible = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                               userInfo: [SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.systemIsTooOld.rawValue,
                                          NSLocalizedRecoverySuggestionErrorKey: "Requires a newer macOS"])
    updates.updater(updater, didFinishUpdateCycleFor: .updates, error: incompatible)
    #expect(updates.state == .noCompatibleUpdate("Requires a newer macOS"))
}
