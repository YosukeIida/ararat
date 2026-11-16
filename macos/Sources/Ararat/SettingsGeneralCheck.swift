// The settings-general tick (P5b), appended to SettingsScreenCheck's extension.
import AppKit
import AraratKit
import AraratUI

/// The General pane's default-browser seams as the check injects them: the status LaunchServices
/// would answer and the setter Make Default calls. No check touches the host's handler, and the
/// status flips only when the app asks the system, so the row's two faces can be read in order.
final class GeneralCheckDefaultBrowser: DefaultBrowserStatus, DefaultBrowserSetter {
    private(set) var calls = 0
    private(set) var isDefault = false

    func requestDefaultBrowser() {
        calls += 1
        // macOS shows its own confirmation; the check's fake accepts at once, which is the state
        // the row reads when the app becomes active again.
        isDefault = true
    }

    func isDefaultBrowser() -> Bool { isDefault }
}

extension Runtime {
    /// Phases 2 to 11 of `settings-general`: the pane's rows and their order, Make Default through
    /// the same call the button runs (the fake counts it and the row turns into its status face when
    /// the app activates), When Ararat opens written and read back from the core after a reopen, and
    /// the folder and the ask-each-file switch read back from Chromium's own download prefs.
    func settingsGeneralTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                             note: @escaping (String) -> Void, trace: @escaping (String) -> Void,
                             step: @escaping (Int) -> Void, end: (String, Bool) -> Void,
                             finish: @escaping () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        // The check's own folder: the panel's answer without a panel. It lives beside the check's
        // database, so nothing is written into the person's Downloads folder.
        func fixtureFolder() -> URL? {
            guard let path = owner.quitPath else { return nil }
            let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("general-downloads")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func engineSettings() -> [String: Any] {
            owner.host?.downloadsCheckSettings() ?? [:]
        }
        func timedOut(_ limit: Int) -> Bool {
            browserCheckAttempts - check.panePhaseStart > limit
        }

        switch check.phase {
        case 2:
            let rows = [SettingsModel.defaultBrowserRowID, SettingsModel.startupRowID,
                        SettingsModel.downloadsFolderRowID, SettingsModel.downloadsAskRowID]
                .map { probe.marker(SettingsModel.rowMarker($0)) }
            let controls = [SettingsModel.makeDefaultButtonMarker, SettingsModel.startupMenuMarker,
                            SettingsModel.downloadsFolderMarker, SettingsModel.downloadsChooseButtonMarker,
                            SettingsModel.downloadsAskSwitchMarker]
                .map { probe.marker($0) }
            guard rows.allSatisfy({ $0 != nil }), controls.allSatisfy({ $0 != nil }) else {
                note("general rows \(rows.map { $0 != nil }) controls \(controls.map { $0 != nil })")
                return
            }
            // The pane's own values must be the core's, not the model's initial ones.
            guard probe.generalLoaded else { note("general record read pending"); return }
            if check.conditions["rows"] != true {
                let ordered = zip(rows, rows.dropFirst()).allSatisfy { first, second in
                    guard let first, let second else { return false }
                    return first.maxY <= second.minY + 1
                }
                // The fresh record: Restore, Chromium's Downloads folder, no prompt.
                check.report("rows", ordered
                             && probe.startup == .restoreWindows
                             && probe.downloads.directory.isEmpty
                             && !probe.downloads.askWhereToSave
                             && probe.downloadFolderName == "Downloads"
                             && !probe.defaultBrowserIsDefault
                             && (controls[0]?.width ?? 0) > 0)
            }
            check.panePhaseStart = browserCheckAttempts
            // The profile's own Downloads folder now, before the pane writes anything: the reset
            // phase compares against it, so a stale folder cannot pass as the default (F1).
            check.downloadsDefaultDirectory = engineSettings()["directory"] as? String
            trace("pressing Make Default through the fake setter")
            probe.makeDefaultBrowser()
            // The app reads the status again when it becomes active; the check posts the same
            // notification the window observes, so the refresh path is the shipping one.
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            step(3)
        case 3:
            guard let fake = generalDefaultBrowser else { note("no fake default-browser pair"); return }
            guard probe.defaultBrowserIsDefault, fake.calls == 1,
                  probe.marker(SettingsModel.defaultBrowserStatusMarker) != nil,
                  probe.marker(SettingsModel.makeDefaultButtonMarker) == nil else {
                if timedOut(100) { check.report("make_default_called", false); finish(); return }
                note("status \(probe.defaultBrowserIsDefault) calls \(fake.calls) button \(probe.marker(SettingsModel.makeDefaultButtonMarker) != nil)")
                return
            }
            check.report("make_default_called", true)
            check.details["default_browser"] = ["calls": fake.calls, "status": probe.defaultBrowserIsDefault]
            trace("writing Open a new window")
            check.panePhaseStart = browserCheckAttempts
            probe.setStartup(.newWindow)
            step(4)
        case 4:
            guard probe.startup == .newWindow else {
                if timedOut(100) { check.report("startup_write", false); finish(); return }
                note("startup after write: \(probe.startupLabel)"); return
            }
            check.report("startup_write", true)
            // M4: the controller and model survive the close, so put the built-in value back before
            // the reopen; startup_reopen can then only pass on a read that answered.
            probe.resetGeneralForRead()
            owner.settings?.window?.performClose(nil)
            step(5)
        case 5:
            guard owner.settings?.window?.isVisible != true else { note("settings window still visible"); return }
            owner.settings?.checkOpen(paneID: "general", shownSpaceID: snapshot.shownSpaceId)
            step(6)
        case 6:
            guard probe.isVisible, probe.pageID == "general", probe.generalLoaded else {
                if timedOut(120) { check.report("startup_reopen", false); finish(); return }
                note("reopened on \(probe.pageID) visible=\(probe.isVisible) loaded=\(probe.generalLoaded)"); return
            }
            guard probe.startup == .newWindow else {
                note("reopened startup: \(probe.startupLabel)"); return
            }
            check.report("startup_reopen", true)
            guard let folder = fixtureFolder() else { note("no fixture folder"); return }
            check.folderPath = folder.path
            trace("choosing \(folder.path) for downloads")
            check.panePhaseStart = browserCheckAttempts
            // The folder panel's own answer path: the same setter its completion calls.
            probe.setDownloadDirectory(folder)
            step(7)
        case 7:
            guard let path = check.folderPath, probe.downloads.directory == path,
                  probe.downloadFolderName == "general-downloads" else {
                if timedOut(100) { check.report("folder_choose_writes_pref", false); finish(); return }
                note("downloads record: \(probe.downloads.directory) name \(probe.downloadFolderName)"); return
            }
            let settings = engineSettings()
            let directory = settings["directory"] as? String ?? ""
            let prompt = settings["prompt"] as? Bool
            check.details["downloads_pref"] = ["directory": directory, "prompt": prompt as Any? ?? "nil"]
            guard directory == path, prompt == false else {
                if timedOut(120) { check.report("folder_choose_writes_pref", false); finish(); return }
                note("chromium download prefs: \(directory) prompt \(prompt.map(String.init) ?? "nil")")
                return
            }
            check.report("folder_choose_writes_pref", true)
            trace("turning Ask where to save each file on")
            check.panePhaseStart = browserCheckAttempts
            probe.setAskWhereToSave(true)
            step(8)
        case 8:
            guard probe.downloads.askWhereToSave else {
                if timedOut(100) { check.report("ask_where_writes_pref", false); finish(); return }
                note("ask switch: \(probe.downloads.askWhereToSave)"); return
            }
            let settings = engineSettings()
            guard settings["prompt"] as? Bool == true, settings["directory"] as? String == check.folderPath else {
                if timedOut(120) { check.report("ask_where_writes_pref", false); finish(); return }
                note("chromium download prefs after the switch: \(settings)")
                return
            }
            check.report("ask_where_writes_pref", true)
            check.details["downloads_pref_after"] = ["directory": check.folderPath ?? "",
                                                     "prompt": settings["prompt"] as? Bool == true]
            trace("resetting the downloads record to Chromium's default")
            check.panePhaseStart = browserCheckAttempts
            probe.resetDownloadDevice()
            step(9)
        case 9:
            guard probe.downloads == .board else {
                if timedOut(100) { check.report("folder_clear_restores_default", false); finish(); return }
                note("downloads record: \(probe.downloads.directory) \(probe.downloads.askWhereToSave)"); return
            }
            // F1: an empty record clears Chromium's pref, so the folder a moment ago set is gone and
            // the profile's own Downloads folder applies again (+ the prompt is off).
            let settings = engineSettings()
            let directory = settings["directory"] as? String ?? ""
            check.details["downloads_pref_reset"] = ["directory": directory,
                                                     "prompt": settings["prompt"] as Any? ?? "nil",
                                                     "default": check.downloadsDefaultDirectory ?? "nil"]
            guard !directory.isEmpty, directory != check.folderPath,
                  settings["prompt"] as? Bool == false else {
                if timedOut(120) { check.report("folder_clear_restores_default", false); finish(); return }
                note("chromium download prefs after the reset: \(settings)"); return
            }
            check.report("folder_clear_restores_default",
                         directory == check.downloadsDefaultDirectory)
            guard capture("general") else { end("capture", false); return }
            finish()
        default: break
        }
    }
}
