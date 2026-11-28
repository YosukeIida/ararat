import AppKit
import AraratUI
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdates: NSObject, SPUUpdaterDelegate, NSMenuItemValidation, SettingsUpdater {
    private static var delegateKey: UInt8 = 0
    private let channels: Set<String>
    private(set) var isRelaunching = false
    @ObservationIgnored private var sparkle: SPUUpdater?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var installNow: (() -> Void)?
    private var sparkleRevision = 0
    @ObservationIgnored private var candidate: String?
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var downloadedBytes: UInt64 = 0
    private(set) var state: SettingsUpdateState = .notChecked

    var canCheck: Bool {
        _ = sparkleRevision
        return sparkle?.canCheckForUpdates == true
    }

    var automaticallyChecks: Bool? {
        get {
            _ = sparkleRevision
            return sparkle?.automaticallyChecksForUpdates
        }
        set { if let newValue { sparkle?.automaticallyChecksForUpdates = newValue } }
    }

    @objc func checkForUpdates(_ sender: Any?) { checkNow() }

    func checkNow() {
        guard canCheck else { return }
        sparkle?.checkForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }

    func restartToUpdate() {
        guard let installNow else { return }
        self.installNow = nil
        state = .checking
        installNow()
    }

    fileprivate func readyToRestart(_ install: @escaping () -> Void) {
        installNow = install
        state = .ready(candidate ?? "")
    }

    fileprivate func setExpectedBytes(_ count: UInt64) { expectedBytes = count }

    fileprivate func receivedBytes(_ count: UInt64) {
        downloadedBytes += count
        let progress = expectedBytes > 0 ? min(1, Double(downloadedBytes) / Double(expectedBytes)) : nil
        if let candidate { state = .downloading(candidate, progress) }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if installNow == nil { state = .checking }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate update: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        // Why check separately: Sparkle's allowed channels always include untagged releases.
        guard channels.isEmpty || update.channel.map(channels.contains) == true else {
            throw NSError(domain: "AraratUpdates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This update is for Ararat Stable."
            ])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        candidate = item.displayVersionString
        state = .available(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        candidate = item.displayVersionString
        expectedBytes = 0
        downloadedBytes = 0
        state = .downloading(item.displayVersionString, nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        // Sparkle presents critical updates immediately after the automatic session ends.
        guard !item.isCriticalUpdate else { return false }
        candidate = item.displayVersionString
        readyToRestart(immediateInstallationBlock)
        // Sparkle invalidates the immediate-install action if its automatic driver ends the session.
        return true
    }

    static func channels(for info: [String: Any]) -> Set<String>? {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.scheme == "https" || (url.scheme == "http" && host == "localhost"),
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        return info["AraratUpdateChannel"] as? String == "preview" ? ["preview"] : []
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
        installNow = nil
        defer { candidate = nil }
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
                let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
                    .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
                if let reason, reason != .onLatestVersion, reason != .onNewerThanLatestVersion {
                    state = .noCompatibleUpdate(error.localizedRecoverySuggestion ?? error.localizedDescription)
                } else {
                    state = .upToDate(updater.lastUpdateCheckDate ?? Date())
                }
            } else if error.domain == SUSparkleErrorDomain &&
                        [SUError.installationCanceledError, .installationAuthorizeLaterError].contains(where: { Int($0.rawValue) == error.code }) {
                state = candidate.map(SettingsUpdateState.available) ?? .notChecked
            } else {
                state = .failed(error.localizedDescription)
            }
        } else {
            state = candidate.map(SettingsUpdateState.available) ?? .notChecked
        }
    }

    static func isRelaunching(owner: (any NSApplicationDelegate)?) -> Bool {
        attached(to: owner)?.isRelaunching == true
    }

    static func attached(to owner: (any NSApplicationDelegate)?) -> AppUpdates? {
        guard let owner else { return nil }
        return objc_getAssociatedObject(owner, &delegateKey) as? AppUpdates
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channels
    }

    static func install(in menu: NSMenu, owner: (any NSApplicationDelegate)?, info: [String: Any]) {
        let item = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        if let owner, let channels = channels(for: info) {
            let updates = AppUpdates(channels: channels)
            let driver = AboutUpdateDriver(hostBundle: .main, delegate: nil)
            driver.updates = updates
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: updates)
            do {
                try updater.start()
                updates.sparkle = updater
                updates.observations = [
                    updater.observe(\.canCheckForUpdates) { [weak updates] _, _ in
                        MainActor.assumeIsolated { updates?.sparkleRevision += 1 }
                    },
                    updater.observe(\.automaticallyChecksForUpdates) { [weak updates] _, _ in
                        MainActor.assumeIsolated { updates?.sparkleRevision += 1 }
                    },
                ]
            } catch {
                updates.state = .failed(error.localizedDescription)
            }
            // Chromium's delegate must stay installed and retain the updater across window lifetimes.
            objc_setAssociatedObject(owner, &delegateKey, updates, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            item.target = updates
            item.action = #selector(checkForUpdates(_:))
        } else {
            item.isEnabled = false
        }
        menu.insertItem(item, at: min(1, menu.items.count))
    }
}

@MainActor
private final class AboutUpdateDriver: SPUStandardUserDriver {
    weak var updates: AppUpdates?

    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        updates?.setExpectedBytes(expectedContentLength)
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        updates?.receivedBytes(length)
        super.showDownloadDidReceiveData(ofLength: length)
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.showReady(toInstallAndRelaunch: readyReply(reply))
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.showUpdateFound(with: appcastItem, state: state,
                              reply: state.stage == .installing ? readyReply(reply) : reply)
    }

    private func readyReply(_ reply: @escaping (SPUUserUpdateChoice) -> Void) -> (SPUUserUpdateChoice) -> Void {
        var pending: ((SPUUserUpdateChoice) -> Void)? = reply
        let respond: (SPUUserUpdateChoice) -> Void = { choice in
            let action = pending
            pending = nil
            action?(choice)
        }
        updates?.readyToRestart { respond(.install) }
        return respond
    }
}
