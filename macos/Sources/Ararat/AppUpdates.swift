import AppKit
import Sparkle

@MainActor
final class AppUpdates: NSObject, SPUUpdaterDelegate {
    private static var delegateKey: UInt8 = 0
    private var controller: SPUStandardUpdaterController?
    private let channels: Set<String>
    private(set) var isRelaunching = false

    static func channels(for info: [String: Any]) -> Set<String>? {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.scheme == "https" || (url.scheme == "http" && host == "localhost"),
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        return info["AraratUpdateChannel"] as? String == "nightly" ? ["nightly"] : []
    }

    init(channels: Set<String>) {
        self.channels = channels
        super.init()
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        isRelaunching = true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isRelaunching = false
    }

    static func isRelaunching(owner: (any NSApplicationDelegate)?) -> Bool {
        guard let owner else { return false }
        return (objc_getAssociatedObject(owner, &delegateKey) as? AppUpdates)?.isRelaunching == true
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channels
    }

    static func install(in menu: NSMenu, owner: (any NSApplicationDelegate)?, info: [String: Any]) {
        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        if let owner, let channels = channels(for: info) {
            let updates = AppUpdates(channels: channels)
            updates.controller = SPUStandardUpdaterController(updaterDelegate: updates, userDriverDelegate: nil)
            // Chromium's delegate must stay installed and retain the updater across window lifetimes.
            objc_setAssociatedObject(owner, &delegateKey, updates, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            item.target = updates.controller
            item.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        } else {
            item.isEnabled = false
        }
        menu.insertItem(item, at: min(1, menu.items.count))
    }
}
