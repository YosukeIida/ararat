import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

// U27a's settings screen checks: `--ararat-screen=settings-<pane>` opens the settings window on
// that pane and reads it through marker views and the model (the VM's accessibility tree is empty
// in process, as `SidebarChecks.swift` and `SiteControlsCheck.swift` say). One launch per pane
// keeps a failure attributable: the panes name their own rows, and `settings-frame` and
// `settings-search` cover the frame and the search's keyboard model.
@MainActor
final class SettingsScreenCheck {
    /// One mode per `--ararat-screen=` argument. The app's check mode is `screen-` plus the raw
    /// value, the form every check family uses, and `screenMode`/`mode` are the only two ways in.
    enum Mode: String, CaseIterable {
        case frame = "settings-frame"
        case search = "settings-search"
        case general = "settings-general"
        case tabs = "settings-tabs"
        case shortcuts = "settings-shortcuts"
        case airTraffic = "settings-air-traffic"
        case appearance = "settings-appearance"
        case spaces = "settings-spaces"
        case littleWindow = "settings-little-window"
        case websites = "settings-websites"
        case privacy = "settings-privacy"
        case extensions = "settings-extensions"
        case toolbar = "settings-toolbar"

        /// The pane the window opens on. The frame and search checks both run on Tabs.
        var paneID: String {
            switch self {
            case .frame, .search, .tabs, .toolbar: "tabs"
            case .shortcuts, .airTraffic, .appearance, .spaces, .websites, .privacy, .general: String(rawValue.dropFirst("settings-".count))
            case .littleWindow: "little-window"
            case .extensions: "extensions"
            }
        }

        /// The `--ararat-screen=` argument, without the prefix.
        var screenArgument: String { rawValue }

        /// `screen-settings-tabs`: the check mode `main.swift` sets for the argument.
        var checkMode: String { "screen-" + rawValue }

        /// The mode an `--ararat-screen=` argument names (`settings-tabs` → `.tabs`).
        static func screenMode(_ argument: String) -> Mode? { Mode(rawValue: argument) }

        /// The mode a check mode names (`screen-settings-tabs` → `.tabs`), nil for another family.
        static func mode(_ checkMode: String) -> Mode? {
            checkMode.hasPrefix("screen-") ? Mode(rawValue: String(checkMode.dropFirst("screen-".count))) : nil
        }

        var ledger: [String] {
            switch self {
            case .frame: ["cards", "header_fade", "search_replaces_rail", "grouping", "no_results"]
            case .search: ["first_selected", "arrow_moves", "return_opens", "hit_look", "hit_scrolled", "highlight_stays"]
            case .tabs: ["rows"]
            case .airTraffic: ["rows"] + SettingsATCInput.conditions
            case .shortcuts: ["rows", "record_button_pressed", "recorder_opened", "key_recorded", "menu_updated", "sidebar_updated",
                              "keyboard_pressed", "keyboard_toggled", "recorder_restored"]
            case .appearance: ["rows", "theme_dark", "theme_light", "theme_page", "theme_reopen", "theme_system",
                               "new_tab_hidden", "new_tab_reopen", "tooltips_off", "look_to_space"]
            case .spaces: ["rows", "space_page", "scroll_card", "scroll_write_reopen", "scroll_wheel_natural", "scroll_wheel_reversed"]
            case .littleWindow: ["rows", "atc_link", "shortcut_recorder", "hot_key_registration", "hot_key_exclusive",
                                 "open_in_write_reopen", "open_in_bar", "close_after_keeps", "remember_off_frame"]
            case .websites: ["rows", "defaults_write", "defaults_reopen", "notification_denied", "camera_prompt",
                             "popover_exception", "pane_site_row", "all_site_settings", "site_page_rows",
                             "clear_site_data", "other_origin_kept", "reset_removes"]
            case .general: ["rows", "make_default_called", "startup_write", "startup_reopen",
                            "folder_choose_writes_pref", "ask_where_writes_pref",
                            "folder_clear_restores_default"]
            case .privacy: ["rows", "cookies_allowed", "cookies_blocked", "gpc_on", "gpc_off",
                            "retention_write", "retention_removes", "retention_keeps",
                            "sheet_rows", "sheet_range", "sheet_clears_history",
                            "sheet_keeps_older_history", "sheet_clears_cookie", "reopen_reads_record"]
            case .extensions: ["rows", "profile_switch", "site_access_write", "pin_action",
                               "disable_hides_action", "enable_brings_action", "review_prompt",
                               "review_enables", "remove_cancel_keeps", "reopen_state"]
            case .toolbar: ["navigation_size", "title_item", "items_order"]
            }
        }
    }

    /// Every check reads the frame first, then its own pane (or the search).
    static let common = ["window_open", "window_size", "rail_width", "pane_rows", "header", "title"]

    /// Every condition reads the visible window, so every check is a screen check and captures.
    static func conditionNames(_ mode: Mode) -> [String] { common + mode.ledger + ["capture"] }

    static func conditionResults(_ conditions: [String: Bool], mode: Mode) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(mode)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                names.filter { conditions[$0] != true })
    }

    var mode: Mode = .frame
    var phase = 0
    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    /// Readings a phase records for the diagnostics (frames, statuses), never asserted by name.
    var details: [String: Any] = [:]
    var airTrafficMenuObserver: NSObjectProtocol?
    var airTrafficMenuTraceObserver: NSObjectProtocol?
    var airTrafficRowMenuEndObserver: NSObjectProtocol?
    var airTrafficRowMenuTracking: Bool?

    deinit {
        if let airTrafficMenuObserver { NotificationCenter.default.removeObserver(airTrafficMenuObserver) }
        if let airTrafficMenuTraceObserver { NotificationCenter.default.removeObserver(airTrafficMenuTraceObserver) }
        if let airTrafficRowMenuEndObserver { NotificationCenter.default.removeObserver(airTrafficRowMenuEndObserver) }
    }
    // A screenshot spins the run loop, so a tick that re-enters while one is in flight would
    // read a half-updated phase.
    var capturing = false
    // The last wait a phase described, so a stall names its condition in the trace and in the
    // timeout diagnostics without a second VM round.
    var lastWait = ""
    // The row a Return opens, recorded before the action, and the page the detail kept while a
    // query had no results. `expectedResultPage` is that row's own registry page, so the assertion
    // follows the result the check navigated rather than a fixed pane name.
    var expectedRowID = ""
    var expectedResultPage = ""
    var hitResultPage = ""
    var previousMarker = ""
    var pageWithoutResults = ""
    var noResultsShown = false
    // The history length before a page push or a Return, so the check can tell it was pushed.
    var historyBefore = -1
    // The hit row the search opened, so the next tick can see the highlight stayed.
    var hitRowID = ""
    // U27c: the space a wheel run starts from, and the delta the natural wheel landed on, which
    // the reversed wheel must mirror.
    var wheelStart = ""
    var naturalDelta = 0
    var naturalWheelSentAt = -Double.infinity
    // U27d: the Today row the New Tab row's close-up is measured on, its frame before the switch,
    // and whether the header tooltip showed before the Tooltips switch was turned off.
    var appearanceTodayRow = ""
    var appearanceRowY: CGFloat = 0
    var appearanceTooltipShown = false
    // U27k: the fixture page's own tab, created once through the core (the engine's check-only
    // navigation gate does not name settings screens, and this is the path a person's New Tab
    // takes anyway), and the tick the phase started so a page that never follows fails the named
    // condition instead of stalling the check.
    var themePageDark: String?
    var themePageRequested = false
    var themePhaseStart = -1
    // U27i: the Little Window check's page, destination space and the window whose Open in is
    // driven (kept after it closes so its handoff record stays readable).
    var littlePageURL = "data:text/html,<title>Little Window settings page</title>"
    var littleSpaceID = ""
    var littleSpaceTitle = ""
    var littlePageLive = ""
    var littleOpening: LittleWindowController?
    // U27w: the Websites check's fixture origins, profile and the values its phases carry over.
    var websiteSecureBase = ""
    var websitePlainBase = ""
    var websiteSecureOrigin = ""
    var websitePlainOrigin = ""
    var websiteProfile = "Default"
    var websiteShownSpace = ""
    var websitePromptsBefore = 0
    var websiteClearFinished = false
    var websiteReadSecure: String?
    var websiteReadPlain: String?
    var websiteSiteRow: SettingsSiteRow?
    // U27x: the Extensions check's fixture args, the two profiles, the row ids it drives, the
    // dialog windows it has already seen (so a new one names the prompt), and its carried results.
    var extensionFixtureDefault = ""
    var extensionFixtureSecond = ""
    var extensionDefaultProfile = ""
    var extensionSecondProfile = ""
    var extensionDefaultID = ""
    var extensionSecondID = ""
    var extensionInstalling = false
    var extensionDefaultLoaded = false
    var extensionSecondLoaded = false
    /// The Views dialog class the seam answered for Review… and Remove… (X3, Major 2).
    var extensionReviewDialog = ""
    var extensionRemoveSheetTitle = ""
    // U27p: the Privacy check's fixture URLs, the visits it seeds, the cookie and GPC titles it
    // reads, and the phases' carried results.
    var privacyRecentVisitURL = "https://history.example/recent"
    var privacyOlderVisitURL = "https://history.example/older"
    var privacyTenDayVisitURL = "https://history.example/ten-days"
    var privacyTwoDayVisitURL = "https://history.example/two-days"
    /// R2-1: the seed time of the retention visits, written in phase 2 before the first expiry
    /// pass, and its offset from launch for the trace and the timeout details.
    var privacySeedTime: Date?
    var privacySeedUptime: TimeInterval?
    var privacyRetentionTimedOut = false
    var privacyPolling = false
    var privacyClearPolling = false
    var privacyLastTen = -1
    var privacyLastTwo = -1
    var privacyRecentGone = false
    var privacyOlderKept = false
    var privacySheetTitle = ""
    var privacyCookieTitle = ""
    var privacyGPCTitle = ""
    var privacyClearCookieTitle = ""
    /// The fixture folder the General check "chose" through the panel's answer path, so a later
    /// phase can compare the downloads pref against it.
    var folderPath: String?
    /// The profile's own Downloads folder, read before the pane writes anything; the reset phase
    /// proves an empty record returns to it (F1).
    var downloadsDefaultDirectory: String?
    // p4checks, the Shortcuts pane: the binding and the sidebar state before the recording, so
    // the recorded key's effect and the reset can be told apart.
    var shortcutKeyBefore: KeyCombination?
    var shortcutSidebarBefore = ""
    var shortcutNewKey = KeyCombination(key: "k", command: false, control: true, option: true, shift: false)
    var panePhaseStart = -1

    func report(_ name: String, _ ok: Bool) {
        conditions[name] = ok
        if let data = try? JSONSerialization.data(withJSONObject: ["check": mode.rawValue, "phase": name, "ok": ok], options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}

extension Runtime {
    func settingsCheckDiagnostics(mode: String) -> [String: Any] {
        guard let check = settingsCheck, let mode = SettingsScreenCheck.Mode.mode(mode) else { return ["phase": browserCheckPhase] }
        let result = SettingsScreenCheck.conditionResults(check.conditions, mode: mode)
        let probe = (root ?? self).settings?.checkProbe()
        var values: [String: Any] = [
            "check": mode.rawValue, "screen": mode.rawValue,
            "conditions": result.values, "failed_conditions": result.failed,
            "phase": check.phase, "attempts": browserCheckAttempts, "last_wait": check.lastWait,
            "images": check.images, "expected_row": check.expectedRowID,
            "settings_owner": (root ?? self).settingsOwner != nil,
            "details": check.details,
        ]
        if let probe {
            probe.layout()
            values["settings_visible"] = probe.isVisible
            values["settings_key"] = probe.isKey
            values["window_size"] = ["width": probe.windowFrame.width, "height": probe.windowFrame.height]
            values["rail_width"] = probe.railWidth as Any? ?? NSNull()
            values["rail_panes"] = probe.railPanes.map { ["id": $0.id, "title": $0.title] }
            values["rail_rows"] = probe.railRows.map { ["id": $0.id, "frame": rectFields($0.frame)] }
            values["title"] = probe.title
            values["subtitle"] = probe.subtitle
            values["pane"] = probe.paneID
            values["page"] = probe.pageID
            values["query"] = probe.query
            values["results"] = probe.resultTitles
            values["groups"] = probe.groupPaneIDs
            values["group_rows"] = probe.groupRowCounts
            values["selected_index"] = probe.selectedIndex
            values["selected_result"] = probe.selectedResultTitle as Any? ?? NSNull()
            values["selected_marker"] = probe.selectedResultMarker as Any? ?? NSNull()
            values["highlighted_row"] = probe.highlightedRowID as Any? ?? NSNull()
            values["scroll"] = probe.detailScrollOffset as Any? ?? NSNull()
            values["header_progress"] = probe.headerProgress
            values["history_index"] = probe.historyIndex
            values["space_scroll"] = probe.spaceScrollDirectionLabel
            values["new_tab_row_shown"] = probe.newTabRowShown
            values["tooltips_shown"] = probe.tooltipsShown
            values["theme"] = probe.themeLabel
            values["theme_app_appearance"] = probe.appAppearanceName as Any? ?? NSNull()
            values["theme_window_appearance"] = probe.windowAppearanceName
            values["shown_space"] = snapshot.shownSpaceId as Any? ?? NSNull()
            values["markers"] = probe.markers(prefix: "").map { ["id": $0.id, "frame": rectFields($0.frame)] }
        }
        if mode == .littleWindow, let probe {
            values["little_window"] = ["open_in": probe.littleWindowOpenInLabel,
                                       "close_after": probe.littleWindowCloseAfter,
                                       "remember": probe.littleWindowRememberFrame,
                                       "hot_key_caps": probe.littleWindowHotKeyCaps,
                                       "hot_key_status": probe.littleWindowHotKeyStatus.map { String(describing: $0) } ?? "none",
                                       "hot_key_message": probe.littleWindowHotKeyMessage ?? ""]
            values["unverified"] = [
                "A real system-wide key press (the check reads the registration result)",
                "Another app holding the key at launch (the taken answer is unit-tested)",
                "The hover and pressed looks (no cursor in the VM)",
            ]
        }
        if mode == .extensions, let probe {
            values["extension_profiles"] = probe.extensionProfiles
            values["extension_profile"] = probe.extensionProfile
            values["extensions"] = probe.extensions.map { row -> [String: Any] in
                ["id": row.id, "name": row.name, "enabled": row.enabled,
                 "needs_review": row.needsReview, "site_access": row.siteAccess.rawValue,
                 "pinned": row.pinned, "summary": row.summary]
            }
            values["extension_in_field_actions"] = (root ?? self).sidebar?.checkInFieldActionIDs ?? []
            values["extension_default_profile"] = check.extensionDefaultProfile
            values["extension_second_profile"] = check.extensionSecondProfile
            values["extension_fixtures"] = ["default": check.extensionFixtureDefault,
                                            "second": check.extensionFixtureSecond]
            values["extension_loaded"] = ["default": check.extensionDefaultLoaded,
                                          "second": check.extensionSecondLoaded]
            values["extension_loading"] = probe.extensionsLoading
            values["extension_review_dialog"] = check.extensionReviewDialog
            values["extension_remove_sheet"] = check.extensionRemoveSheetTitle
        }
        if mode == .general, let probe {
            let owner = root ?? self
            values["general"] = ["startup": probe.startupLabel,
                                 "downloads_folder": probe.downloads.directory,
                                 "downloads_name": probe.downloadFolderName,
                                 "ask": probe.downloads.askWhereToSave,
                                 "default_browser": probe.defaultBrowserIsDefault,
                                 "loaded": probe.generalLoaded,
                                 "make_default_calls": owner.generalDefaultBrowser?.calls as Any? ?? NSNull()]
            values["general_pref"] = owner.host?.downloadsCheckSettings() ?? [:]
        }
        if mode == .privacy, let probe {
            values["privacy"] = ["cookies": probe.privacy.thirdPartyCookies.label,
                                 "gpc": probe.privacy.globalPrivacyControl,
                                 "retention": probe.privacy.historyRetention.label,
                                 "profile": probe.privacyProfile,
                                 "loaded": probe.privacyLoaded,
                                 "sheet_shown": probe.clearSheetShown,
                                 "sheet_visible": probe.clearSheetVisible,
                                 "range": probe.clearRange.title,
                                 "types": probe.clearTypes.rawValue,
                                 "clearing": probe.clearing]
            values["privacy_titles"] = ["cookie": check.privacyCookieTitle,
                                        "gpc": check.privacyGPCTitle,
                                        "clear": check.privacyClearCookieTitle]
            values["privacy_visits"] = ["seed_offset": Int(check.privacySeedUptime ?? 0),
                                        "ten": check.privacyLastTen,
                                        "two": check.privacyLastTwo,
                                        "recent_gone": check.privacyRecentGone,
                                        "older_kept": check.privacyOlderKept]
        }
        return values
    }

    func settingsCheckTick(_ screenName: String) {
        guard let mode = SettingsScreenCheck.Mode.mode(screenName) else { return }
        if settingsCheck == nil { settingsCheck = SettingsScreenCheck() }
        guard let check = settingsCheck else { return }
        check.mode = mode
        guard !check.capturing else { return }
        func trace(_ name: String) {
            FileHandle.standardError.write(Data("ararat-trace: \(mode.rawValue) phase \(check.phase) \(name)\n".utf8))
        }
        func step(_ next: Int) { check.phase = next; browserCheckPhase = next }
        func end(_ name: String, _ ok: Bool) {
            check.report(name, ok)
            if !ok { finishBrowserCheck(ok: false, values: settingsCheckDiagnostics(mode: screenName)) }
            else { step(check.phase + 1) }
        }
        func finish() {
            let failed = SettingsScreenCheck.conditionNames(mode).filter { check.conditions[$0] != true }
            finishBrowserCheck(ok: failed.isEmpty,
                               values: ["conditions": check.conditions, "failed_conditions": failed, "images": check.images, "details": check.details])
        }
        func note(_ text: String) {
            if check.lastWait != text || browserCheckAttempts % 30 == 0 {
                check.lastWait = text
                FileHandle.standardError.write(Data("ararat-trace: \(mode.rawValue) wait phase \(check.phase): \(text)\n".utf8))
            }
        }
        func capture(_ name: String) -> Bool {
            trace("capture \(name)")
            check.capturing = true
            let path = (root ?? self).settings?.window.flatMap { window in
                promptScreenScreenshot(window, name: "\(mode.rawValue)-\(name)", withoutShadow: true)
            }
            check.capturing = false
            if let path { check.images[name] = path }
            check.conditions["capture"] = (check.conditions["capture"] ?? true) && path != nil
            return path != nil
        }
        func near(_ value: CGFloat, _ target: CGFloat) -> Bool { abs(value - target) <= 1 }

        let owner = root ?? self
        guard snapshot.spaces.count >= 2, workspace != nil, keyBindings != nil, airTraffic != nil else {
            note("workspace not ready spaces=\(snapshot.spaces.count)")
            return
        }
        if owner.settings == nil { owner.openSettings() }
        guard let settings = owner.settings, let probe = settings.checkProbe() else {
            note("settings window missing")
            return
        }
        probe.layout()

        // MARK: opening and the frame every mode shares

        if check.phase == 0 {
            // The window opens on the shown space's page; the check needs the pane's own page,
            // so it drives the same open path a settings command does and then names the pane.
            guard probe.isVisible, probe.pageID == mode.paneID else {
                settings.checkOpen(paneID: mode.paneID, shownSpaceID: snapshot.shownSpaceId)
                note("opening on \(mode.paneID) (page=\(probe.pageID) visible=\(probe.isVisible))")
                return
            }
            check.report("window_open", true)
            step(1)
            return
        }
        if check.phase == 1 {
            // SwiftUI commits the first layout after the window orders in, so the frame waits
            // for the rail and header markers instead of reading an empty tree once.
            guard probe.marker(SettingsModel.headerTitleMarker) != nil, probe.railRows.count == probe.railPanes.count else {
                note("layout: rail=\(probe.railRows.count)/\(probe.railPanes.count) header=\(probe.marker(SettingsModel.headerTitleMarker) != nil)")
                return
            }
            let size = probe.windowFrame.size
            check.report("window_size", near(size.width, 760) && near(size.height, 540))
            check.report("rail_width", probe.railWidth.map { near($0, 180) } ?? false)
            let rows = probe.railRows
            let expected = probe.railPanes.map { SettingsModel.railMarker(id: $0.id) }
            let pitches = zip(rows, rows.dropFirst()).map { $1.frame.minY - $0.frame.minY }
            check.report("pane_rows", rows.map(\.id) == expected
                && rows.allSatisfy { abs($0.frame.height - 26) <= 2 }
                && pitches.allSatisfy { abs($0 - 28) <= 2 })
            let icon = probe.marker(SettingsModel.headerIconMarker)
            check.report("header", icon.map { abs($0.height - 56) <= 2 } == true
                && probe.marker(SettingsModel.headerTitleMarker) != nil
                && probe.marker(SettingsModel.headerSubtitleMarker) != nil)
            check.report("title", probe.title == probe.railPanes.first { $0.id == mode.paneID }?.title
                && !probe.subtitle.isEmpty)
            if check.conditions.values.contains(false) {
                note("frame rows=\(rows.map(\.id)) widths=\(probe.railWidth.map { String(format: "%.1f", $0) } ?? "-") size=\(size) title=\(probe.title) pitches=\(pitches)")
            }
            step(2)
            return
        }

        switch mode {
        case .airTraffic:
            settingsAirTrafficTick(probe, check: check, note: note, step: step, end: end, finish: finish, capture: capture)
        case .frame:
            settingsFrameTick(probe, check: check, note: note, trace: trace, step: step, end: end, finish: finish, capture: capture, near: near)
        case .search:
            settingsSearchTick(probe, check: check, note: note, trace: trace, step: step, end: end, finish: finish, capture: capture, near: near)
        case .tabs, .shortcuts, .spaces, .appearance, .littleWindow, .websites, .general, .privacy, .extensions, .toolbar:
            if mode == .spaces, check.phase >= 4 {
                settingsSpacesScrollTick(probe, check: check, note: note, trace: trace, step: step,
                                         end: end, finish: finish, capture: capture)
                return
            }
            if mode == .extensions {
                settingsExtensionsTick(probe, check: check, note: note, trace: trace, step: step,
                                       end: end, finish: finish, capture: capture)
                return
            }
            if mode == .appearance {
                settingsAppearanceTick(probe, check: check, note: note, trace: trace, step: step,
                                       end: end, finish: finish, capture: capture)
                return
            }
            if mode == .littleWindow {
                settingsLittleWindowTick(probe, check: check, note: note, trace: trace, step: step,
                                         end: end, finish: finish, capture: capture)
                return
            }
            if mode == .websites {
                settingsWebsitesTick(probe, check: check, note: note, trace: trace, step: step,
                                     end: end, finish: finish, capture: capture)
                return
            }
            if mode == .privacy {
                settingsPrivacyTick(probe, check: check, note: note, trace: trace, step: step,
                                    end: end, finish: finish, capture: capture)
                return
            }
            if mode == .general {
                settingsGeneralTick(probe, check: check, note: note, trace: trace, step: step,
                                    end: end, finish: finish, capture: capture)
                return
            }
            settingsPaneTick(mode, probe, check: check, note: note, trace: trace, step: step, end: end, finish: finish, capture: capture, pushSpace: settings.checkPushSpace)
        }
    }

    // MARK: settings-frame

    private func settingsFrameTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck, note: (String) -> Void, trace: (String) -> Void,
                                   step: (Int) -> Void, end: (String, Bool) -> Void, finish: () -> Void, capture: (String) -> Bool,
                                   near: (CGFloat, CGFloat) -> Bool) {
        switch check.phase {
        case 2:
            let width = probe.marker(SettingsModel.rowMarker("width"))
            let archive = probe.marker(SettingsModel.rowMarker("archive-after"))
            guard let width, let archive else { note("card markers width=\(width != nil) archive=\(archive != nil)"); return }
            let gap = archive.minY - width.maxY
            let cards = abs(width.width - archive.width) <= 1 && near(gap, SettingsMetrics.cardGap)
                && width.height >= 54 && archive.height >= 54
            note("cards width=\(width) archive=\(archive) gap=\(gap)")
            probe.scrollDetail(to: 50)
            end("cards", cards)
        case 3:
            guard probe.headerProgress > 0.45, probe.headerProgress < 0.55 else {
                note("header progress at 50 pt: \(probe.headerProgress)"); return
            }
            trace("header half at \(probe.headerProgress)")
            probe.scrollDetail(to: 200)
            step(4)
        case 4:
            guard probe.headerProgress == 1 else { note("header progress at 200 pt: \(probe.headerProgress)"); return }
            probe.scrollDetail(to: 0)
            step(5)
        case 5:
            guard probe.headerProgress < 0.05 else { note("header progress back at 0: \(probe.headerProgress)"); return }
            check.report("header_fade", true)
            probe.setQuery("space")
            step(6)
        case 6:
            let headings = probe.markers(prefix: "group-")
            let results = probe.markers(prefix: "result-").filter { $0.id != SettingsModel.selectedResultMarker }
            guard !headings.isEmpty, results.count == probe.resultTitles.count else {
                note("groups=\(probe.groupPaneIDs) results=\(results.count)/\(probe.resultTitles.count)"); return
            }
            let expectedHeadings = probe.groupPaneIDs.map { SettingsModel.groupMarker(id: $0) }
            let counts = probe.groupRowCounts
            var grouped = headings.map(\.id) == expectedHeadings && counts.reduce(0, +) == results.count
            var index = 0
            for (position, heading) in headings.enumerated() {
                guard counts.indices.contains(position) else { grouped = false; break }
                let count = counts[position]
                let band = results[index..<min(results.count, index + count)]
                // The group's rows sit under its heading and above the next heading.
                let floor = headings.indices.contains(position + 1) ? headings[position + 1].frame.minY : CGFloat.greatestFiniteMagnitude
                grouped = grouped && band.count == count
                    && band.allSatisfy { $0.frame.minY >= heading.frame.maxY - 1 && $0.frame.maxY <= floor + 1 }
                index += count
            }
            trace("groups=\(probe.groupPaneIDs) results=\(results.count)")
            check.report("search_replaces_rail", probe.railRows.isEmpty)
            check.report("grouping", grouped)
            probe.setQuery("zzzz")
            step(7)
        case 7:
            guard probe.noResults, probe.marker(SettingsModel.noResultsMarker) != nil else {
                note("results for zzzz: \(probe.resultTitles.count), marker=\(probe.marker(SettingsModel.noResultsMarker) != nil)"); return
            }
            check.noResultsShown = true
            check.pageWithoutResults = probe.pageID
            probe.setQuery("")
            step(8)
        case 8:
            guard probe.query.isEmpty, probe.marker(SettingsModel.noResultsMarker) == nil,
                  !probe.railRows.isEmpty else {
                note("after clearing: query=\(probe.query.debugDescription) noResults=\(probe.noResults) rail=\(probe.railRows.count)"); return
            }
            trace("after clearing: query=\(probe.query.debugDescription) noResults=\(probe.noResults) rail=\(probe.railRows.count)")
            check.report("no_results", check.noResultsShown && probe.pageID == check.pageWithoutResults
                && probe.marker(SettingsModel.noResultsMarker) == nil)
            guard capture("frame") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-search

    /// The selected result is drawn (M1): the selection grey at the row's left inside edge and
    /// another result's own grey there must differ. Marker frames alone cannot tell a drawn fill.
    private func selectionIsDrawn(_ probe: SettingsCheckProbe) -> Bool {
        guard let marker = probe.selectedResultMarker, let row = probe.marker(marker) else { return false }
        let other = probe.markers(prefix: "result-").first {
            $0.id != SettingsModel.selectedResultMarker && $0.id != marker
        }.map(\.frame)
        guard let other else { return false }
        // 6 pt in from each row's left edge, level with its middle: inside the fill, left of the title.
        let greys = probe.greys(at: [NSPoint(x: row.minX + 6, y: row.midY),
                                     NSPoint(x: other.minX + 6, y: other.midY)])
        guard let selected = greys[0], let plain = greys[1] else { return false }
        return abs(selected - plain) > 10
    }

    private func settingsSearchTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck, note: (String) -> Void, trace: (String) -> Void,
                                    step: (Int) -> Void, end: (String, Bool) -> Void, finish: () -> Void, capture: (String) -> Bool,
                                    near: (CGFloat, CGFloat) -> Bool) {
        switch check.phase {
        case 2:
            probe.setQuery("space")
            step(3)
        case 3:
            guard probe.resultTitles.count >= 3, let marker = probe.selectedResultMarker, let selected = probe.marker(marker) else {
                note("results: \(probe.resultTitles.count)"); return
            }
            trace("first=\(probe.selectedResultTitle ?? "-")")
            check.report("first_selected", probe.selectedIndex == 0 && selected.height >= 24
                && probe.selectedResultTitle == probe.resultTitles.first && selectionIsDrawn(probe))
            _ = probe.searchKey(.down)
            _ = probe.searchKey(.down)
            step(4)
        case 4:
            guard probe.selectedIndex == 2, let marker = probe.selectedResultMarker,
                  let row = probe.marker(marker), let selected = probe.marker(SettingsModel.selectedResultMarker),
                  near(row.minY, selected.minY), near(row.height, selected.height) else {
                note("index after two downs: \(probe.selectedIndex)"); return
            }
            check.previousMarker = marker
            _ = probe.searchKey(.up)
            step(5)
        case 5:
            guard probe.selectedIndex == 1, probe.selectedResultMarker != check.previousMarker,
                  let marker = probe.selectedResultMarker, let row = probe.marker(marker),
                  let selected = probe.marker(SettingsModel.selectedResultMarker),
                  near(row.minY, selected.minY) else {
                note("index after one up: \(probe.selectedIndex) marker=\(probe.selectedResultMarker ?? "-")")
                return
            }
            let drawn = selectionIsDrawn(probe)
            if !drawn { note("the moved selection is not drawn") }
            check.report("arrow_moves", drawn)
            check.expectedRowID = probe.selectedResultID ?? ""
            check.expectedResultPage = probe.selectedResultPageID ?? ""
            check.historyBefore = probe.historyIndex
            trace("return on \(check.expectedRowID) opening \(check.expectedResultPage)")
            _ = probe.searchKey(.return)
            step(6)
        case 6:
            guard !check.expectedRowID.isEmpty, !check.expectedResultPage.isEmpty,
                  probe.highlightedRowID == check.expectedRowID,
                  probe.marker(SettingsModel.rowMarker(check.expectedRowID)) != nil else {
                note("highlight \(probe.highlightedRowID ?? "-") want \(check.expectedRowID)"); return
            }
            check.report("return_opens", probe.historyIndex > check.historyBefore
                && probe.pageID == check.expectedResultPage)
            probe.setQuery("Move to Space 9")
            step(7)
        case 7:
            guard probe.resultTitles.count == 1, probe.selectedIndex == 0 else {
                note("results for Move to Space 9: \(probe.resultTitles)"); return
            }
            check.hitResultPage = probe.selectedResultPageID ?? ""
            guard !check.hitResultPage.isEmpty else { note("the hit result has no page"); return }
            _ = probe.searchKey(.return)
            step(8)
        case 8:
            guard let id = probe.highlightedRowID, let row = probe.marker(SettingsModel.rowMarker(id)),
                  let offset = probe.detailScrollOffset else {
                note("hit row \(probe.highlightedRowID ?? "-") scroll=\(String(describing: probe.detailScrollOffset))"); return
            }
            let greys = probe.greys(at: [NSPoint(x: row.minX + 1.5, y: row.midY), NSPoint(x: row.minX + 6, y: row.midY)])
            trace("hit \(id) row=\(row) offset=\(offset) greys=\(greys)")
            // Both reads must land: one nil and one dark pixel must not read as an inset.
            let cards = greys[0]
            let fills = greys[1]
            check.report("hit_scrolled", offset > 300)
            // Outside the 3 pt fill but inside the card, then inside the fill: the two greys
            // differ, which is the inset render D7 asks for rather than a whole-card fill.
            check.report("hit_look", row.height >= SettingsMetrics.hitRowHeight && cards != nil && fills != nil
                && abs((cards ?? 0) - (fills ?? 0)) > 10)
            check.hitRowID = id
            guard capture("search") else { end("capture", false); return }
            step(9)
        case 9:
            // With the query cleared the rail is the pane list again; the detail keeps the pane
            // and the row keeps its fill ("The highlight stays", E-Search).
            probe.setQuery("")
            guard let row = probe.marker(SettingsModel.rowMarker(check.hitRowID)), check.hitRowID == probe.highlightedRowID,
                  !check.hitResultPage.isEmpty, probe.pageID == check.hitResultPage else {
                note("after clearing: highlight=\(probe.highlightedRowID ?? "-") page=\(probe.pageID)"); return
            }
            let greys = probe.greys(at: [NSPoint(x: row.minX + 1.5, y: row.midY), NSPoint(x: row.minX + 6, y: row.midY)])
            check.report("highlight_stays", greys[0] != nil && greys[1] != nil
                && abs((greys[0] ?? 0) - (greys[1] ?? 0)) > 10)
            guard capture("search-cleared") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-tabs, settings-shortcuts, settings-air-traffic, settings-spaces

    private func settingsPaneTick(_ mode: SettingsScreenCheck.Mode, _ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                  note: (String) -> Void, trace: (String) -> Void, step: (Int) -> Void, end: (String, Bool) -> Void,
                                  finish: () -> Void, capture: (String) -> Bool, pushSpace: (Int) -> Bool) {
        switch check.phase {
        case 2:
            switch mode {
            case .shortcuts:
                let rows = probe.markers(prefix: "row-shortcut-")
                note("shortcut rows: \(rows.count)")
                guard rows.count >= 20 else { return }
                if check.conditions["rows"] != true {
                    check.report("rows", rows.allSatisfy { $0.frame.height >= 54 })
                }
                // p4checks: record a key in Settings, then press it in the browser window. The
                // record button is pressed through the UI: the window's AX tree first, else a
                // real click on the row's record face; the direct model call is the last resort.
                check.shortcutKeyBefore = probe.shortcutKey("toggle_sidebar")
                check.shortcutSidebarBefore = (root ?? self).container?.sidebarState ?? ""
                check.panePhaseStart = browserCheckAttempts
                let press = probe.pressShortcutRecordButton("toggle_sidebar")
                check.details["shortcut_press"] = ["pressed": press.pressed, "way": press.way]
                if !press.tree.isEmpty { check.details["shortcut_ax_tree"] = press.tree }
                if let click = press.tree.last, click.hasPrefix("click ") { trace(click) }
                if press.pressed {
                    trace("record button UI attempt through \(press.way) for toggle_sidebar (before \(check.shortcutKeyBefore.map { "\($0.key)" } ?? "nil"))")
                } else {
                    check.report("record_button_pressed", false)
                    check.details["shortcut_press_fallback"] = true
                    check.details["shortcut_press_fallback_reason"] = "no_ui_path"
                    trace("neither the AX tree nor a click reached the record button; calling the model")
                    probe.beginShortcutRecording("toggle_sidebar")
                }
                step(20)
                return
            case .spaces:
                let markers = probe.spaceIDs.map { SettingsModel.rowMarker("space-\($0)") }
                let found = markers.map { probe.marker($0) }
                let rows = zip(markers, found).filter { $0.1 != nil }.map { (id: $0.0, frame: $0.1!) }
                guard probe.spaceIDs.count >= 2, rows.count == markers.count else {
                    note("space rows: \(markers.filter { probe.marker($0) == nil })"); return
                }
                // U27c: the direction card sits under the spaces list in a card of its own, with
                // the segmented control on the row (E-Spaces).
                let card = probe.marker(SettingsModel.rowMarker(SettingsModel.spaceScrollDirectionCardId))
                let control = probe.marker(SettingsModel.spaceScrollControlMarker)
                guard let card, let control, let last = rows.last else {
                    note("scroll direction card=\(card != nil) control=\(control != nil)"); return
                }
                check.report("scroll_card", card.minY >= last.frame.maxY - 1 && control.width > 0
                    && control.height >= 16)
                check.report("rows", rows.count == probe.spaceIDs.count
                    && zip(rows, rows.dropFirst()).allSatisfy { $0.frame.minY < $1.frame.minY })
                // The page push is what the space page condition is about, so its history length
                // is read before the push.
                check.historyBefore = probe.historyIndex
                guard pushSpace(0) else { note("no space to push"); return }
                step(3)
                return
            case .tabs, .airTraffic:
                let markers: [String]
                switch mode {
                case .tabs: markers = ["width", "archive-after"].map(SettingsModel.rowMarker)
                default: markers = [SettingsModel.airTrafficCardId, "atc-test"].map(SettingsModel.rowMarker)
                }
                guard markers.allSatisfy({ probe.marker($0) != nil }) else {
                    note("rows missing: \(markers.filter { probe.marker($0) == nil })"); return
                }
                check.report("rows", true)
            case .toolbar:
                // p4checks: the pair's own 76 × 36 and the title in its own item; exactly one
                // capsule is drawn (the system's glass on macOS 26, ours before it). The images
                // are the measurement of the capsule: one at the top and one scrolled, where the
                // toolbar carries the title.
                let items = probe.toolbarItems
                guard let navigation = items["navigation"], let title = items["title"] else {
                    note("toolbar items: \(items.keys.sorted())"); return
                }
                check.report("navigation_size", abs(navigation.width - 76) <= 1 && abs(navigation.height - 36) <= 1)
                check.report("title_item", title.width > 0 && title.height > 0)
                check.report("items_order", navigation.minX <= title.minX)
                check.details["toolbar"] = ["navigation": rectFields(navigation), "title": rectFields(title),
                                            "own_capsule": probe.toolbarOwnCapsule,
                                            "capsule_owner": probe.toolbarOwnCapsule ? "own" : "system"]
                guard capture("toolbar-top") else { end("capture", false); return }
                check.panePhaseStart = browserCheckAttempts
                probe.scrollDetail(to: 200)
                step(20)
                return
            // The frame and search modes have their own phase machines, and the appearance pane
            // has its own below; leaving them here keeps the pane switch total.
            case .frame, .search, .appearance, .littleWindow, .websites, .general, .privacy, .extensions:
                return
            }
            guard capture(mode.rawValue) else { end("capture", false); return }
            finish()
        case 3:
            guard let id = probe.spaceIDs.first, probe.pageID == "space-\(id)" else {
                note("page \(probe.pageID) want space-\(probe.spaceIDs.first ?? "-")"); return
            }
            let pageRows = ["name", "icon", "look", "profile", "delete"].map { probe.marker(SettingsModel.rowMarker($0)) }
            guard pageRows.allSatisfy({ $0 != nil }) else {
                note("space page rows: \(pageRows.map { $0 != nil })"); return
            }
            trace("space page \(probe.pageID) back=\(probe.canGoBack)")
            check.report("space_page", probe.historyIndex > check.historyBefore && probe.canGoBack)
            guard capture("space-page") else { end("capture", false); return }
            // U27c keeps going on the Spaces pane; the other panes are done here.
            if mode == .spaces { probe.openSpacesPane(); step(4); return }
            finish()
        // MARK: p4checks, the Shortcuts pane's recorder and the key it records
        case 20:
            if mode == .toolbar {
                // The second toolbar image: the header has scrolled away and the toolbar carries
                // the title, which is where design judges the capsule.
                guard probe.headerProgress > 0.95 else {
                    if browserCheckAttempts - check.panePhaseStart > 120 {
                        check.report("capture", false); finish()
                        return
                    }
                    note("the detail is not scrolled: \(probe.headerProgress)"); return
                }
                guard capture("toolbar-scrolled") else { end("capture", false); return }
                probe.scrollDetail(to: 0)
                finish()
                return
            }
            guard mode == .shortcuts else { finish(); return }
            if check.details["shortcut_press_fallback"] == nil,
               check.conditions["record_button_pressed"] == nil,
               probe.shortcutRecordingCommand == "toggle_sidebar" {
                check.report("record_button_pressed", true)
            }
            let ready = probe.shortcutRecordingCommand == "toggle_sidebar"
                && probe.shortcutRecorderPresent && probe.shortcutRecorderIsFirstResponder
            guard ready else {
                // shortcut: the UI press may start no recording; keep downstream checks running until the VM press path is fixed.
                if probe.shortcutRecordingCommand == nil,
                   browserCheckAttempts - check.panePhaseStart > 20,
                   check.details["shortcut_press_fallback"] == nil {
                    check.details["shortcut_press_fallback"] = true
                    check.details["shortcut_press_fallback_reason"] = "no_recording_after_press"
                    check.report("record_button_pressed", false)
                    FileHandle.standardError.write(Data("ararat-trace: shortcuts the UI press did not start the recording; calling the model\n".utf8))
                    probe.beginShortcutRecording("toggle_sidebar")
                }
                if browserCheckAttempts - check.panePhaseStart > 120 {
                    check.report("recorder_opened", false); finish()
                    return
                }
                note("the recorder is not ready: recording=\(probe.shortcutRecordingCommand ?? "nil") present=\(probe.shortcutRecorderPresent) first=\(probe.shortcutRecorderIsFirstResponder)")
                return
            }
            check.report("recorder_opened", true)
            guard capture("shortcuts-recorder") else { end("capture", false); return }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                               context: nil, characters: "k", charactersIgnoringModifiers: "k",
                                               isARepeat: false, keyCode: 40) else {
                check.report("key_recorded", false); finish(); return
            }
            check.panePhaseStart = browserCheckAttempts
            probe.recordShortcutKey(event)
            step(21)
        case 21:
            guard mode == .shortcuts else { finish(); return }
            let key = probe.shortcutKey("toggle_sidebar")
            guard key == check.shortcutNewKey, probe.shortcutRecordingCommand == nil else {
                if browserCheckAttempts - check.panePhaseStart > 120 {
                    check.report("key_recorded", false); finish()
                    return
                }
                note("recorded key \(key.map { "\($0.key) c=\($0.command) ctl=\($0.control) opt=\($0.option)" } ?? "nil")"); return
            }
            check.report("key_recorded", true)
            let menu = probe.menuKeyEquivalent("toggle_sidebar")
            check.report("menu_updated", menu?.key == "k" && menu?.modifiers.contains(.control) == true
                         && menu?.modifiers.contains(.option) == true && menu?.modifiers.contains(.command) == false)
            let binding = (root ?? self).sidebar?.keyBindings.first { $0.command == "toggle_sidebar" }
            check.report("sidebar_updated", binding?.key == check.shortcutNewKey)
            check.details["shortcut"] = ["key": "k", "control": true, "option": true,
                                         "menu_key": menu?.key ?? "",
                                         "menu_modifiers": menu?.modifiers.rawValue ?? 0,
                                         "sidebar_key": binding?.key.map { "\($0.key)" } ?? "nil"]
            // Press it in the browser window: the window's own key-equivalent path to the menu.
            guard let host = host, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: host.window().windowNumber, context: nil,
                                                                characters: "k", charactersIgnoringModifiers: "k",
                                                                isARepeat: false, keyCode: 40) else {
                check.report("keyboard_pressed", false); finish(); return
            }
            host.window().makeKeyAndOrderFront(nil)
            trace("press ⌃⌥K in the browser window")
            check.shortcutSidebarBefore = (root ?? self).container?.sidebarState ?? ""
            check.panePhaseStart = browserCheckAttempts
            NSApp.sendEvent(event)
            step(22)
        case 22:
            guard mode == .shortcuts else { finish(); return }
            guard let container = (root ?? self).container,
                  container.sidebarState != check.shortcutSidebarBefore else {
                if browserCheckAttempts - check.panePhaseStart > 120 {
                    check.report("keyboard_pressed", false); finish()
                    return
                }
                note("the recorded key did not toggle the sidebar"); return
            }
            check.report("keyboard_pressed", true)
            // The same key again puts the sidebar back.
            guard let host = host, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: host.window().windowNumber, context: nil,
                                                                characters: "k", charactersIgnoringModifiers: "k",
                                                                isARepeat: false, keyCode: 40) else {
                check.report("keyboard_toggled", false); finish(); return
            }
            check.panePhaseStart = browserCheckAttempts
            NSApp.sendEvent(event)
            step(23)
        case 23:
            guard mode == .shortcuts else { finish(); return }
            guard let container = (root ?? self).container,
                  container.sidebarState == check.shortcutSidebarBefore else {
                if browserCheckAttempts - check.panePhaseStart > 120 {
                    check.report("keyboard_toggled", false); finish()
                    return
                }
                note("the recorded key did not toggle the sidebar back"); return
            }
            check.report("keyboard_toggled", true)
            // Leave the pane as it was found: reset the row to its default binding.
            probe.resetShortcut("toggle_sidebar")
            check.panePhaseStart = browserCheckAttempts
            step(24)
        case 24:
            guard mode == .shortcuts else { finish(); return }
            guard probe.shortcutKey("toggle_sidebar") == check.shortcutKeyBefore else {
                if browserCheckAttempts - check.panePhaseStart > 120 {
                    check.report("recorder_restored", false); finish()
                    return
                }
                note("the binding has not been reset"); return
            }
            check.report("recorder_restored", true)
            guard capture("shortcuts") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-appearance, U27d's switches and U27k's Theme

    /// The page whose title is the resolved `prefers-color-scheme`, so the check proves Chromium
    /// follows the app's appearance instead of assuming it. The interval keeps the title current
    /// even if the media query's change event never fires.
    static let themeFixturePage = "data:text/html,<title>light</title><script>setInterval(function(){document.title=matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'},100)</script>"

    /// "dark" or "light" for an appearance, the same two words the fixture page writes.
    private static func appearanceWord(_ appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    /// The checked window's active tab's title, which the theme fixture page drives.
    private func settingsThemePageTitle() -> String? {
        guard let host, let active = host.activeItemId() else { return nil }
        return (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == active }?.title
    }

    /// Phases 2 to 12 of `settings-appearance`: the pane's four rows; U27k's Theme in Dark, Light,
    /// a reopen that reads Light back from the core, and System (with the fixture page's
    /// `prefers-color-scheme` following each); then U27d's New Tab row switch hiding the row (the
    /// Today rows close up by its 41 pt) and the reopened window reading it back, the Tooltips
    /// switch off leaving a hovered header control silent, and the Look row pushing the shown
    /// space's page.
    private func settingsAppearanceTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                        note: (String) -> Void, trace: (String) -> Void,
                                        step: (Int) -> Void, end: (String, Bool) -> Void,
                                        finish: () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        let mainAppearance = host.map { Self.appearanceWord($0.window().effectiveAppearance) }
        let windowAppearance = probe.windowAppearanceName
        switch check.phase {
        case 2:
            let markers = [SettingsModel.themeRowId, SettingsModel.lookRowId, SettingsModel.newTabRowId,
                           SettingsModel.tooltipsRowId].map(SettingsModel.rowMarker)
            let rows = markers.map { probe.marker($0) }
            let control = probe.marker(SettingsModel.themeControlMarker)
            let switches = [SettingsModel.newTabRowSwitchMarker, SettingsModel.tooltipsSwitchMarker].map { probe.marker($0) }
            guard let theme = rows[0], let look = rows[1], let newTab = rows[2], let tips = rows[3],
                  control != nil, switches.allSatisfy({ $0 != nil }) else {
                note("appearance rows \(rows.map { $0 != nil }) control \(control != nil) switches \(switches.map { $0 != nil })")
                return
            }
            // The board's order: the Theme card, then the Look link, then the Sidebar group. The
            // report is made once, so a retried phase does not repeat it.
            if check.conditions["rows"] != true {
                check.report("rows", theme.maxY <= look.minY + 1 && look.maxY <= newTab.minY + 1
                    && newTab.maxY <= tips.minY + 1 && (control?.width ?? 0) > 0 && (control?.height ?? 0) >= 16
                    && switches.allSatisfy { ($0?.width ?? 0) > 0 && ($0?.height ?? 0) >= 16 })
            }
            // The page reports what `prefers-color-scheme` resolves to. It gets its own tab through
            // the command bar's own URL path (the engine's check-only navigation gate does not name
            // settings screens, and this unit changes no engine).
            guard let host, host.hasBrowser() else { note("no browser for the theme fixture page"); return }
            if !check.themePageRequested {
                guard let adapter, let shown = snapshot.shownSpaceId,
                      let space = snapshot.spaces.first(where: { $0.id == shown }) else {
                    note("no shown space for the theme fixture page"); return
                }
                trace("opening the theme fixture tab")
                check.themePageRequested = true
                adapter.openCommandURL(Self.themeFixturePage, expectedSpace: shown, profile: space.profileName)
                return
            }
            guard let active = host.activeItemId(),
                  (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == active })?.url.hasPrefix("data:text/html") == true else {
                note("the theme fixture tab is not active yet")
                return
            }
            trace("writing dark")
            check.themePhaseStart = browserCheckAttempts
            probe.setTheme(.dark)
            step(3)
        case 3:
            let page = settingsThemePageTitle()
            guard probe.theme == .dark, probe.appAppearanceName == NSAppearance.Name.darkAqua.rawValue,
                  windowAppearance == NSAppearance.Name.darkAqua.rawValue, mainAppearance == "dark" else {
                note("dark: switch=\(probe.themeLabel) app=\(probe.appAppearanceName ?? "nil") settings=\(windowAppearance) main=\(mainAppearance ?? "nil")")
                return
            }
            // Eight seconds is a slow load, not a media query that ignores the theme.
            if page != "dark", browserCheckAttempts - check.themePhaseStart < 80 {
                note("dark applied, page says \(page ?? "nil")")
                return
            }
            check.themePageDark = page
            check.details["theme_dark"] = ["app": probe.appAppearanceName ?? "nil", "settings": windowAppearance,
                                           "main": mainAppearance ?? "nil", "page": page ?? "nil"]
            trace("dark applied, page says \(page ?? "-")")
            check.report("theme_dark", true)
            guard capture("theme-dark") else { end("capture", false); return }
            trace("writing light")
            check.themePhaseStart = browserCheckAttempts
            probe.setTheme(.light)
            step(4)
        case 4:
            let page = settingsThemePageTitle()
            guard probe.theme == .light, probe.appAppearanceName == NSAppearance.Name.aqua.rawValue,
                  windowAppearance == NSAppearance.Name.aqua.rawValue, mainAppearance == "light" else {
                note("light: switch=\(probe.themeLabel) app=\(probe.appAppearanceName ?? "nil") settings=\(windowAppearance) main=\(mainAppearance ?? "nil")")
                return
            }
            if page != "light", browserCheckAttempts - check.themePhaseStart < 80 {
                note("light applied, page says \(page ?? "nil")")
                return
            }
            check.details["theme_page"] = ["dark": check.themePageDark ?? "nil", "light": page ?? "nil"]
            trace("light applied, page says \(page ?? "-")")
            check.report("theme_page", check.themePageDark == "dark" && page == "light")
            check.report("theme_light", true)
            guard capture("theme-light") else { end("capture", false); return }
            trace("closing the settings window")
            owner.settings?.window?.performClose(nil)
            step(5)
        case 5:
            guard owner.settings?.window?.isVisible != true else { note("the settings window is still visible"); return }
            trace("reopening the settings window")
            owner.settings?.checkOpen(paneID: "appearance", shownSpaceID: snapshot.shownSpaceId)
            step(6)
        case 6:
            // The reopened window reads the record: Light, the last value written, so a built-in
            // default cannot answer instead.
            guard probe.isVisible, probe.pageID == "appearance", probe.theme == .light,
                  probe.appAppearanceName == NSAppearance.Name.aqua.rawValue,
                  probe.windowAppearanceName == NSAppearance.Name.aqua.rawValue, mainAppearance == "light" else {
                note("after reopen visible=\(probe.isVisible) page=\(probe.pageID) switch=\(probe.themeLabel) app=\(probe.appAppearanceName ?? "nil") settings=\(windowAppearance) main=\(mainAppearance ?? "nil")")
                return
            }
            trace("reopened on light")
            check.report("theme_reopen", probe.marker(SettingsModel.rowMarker(SettingsModel.themeRowId)) != nil
                && probe.marker(SettingsModel.themeControlMarker) != nil)
            trace("writing system")
            probe.setTheme(.system)
            step(7)
        case 7:
            // System hands every window back to the Mac, so the page and the windows must agree
            // with the Mac's own appearance rather than with either forced one.
            let system = Self.appearanceWord(NSApp.effectiveAppearance)
            let page = settingsThemePageTitle()
            guard probe.theme == .system, probe.appAppearanceName == nil,
                  windowAppearance == (system == "dark" ? NSAppearance.Name.darkAqua : .aqua).rawValue,
                  mainAppearance == system else {
                note("system: switch=\(probe.themeLabel) app=\(probe.appAppearanceName ?? "nil") settings=\(windowAppearance) main=\(mainAppearance ?? "nil") mac=\(system)")
                return
            }
            // The page's own answer is `theme_page`; here only its value is recorded, so a page
            // that never follows cannot stall this phase.
            check.details["theme_system"] = ["app": "nil", "settings": windowAppearance,
                                             "main": mainAppearance ?? "nil", "mac": system, "page": page ?? "nil"]
            trace("system applied, page says \(page ?? "-")")
            check.report("theme_system", true)
            guard capture("theme-system") else { end("capture", false); return }
            guard let today = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first?.id,
                  let before = sidebar?.checkRowFrame(today) else {
                note("no Today row to measure the New Tab row's close-up on"); return
            }
            check.appearanceTodayRow = today
            check.appearanceRowY = before.minY
            trace("New Tab row off, Today row at \(before.minY)")
            probe.setNewTabRowShown(false)
            step(8)
        case 8:
            guard probe.newTabRowShown == false, let sidebar, sidebar.newTabRowForCheck == nil else {
                note("switch off=\(!probe.newTabRowShown) row=\(sidebar?.newTabRowForCheck != nil)"); return
            }
            guard let after = sidebar.checkRowFrame(check.appearanceTodayRow)?.minY else {
                note("the measured Today row is gone"); return
            }
            let delta = check.appearanceRowY - after
            guard abs(delta - probe.newTabRowHeight) < 1 else {
                // A reload that has not laid out yet reads as no movement; the wait names it.
                note("rows moved \(delta), want \(probe.newTabRowHeight)"); return
            }
            trace("New Tab row gone, rows closed up by \(delta)")
            check.report("new_tab_hidden", true)
            trace("closing the settings window")
            owner.settings?.window?.performClose(nil)
            step(9)
        case 9:
            guard owner.settings?.window?.isVisible != true else { note("the settings window is still visible"); return }
            trace("reopening the settings window")
            owner.settings?.checkOpen(paneID: "appearance", shownSpaceID: snapshot.shownSpaceId)
            step(10)
        case 10:
            guard probe.isVisible, probe.pageID == "appearance", probe.newTabRowShown == false else {
                note("after reopen visible=\(probe.isVisible) page=\(probe.pageID) switch=\(probe.newTabRowShown)"); return
            }
            // The reopened window reads the record, and the sidebar still has the row hidden.
            check.report("new_tab_reopen", probe.marker(SettingsModel.rowMarker(SettingsModel.newTabRowId)) != nil
                && sidebar?.newTabRowForCheck == nil)
            // The gate is proved against a tooltip that did show: the header's Back is asked
            // through the same path a hover uses.
            let shown = owner.container?.header.checkTooltip("back")
            guard let shown, shown.0 != nil else {
                note("the header tooltip did not show before the switch"); return
            }
            trace("header tooltip on: \(shown.0 ?? "-") \(shown.1)")
            check.appearanceTooltipShown = true
            probe.setTooltipsShown(false)
            step(11)
        case 11:
            guard probe.tooltipsShown == false else { note("the switch is still on"); return }
            let hidden = owner.container?.header.checkTooltip("back")
            trace("header tooltip off: \(hidden?.0 ?? "nil") \(hidden?.1 ?? [])")
            check.report("tooltips_off", check.appearanceTooltipShown && hidden?.0 == nil)
            guard capture("appearance") else { end("capture", false); return }
            trace("pushing the space page from the Look row")
            probe.openLook()
            step(12)
        case 12:
            guard let shown = snapshot.shownSpaceId, probe.pageID == "space-" + shown else {
                note("page after the Look row: \(probe.pageID), want space-\(snapshot.shownSpaceId ?? "-")"); return
            }
            check.report("look_to_space", probe.highlightedRowID == SettingsModel.lookRowId
                && probe.marker(SettingsModel.rowMarker(SettingsModel.lookRowId)) != nil)
            guard capture("look-space-page") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-websites, U27w: the pane, the defaults, a site's page and its two actions

    /// The fixture tab a step is waiting for: the newest tab whose URL starts with `prefix`.
    private func websiteTab(_ host: any ARWindowHostAPI, prefix: String) -> (any ARTabAPI)? {
        (host.tabs() as? [any ARTabAPI])?.last { $0.url.hasPrefix(prefix) }
    }

    /// Phases 2 to 23 of `settings-websites`. The pane's rows and the core's record; the engine's
    /// application of the record (a fixture page's `Notification.requestPermission()` resolves
    /// denied); Camera back to Ask and the prompt sheet; a site exception through the popover; the
    /// pane's row and summary; All Site Settings…; a site page's Reset; and Clear cookies and site
    /// data proved with a cookie and a localStorage value on two origins (W1–W4).
    private func settingsWebsitesTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                      note: (String) -> Void, trace: (String) -> Void,
                                      step: (Int) -> Void, end: (String, Bool) -> Void,
                                      finish: () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        if let ports = siteFixturePorts, check.websiteSecureBase.isEmpty {
            check.websiteSecureBase = "https://127.0.0.1:\(ports.secure)"
            check.websitePlainBase = "http://ararat.test:\(ports.plain)"
            check.websiteSecureOrigin = check.websiteSecureBase
            check.websitePlainOrigin = check.websitePlainBase
        }
        if let shown = snapshot.shownSpaceId, check.websiteShownSpace.isEmpty,
           let space = snapshot.spaces.first(where: { $0.id == shown }) {
            check.websiteShownSpace = shown
            check.websiteProfile = space.profileName
        }
        func openTab(_ path: String) {
            guard let adapter, !check.websiteShownSpace.isEmpty else { return }
            adapter.openCommandURL(check.websiteSecureBase + path, expectedSpace: check.websiteShownSpace,
                                   profile: check.websiteProfile)
        }
        func openPlainTab(_ path: String) {
            guard let adapter, !check.websiteShownSpace.isEmpty else { return }
            adapter.openCommandURL(check.websitePlainBase + path, expectedSpace: check.websiteShownSpace,
                                   profile: check.websiteProfile)
        }
        switch check.phase {
        case 2:
            let rows = SitePermissionKind.allCases.map { SettingsModel.rowMarker(SettingsModel.websiteRowID($0)) }
            let menus = SitePermissionKind.allCases.map { SettingsModel.websiteMenuMarker($0) }
            let found = rows.map { probe.marker($0) }
            let foundMenus = menus.map { probe.marker($0) }
            let defaults = probe.marker(SettingsModel.rowMarker(SettingsModel.websitesDefaultsCardID))
            let sites = probe.marker(SettingsModel.rowMarker(SettingsModel.websitesSitesCardID))
            guard siteFixturePorts != nil, !check.websiteSecureBase.isEmpty,
                  defaults != nil, sites != nil,
                  found.allSatisfy({ $0 != nil }), foundMenus.allSatisfy({ $0 != nil }) else {
                note("websites rows \(found.map { $0 != nil }) menus \(foundMenus.map { $0 != nil }) cards \(defaults != nil)/\(sites != nil) fixture \(siteFixturePorts != nil)")
                return
            }
            // The board's order, and the built-in values: Ask for five, Block for pop-ups, Allow
            // for sound. The empty card says no site has its own settings yet.
            let ordered = zip(found, found.dropFirst()).allSatisfy { first, second in
                guard let first, let second else { return false }
                return first.maxY <= second.minY + 1
            }
            let stored = probe.siteDefaults
            let values = SitePermissionKind.allCases.map { stored.value(for: $0) }
            let expected: [SitePermissionValue] = [.ask, .ask, .ask, .ask, .block, .ask, .allow]
            let menusSized = foundMenus.allSatisfy { menu in
                guard let menu else { return false }
                return menu.width >= 64 && menu.height >= 16
            }
            let empty = probe.siteRows.isEmpty && probe.marker(SettingsModel.websitesEmptyMarker) != nil
            check.report("rows", ordered && values == expected && menusSized && empty)
            guard capture("websites") else { end("capture", false); return }
            trace("writing notifications block")
            probe.setSiteDefault(.notifications, .block)
            step(3)
        case 3:
            guard probe.siteDefaults.notifications == .block else {
                note("notifications after the write: \(probe.siteDefaults.notifications)")
                return
            }
            check.report("defaults_write", true)
            trace("closing the settings window")
            owner.settings?.window?.performClose(nil)
            step(4)
        case 4:
            guard owner.settings?.window?.isVisible != true else { note("the settings window is still visible"); return }
            trace("reopening the settings window")
            owner.settings?.checkOpen(paneID: "websites", shownSpaceID: snapshot.shownSpaceId)
            step(5)
        case 5:
            // The reopened window reads the record from the core, not its own last model.
            guard probe.isVisible, probe.pageID == "websites", probe.siteDefaults.notifications == .block else {
                note("after reopen visible=\(probe.isVisible) page=\(probe.pageID) notifications=\(probe.siteDefaults.notifications)")
                return
            }
            check.report("defaults_reopen", probe.marker(SettingsModel.websiteMenuMarker(.notifications)) != nil)
            trace("opening the notification fixture")
            check.websitePromptsBefore = websitePromptCount()
            openTab("/websites?do=notification")
            step(6)
        case 6:
            guard let host, let tab = websiteTab(host, prefix: check.websiteSecureBase + "/websites?do=notification"),
                  !tab.isLoading, tab.title.hasPrefix("notification:") else {
                note("notification fixture not ready")
                return
            }
            // Block is the engine's default now: the page resolves denied and nothing asked.
            check.report("notification_denied", tab.title == "notification:denied"
                && websitePromptCount() == check.websitePromptsBefore)
            trace("camera to block, then back to ask")
            probe.setSiteDefault(.camera, .block)
            step(7)
        case 7:
            guard probe.siteDefaults.camera == .block else { note("camera after block: \(probe.siteDefaults.camera)"); return }
            probe.setSiteDefault(.camera, .ask)
            step(8)
        case 8:
            guard probe.siteDefaults.camera == .ask else { note("camera after ask: \(probe.siteDefaults.camera)"); return }
            check.websitePromptsBefore = websitePromptCount()
            // Chromium shows a permission prompt for the active tab of a visible window; the
            // fixture window goes back to the front for this step, and the settings window stays
            // readable through its markers.
            host?.window().makeKeyAndOrderFront(nil)
            trace("opening the camera fixture")
            openTab("/websites?do=camera")
            step(9)
        case 9:
            guard let host, let tab = websiteTab(host, prefix: check.websiteSecureBase + "/websites?do=camera") else {
                note("camera fixture tab"); return
            }
            guard websitePromptCount() > check.websitePromptsBefore else {
                note("camera prompt has not shown (title \(tab.title), shown \(websitePromptCount()) want > \(check.websitePromptsBefore))")
                return
            }
            check.report("camera_prompt", true)
            trace("allowing the camera prompt")
            guard tab.checkPermissionDecision(0) else { note("camera decision refused"); return }
            step(10)
        case 10:
            guard let host, let tab = websiteTab(host, prefix: check.websiteSecureBase + "/websites?do=camera"),
                  !tab.checkPermissionPending() else {
                note("camera prompt still pending"); return
            }
            trace("opening the site controls popover")
            sidebar?.checkClickSiteControls()
            step(11)
        case 11:
            guard let controls = siteControls, controls.isShown else { note("site controls popover"); return }
            let rows = controls.checkPermissionRows
            guard let index = rows.firstIndex(where: { $0.type == SitePermissionKind.camera.rawValue }),
                  let block = rows[index].items.firstIndex(of: "Block") else {
                note("camera row in the popover: \(rows.map { "\($0.type)=\($0.current)" })"); return
            }
            trace("choosing Block in the popover")
            guard controls.checkChoosePermission(row: index, item: block) else { note("popover write refused"); return }
            step(12)
        case 12:
            guard let controls = siteControls,
                  controls.checkPermissionRows.first(where: { $0.type == SitePermissionKind.camera.rawValue })?.current == "Block" else {
                note("popover camera row after the write: \(siteControls?.checkPermissionRows.map { "\($0.type)=\($0.current)" } ?? [])")
                return
            }
            controls.close()
            trace("reading the pane's site rows")
            probe.readWebsites()
            step(13)
        case 13:
            guard let row = probe.siteRows.first(where: {
                $0.origin == check.websiteSecureOrigin && $0.profile == check.websiteProfile
            }) else {
                note("pane site rows: \(probe.siteRows.map { "\($0.origin)|\($0.profile)" }) want \(check.websiteSecureOrigin)|\(check.websiteProfile)")
                return
            }
            let summary = probe.siteSummary(row)
            let expected = "Camera: Block · " + check.websiteProfile
            check.websiteSiteRow = row
            check.report("popover_exception", row.settings[.camera]?.title == "Block")
            // W2's summary: the board's kinds in order, then the profile because this workspace
            // has two.
            check.report("pane_site_row", summary == expected
                && probe.marker(SettingsModel.rowMarker(SettingsModel.websiteSiteRowID(row))) != nil)
            check.details["site_summary"] = summary
            trace("site row \(summary)")
            guard capture("site-row") else { end("capture", false); return }
            sidebar?.checkClickSiteControls()
            step(14)
        case 14:
            guard let controls = siteControls, controls.isShown else { note("popover for All Site Settings"); return }
            trace("clicking All Site Settings…")
            guard controls.checkClickAllSiteSettings() else { note("All Site Settings… refused"); return }
            step(15)
        case 15:
            let page = "site-" + check.websiteSecureOrigin + "|" + check.websiteProfile
            guard probe.isVisible, probe.pageID == page,
                  probe.marker(SettingsModel.rowMarker(SettingsModel.sitePermissionRowID(.camera))) != nil,
                  probe.marker(SettingsModel.siteResetButtonMarker) != nil,
                  probe.marker(SettingsModel.siteClearButtonMarker) != nil else {
                note("site page \(probe.pageID) want \(page) rows=\(probe.marker(SettingsModel.rowMarker(SettingsModel.sitePermissionRowID(.camera))) != nil)")
                return
            }
            check.report("all_site_settings", true)
            check.report("site_page_rows", probe.marker(SettingsModel.sitePermissionMenuMarker(.camera)) != nil
                && probe.marker(SettingsModel.rowMarker(SettingsModel.siteResetRowID)) != nil
                && probe.marker(SettingsModel.rowMarker(SettingsModel.siteClearRowID)) != nil)
            guard capture("site-page") else { end("capture", false); return }
            trace("writing storage on both origins")
            openTab("/websites?do=storage")
            openPlainTab("/websites?do=storage")
            step(16)
        case 16:
            guard let host,
                  let secure = websiteTab(host, prefix: check.websiteSecureBase + "/websites?do=storage"),
                  let plain = websiteTab(host, prefix: check.websitePlainBase + "/websites?do=storage"),
                  !secure.isLoading, !plain.isLoading,
                  secure.title == "storage:written", plain.title == "storage:written" else {
                note("storage fixtures: records not written yet"); return
            }
            trace("clearing cookies and site data")
            probe.clearSiteData(origin: check.websiteSecureOrigin, profile: check.websiteProfile) {
                check.websiteClearFinished = true
            }
            step(17)
        case 17:
            guard check.websiteClearFinished else { note("clear still running"); return }
            check.websiteClearFinished = false
            trace("reading both origins back")
            openTab("/websites?do=read")
            step(18)
        case 18:
            guard let host, let tab = websiteTab(host, prefix: check.websiteSecureBase + "/websites?do=read"),
                  !tab.isLoading, tab.title.hasPrefix("storage:") else { note("secure read-back"); return }
            check.websiteReadSecure = tab.title
            openPlainTab("/websites?do=read")
            step(19)
        case 19:
            guard let host, let tab = websiteTab(host, prefix: check.websitePlainBase + "/websites?do=read"),
                  !tab.isLoading, tab.title.hasPrefix("storage:") else { note("plain read-back"); return }
            check.websiteReadPlain = tab.title
            check.details["storage_read"] = ["secure": check.websiteReadSecure ?? "nil", "plain": tab.title]
            // The cleared site's cookie and localStorage are gone; the other origin's stay.
            check.report("clear_site_data", check.websiteReadSecure == "storage:none:nocookie")
            check.report("other_origin_kept", tab.title == "storage:value:cookie")
            trace("resetting the site's permissions")
            probe.openWebsitesPane()
            step(20)
        case 20:
            guard probe.pageID == "websites" else { note("pane after the site page: \(probe.pageID)"); return }
            probe.resetSitePermissions(origin: check.websiteSecureOrigin, profile: check.websiteProfile)
            step(21)
        case 21:
            guard probe.siteRows.first(where: {
                $0.origin == check.websiteSecureOrigin && $0.profile == check.websiteProfile
            }) == nil else {
                note("site rows after Reset: \(probe.siteRows.map { "\($0.origin)|\($0.profile)" })")
                return
            }
            check.report("reset_removes", probe.marker(SettingsModel.websitesEmptyMarker) != nil)
            trace("Rows reset")
            guard capture("websites-reset") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    /// The prompts the engine has shown in this process, through the focused tab's check API.
    private func websitePromptCount() -> Int {
        guard let host, let active = host.activeItemId(),
              let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == active }) else { return 0 }
        return Int(tab.checkPermissionShownCount())
    }

    // MARK: settings-spaces, U27c: the direction card's write, and both wheels
    /// Sends a sideways wheel to the sidebar the way a trackball does. The pipeline judges a
    /// wheel after cancelling the system's natural-scrolling inversion, so a machine with
    /// natural scrolling on gets the inverse CGEvent and lands on the same delta.
    @discardableResult
    func settingsSpacesSendWheel() -> Bool {
        guard let input = SettingsScreenCheck.spaceWheelEvent() else { return false }
        FileHandle.standardError.write(Data("ararat-trace: settings-spaces send wheel time=\(input.timestamp) dx=\(input.scrollingDeltaX) dy=\(input.scrollingDeltaY) inverted=\(input.isDirectionInvertedFromDevice)\n".utf8))
        sidebar?.scrollWheel(with: input)
        return true
    }
}

extension SettingsScreenCheck {
    static func spaceWheelEvent(time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -5, wheel3: 0),
              let input = NSEvent(cgEvent: event) else { return nil }
        var wheel = event
        if input.isDirectionInvertedFromDevice,
           let inverse = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 5, wheel3: 0) { wheel = inverse }
        // Unposted CGEvents have timestamp zero, so waiting cannot expire the classifier's pause.
        wheel.timestamp = UInt64(time * 1_000_000_000)
        return NSEvent(cgEvent: wheel)
    }
}

extension Runtime {
    /// Phases 4 to 11 of `settings-spaces` (U27c): with Natural the sidebar's wheel pages to
    /// the next space; the pane then writes Reversed, the window closes and reopens on the card
    /// with Reversed still chosen, and the same wheel pages the other way.
    private func settingsSpacesScrollTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                          note: (String) -> Void, trace: (String) -> Void,
                                          step: (Int) -> Void, end: (String, Bool) -> Void,
                                          finish: () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        let spaces = snapshot.spaces
        func index(_ id: String) -> Int? { spaces.firstIndex { $0.id == id } }
        /// A start space with a neighbour on both sides, so either wheel switches rather than
        /// opening the Library or pulling into space creation.
        var startIndex: Int { max(1, min(spaces.count - 2, spaces.count / 2)) }
        switch check.phase {
        case 4:
            guard spaces.count >= 3 else { note("the wheel needs 3 spaces, there are \(spaces.count)"); return }
            guard probe.pageID == "spaces" else {
                probe.openSpacesPane()
                note("back to the spaces pane from \(probe.pageID)")
                return
            }
            trace("writing natural")
            probe.setSpaceScrollDirection(.natural)
            step(5)
        case 5:
            guard probe.spaceScrollDirection == .natural else { note("direction \(probe.spaceScrollDirectionLabel)"); return }
            let start = startIndex
            guard let sidebar, spaces.indices.contains(start) else { note("no sidebar"); return }
            if snapshot.shownSpaceId != spaces[start].id {
                sidebar.showSpace(at: start)
                note("moving to space \(spaces[start].title)")
                return
            }
            check.wheelStart = spaces[start].id
            trace("natural wheel from \(start)")
            guard settingsSpacesSendWheel() else { end("scroll_wheel_natural", false); return }
            check.naturalWheelSentAt = ProcessInfo.processInfo.systemUptime
            step(6)
        case 6:
            guard let start = index(check.wheelStart), snapshot.shownSpaceId != check.wheelStart,
                  let shown = snapshot.shownSpaceId.flatMap(index) else {
                note("shown after the natural wheel: \(snapshot.shownSpaceId ?? "-")"); return
            }
            check.naturalDelta = shown - start
            trace("natural wheel landed on \(shown) from \(start)")
            check.report("scroll_wheel_natural", check.naturalDelta == 1)
            guard let sidebar, spaces.indices.contains(start) else { return }
            sidebar.showSpace(at: start)
            step(7)
        case 7:
            guard index(check.wheelStart) != nil, snapshot.shownSpaceId == check.wheelStart else {
                note("back at \(snapshot.shownSpaceId ?? "-"), wanted \(check.wheelStart)"); return
            }
            trace("writing reversed")
            probe.setSpaceScrollDirection(.reversed)
            step(8)
        case 8:
            guard probe.spaceScrollDirection == .reversed else {
                note("direction after the write: \(probe.spaceScrollDirectionLabel)"); return
            }
            trace("closing the settings window")
            owner.settings?.window?.performClose(nil)
            step(9)
        case 9:
            guard owner.settings?.window?.isVisible != true else { note("the settings window is still visible"); return }
            trace("reopening the settings window")
            owner.settings?.checkOpen(paneID: "spaces", shownSpaceID: snapshot.shownSpaceId)
            step(10)
        case 10:
            guard probe.isVisible, probe.pageID == "spaces", probe.spaceScrollDirection == .reversed,
                  snapshot.shownSpaceId == check.wheelStart else {
                note("after reopen visible=\(probe.isVisible) page=\(probe.pageID) direction=\(probe.spaceScrollDirectionLabel) shown=\(snapshot.shownSpaceId ?? "-")")
                return
            }
            // Reopening Settings and changing direction must not bypass the sidebar's wheel pause.
            guard ProcessInfo.processInfo.systemUptime - check.naturalWheelSentAt >= 0.250 else {
                note("waiting for the natural wheel's 250 ms pause"); return
            }
            check.report("scroll_write_reopen", probe.marker(SettingsModel.rowMarker(SettingsModel.spaceScrollDirectionCardId)) != nil)
            trace("reversed wheel")
            guard settingsSpacesSendWheel() else { end("scroll_wheel_reversed", false); return }
            step(11)
        case 11:
            guard let start = index(check.wheelStart), snapshot.shownSpaceId != check.wheelStart,
                  let shown = snapshot.shownSpaceId.flatMap(index) else {
                note("shown after the reversed wheel: \(snapshot.shownSpaceId ?? "-")"); return
            }
            let delta = shown - start
            trace("reversed wheel landed on \(shown) from \(start)")
            check.report("scroll_wheel_reversed", delta == -1 && check.naturalDelta == 1)
            guard capture("spaces") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-extensions (U27x): the chooser, the rows, the switch, site access, Review…
    // and Remove…, then a reopen

    /// The fixture directories arrive as arguments the runner forwards, so the VM needs no access
    /// to the checkout: `--ararat-extension-fixture-default=<windows>` and
    /// `--ararat-extension-fixture-second=<urlfield-one>`.
    private static func extensionFixture(_ name: String) -> String {
        let prefix = "--ararat-extension-fixture-" + name + "="
        guard let value = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { return "" }
        return String(value.dropFirst(prefix.count))
    }

    /// The Views dialog seam (Major 2): the engine resolves the dialog the Settings window owns
    /// and accepts or cancels it through `DialogDelegate`, returning the dialog's contents class.
    /// No accessibility: the VM's in-process tree is empty.
    private func extensionDialog(action: String) -> String {
        let settingsWindow = (root ?? self).settings?.window
        let name = EngineExtensionSettingsHost.shared.checkExtensionDialog(parent: settingsWindow,
                                                                           action: action)
        let label = action == "accept" ? "review" : "remove"
        FileHandle.standardError.write(Data("ararat-trace: extensions \(label) dialog \(name)\n".utf8))
        return name
    }

    /// Phases 2 to 17 of `settings-extensions`. Two profiles start with different fixture
    /// extensions (the check installs unpacked directories into each profile's own service); the
    /// chooser switches the list; the switch disables an extension whose pinned action leaves the
    /// URL field and enabling brings it back; "On click" is read back from the engine; Review…
    /// opens Chromium's prompt and accepting re-enables; Remove… cancelled keeps the row; and a
    /// reopened window reads the same state.
    private func settingsExtensionsTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                        note: (String) -> Void, trace: (String) -> Void,
                                        step: (Int) -> Void, end: (String, Bool) -> Void,
                                        finish: () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        let engine = EngineExtensionSettingsHost.shared
        let sidebar = owner.sidebar
        func fixtureRow(_ probe: SettingsCheckProbe, _ id: String) -> SettingsExtension? {
            probe.extensionRow(id: id)
        }
        if check.extensionDefaultProfile.isEmpty, let shown = snapshot.shownSpaceId,
           let space = snapshot.spaces.first(where: { $0.id == shown }) {
            check.extensionDefaultProfile = space.profileName
            check.extensionSecondProfile = snapshot.spaces.first { $0.profileName != space.profileName }?.profileName ?? ""
            check.extensionFixtureDefault = Self.extensionFixture("default")
            check.extensionFixtureSecond = Self.extensionFixture("second")
        }
        if !check.extensionInstalling {
            guard !check.extensionDefaultProfile.isEmpty, !check.extensionSecondProfile.isEmpty,
                  !check.extensionFixtureDefault.isEmpty, !check.extensionFixtureSecond.isEmpty else {
                note("fixture arguments: default=\(check.extensionFixtureDefault) second=\(check.extensionFixtureSecond)")
                return
            }
            check.extensionInstalling = true
            trace("installing fixtures into \(check.extensionDefaultProfile) and \(check.extensionSecondProfile)")
            engine.checkLoadUnpacked(profile: check.extensionDefaultProfile, path: check.extensionFixtureDefault) { result in
                check.extensionDefaultLoaded = result == "loaded"
                FileHandle.standardError.write(Data("ararat-trace: extensions default fixture \(result)\n".utf8))
            }
            engine.checkLoadUnpacked(profile: check.extensionSecondProfile, path: check.extensionFixtureSecond) { result in
                check.extensionSecondLoaded = result == "loaded"
                FileHandle.standardError.write(Data("ararat-trace: extensions second fixture \(result)\n".utf8))
            }
            return
        }
        switch check.phase {
        case 2:
            probe.refreshExtensions()
            guard check.extensionDefaultLoaded, check.extensionSecondLoaded,
                  probe.extensionProfile == check.extensionDefaultProfile,
                  let row = probe.extensions.first(where: { $0.name.hasPrefix("Ararat windows check") }),
                  row.canPin else {
                note("phase 2 waits for loaded fixtures (default=\(check.extensionDefaultLoaded) second=\(check.extensionSecondLoaded)), the Default profile (\(check.extensionDefaultProfile), now \(probe.extensionProfile)), the windows row, and canPin=true (now \(probe.extensions.first(where: { $0.name.hasPrefix("Ararat windows check") })?.canPin ?? false)); rows=\(probe.extensions.map(\.name)); in_field=\(sidebar?.checkInFieldActionIDs ?? [])")
                return
            }
            check.extensionDefaultID = row.id
            let profileRow = probe.marker(SettingsModel.rowMarker(SettingsModel.extensionsProfileRowID))
            let menu = probe.marker(SettingsModel.extensionsProfileMenuMarker)
            let card = probe.marker(SettingsModel.rowMarker(SettingsModel.extensionsListCardID))
            let switchMarker = probe.marker(SettingsModel.extensionSwitchMarker(row.id))
            let titles = probe.extensionMenuTitles(row)
            // The pin item follows the row's own state: Chrome may load the fixture's action pinned.
            let expectedTitles = ["On all sites", "On click",
                                  row.pinned ? "Unpin from Sidebar" : "Pin to Sidebar",
                                  "Manage Extension", "Remove…"]
            let menuOK = titles == expectedTitles
            check.report("rows", profileRow != nil && menu != nil && card != nil && switchMarker != nil
                && probe.extensions.count == 1 && row.enabled && !row.needsReview
                && row.summary == row.siteAccess.title && menuOK)
            check.details["default_row"] = ["name": row.name, "summary": row.summary,
                                            "site_access": row.siteAccess.rawValue, "menu": titles]
            trace("rows: \(row.name) \(row.summary) menu=\(titles)")
            guard capture("extensions") else { end("capture", false); return }
            probe.selectExtensionProfile(check.extensionSecondProfile)
            step(3)
        case 3:
            probe.refreshExtensions()
            guard probe.extensionProfile == check.extensionSecondProfile,
                  let row = probe.extensions.first(where: { $0.name.hasPrefix("Ararat URL field action one") }) else {
                note("after the chooser: profile=\(probe.extensionProfile) rows=\(probe.extensions.map(\.name))")
                return
            }
            check.extensionSecondID = row.id
            // The chooser really switched lists: the second profile has its own fixture and no
            // windows fixture.
            check.report("profile_switch", probe.extensions.count == 1 && row.id != check.extensionDefaultID
                && probe.marker(SettingsModel.rowMarker(SettingsModel.extensionRowID(row.id))) != nil)
            trace("switched to \(probe.extensionProfile): \(row.name)")
            guard capture("extensions-profile2") else { end("capture", false); return }
            probe.selectExtensionProfile(check.extensionDefaultProfile)
            step(4)
        case 4:
            probe.refreshExtensions()
            guard probe.extensionProfile == check.extensionDefaultProfile,
                  let row = fixtureRow(probe, check.extensionDefaultID), row.canPin else {
                note("back on \(probe.extensionProfile) row=\(probe.extensions.map(\.name)) pin=\(fixtureRow(probe, check.extensionDefaultID)?.canPin ?? false)")
                return
            }
            // Chrome may load a new action pinned; start from Unpinned so the write is the check's.
            if row.pinned {
                trace("unpinning \(row.name) before the pin check")
                guard probe.toggleExtensionPin(row.id) else { note("unpin write refused"); return }
                return
            }
            trace("pinning \(row.name)")
            guard probe.toggleExtensionPin(row.id) else { note("pin write refused"); return }
            step(5)
        case 5:
            guard let row = fixtureRow(probe, check.extensionDefaultID), row.pinned,
                  sidebar?.checkInFieldActionIDs.contains(row.id) == true else {
                note("pin: pinned=\(fixtureRow(probe, check.extensionDefaultID)?.pinned ?? false) in_field=\(sidebar?.checkInFieldActionIDs ?? [])")
                return
            }
            check.report("pin_action", true)
            trace("pinned action in the URL field")
            guard probe.setExtensionEnabled(row.id, false) else { note("disable refused"); return }
            step(6)
        case 6:
            guard let row = fixtureRow(probe, check.extensionDefaultID), !row.enabled,
                  row.summary == "Off",
                  sidebar?.checkInFieldActionIDs.contains(row.id) != true else {
                note("disabled: row=\(fixtureRow(probe, check.extensionDefaultID).map { "\($0.enabled)/\($0.summary)" } ?? "nil") in_field=\(sidebar?.checkInFieldActionIDs ?? [])")
                return
            }
            check.report("disable_hides_action", true)
            trace("disabled; the pinned action left the URL field")
            guard capture("extensions-disabled") else { end("capture", false); return }
            guard probe.setExtensionEnabled(row.id, true) else { note("enable refused"); return }
            step(7)
        case 7:
            guard let row = fixtureRow(probe, check.extensionDefaultID), row.enabled,
                  sidebar?.checkInFieldActionIDs.contains(row.id) == true else {
                note("enabled: row=\(fixtureRow(probe, check.extensionDefaultID).map { "\($0.enabled)/\($0.summary)" } ?? "nil") in_field=\(sidebar?.checkInFieldActionIDs ?? [])")
                return
            }
            check.report("enable_brings_action", true)
            trace("re-enabled; the pinned action is back (\(row.siteAccess.rawValue))")
            guard probe.setExtensionSiteAccess(row.id, .onClick) else { note("site access write refused"); return }
            step(8)
        case 8:
            guard let row = fixtureRow(probe, check.extensionDefaultID), row.siteAccess == .onClick else {
                note("site access: \(fixtureRow(probe, check.extensionDefaultID)?.siteAccess.rawValue ?? "nil")")
                return
            }
            check.report("site_access_write", true)
            check.details["site_access"] = row.siteAccess.rawValue
            trace("site access read back from the engine: \(row.siteAccess.rawValue)")
            engine.checkDisableForReview(profile: check.extensionDefaultProfile, identifier: row.id)
            step(9)
        case 9:
            guard let row = fixtureRow(probe, check.extensionDefaultID), row.needsReview, !row.enabled,
                  probe.marker(SettingsModel.extensionReviewMarker(row.id)) != nil else {
                note("needs review: row=\(fixtureRow(probe, check.extensionDefaultID).map { "\($0.needsReview)/\($0.enabled)" } ?? "nil") marker=\(probe.marker(SettingsModel.extensionReviewMarker(check.extensionDefaultID)) != nil)")
                return
            }
            check.details["review_row"] = ["summary": row.summary, "needs_review": true]
            trace("Review… shown: \(row.summary)")
            guard capture("extensions-review") else { end("capture", false); return }
            probe.reviewExtension(row.id)
            step(10)
        case 10:
            // Major 2: the engine's Views seam accepts the real re-enable prompt and names its
            // class; an empty answer means the prompt has not opened yet.
            let dialog = extensionDialog(action: "accept")
            guard !dialog.isEmpty else { note("the re-enable prompt has not opened"); return }
            check.extensionReviewDialog = dialog
            step(11)
        case 11:
            guard let row = fixtureRow(probe, check.extensionDefaultID), row.enabled, !row.needsReview else {
                note("after accepting: enabled=\(fixtureRow(probe, check.extensionDefaultID)?.enabled ?? false) review=\(fixtureRow(probe, check.extensionDefaultID)?.needsReview ?? false) dialog=\(check.extensionReviewDialog)")
                return
            }
            // Non-vacuous: the prompt itself was up, not just any new window.
            check.report("review_prompt", check.extensionReviewDialog.contains("ExtensionInstallDialogView"))
            check.report("review_enables", true)
            check.details["review_dialog"] = check.extensionReviewDialog
            trace("accepted \(check.extensionReviewDialog); the extension is enabled again")
            probe.requestRemoveExtension(row.id)
            step(12)
        case 12:
            // Design decision B: Remove… is our AppKit sheet on the Settings window. The check ends
            // it with the Cancel return code, which is the sheet's default button (and Esc).
            guard let sheet = owner.settings?.window?.attachedSheet, sheet.isVisible else {
                note("the remove sheet has not opened")
                return
            }
            guard let row = fixtureRow(probe, check.extensionDefaultID) else {
                note("the removed row is gone before the sheet")
                return
            }
            let expectedTitle = SettingsCheckProbe.removeSheetTitle(for: row.name)
            guard sheet.title == expectedTitle else {
                note("remove sheet title \(sheet.title.debugDescription), want \(expectedTitle.debugDescription)")
                return
            }
            check.extensionRemoveSheetTitle = sheet.title
            trace("cancelling the remove sheet: \(sheet.title)")
            owner.settings?.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            step(13)
        case 13:
            guard probe.pendingRemoval == nil else { note("the remove sheet has not reported"); return }
            guard let row = fixtureRow(probe, check.extensionDefaultID) else {
                note("the cancelled extension is gone")
                return
            }
            check.report("remove_cancel_keeps", probe.extensions.contains { $0.id == row.id }
                && check.extensionRemoveSheetTitle == SettingsCheckProbe.removeSheetTitle(for: row.name))
            check.details["remove_sheet"] = check.extensionRemoveSheetTitle
            trace("cancelled \(check.extensionRemoveSheetTitle); the row stays")
            owner.settings?.window?.performClose(nil)
            step(14)

        case 14:
            guard owner.settings?.window?.isVisible != true else { note("the settings window is still visible"); return }
            trace("reopening the settings window")
            owner.settings?.checkOpen(paneID: "extensions", shownSpaceID: snapshot.shownSpaceId)
            step(15)
        case 15:
            guard probe.isVisible, probe.pageID == "extensions",
                  probe.extensionProfile == check.extensionDefaultProfile,
                  let row = fixtureRow(probe, check.extensionDefaultID), row.enabled, !row.needsReview else {
                note("after reopen: visible=\(probe.isVisible) page=\(probe.pageID) profile=\(probe.extensionProfile) row=\(probe.extensions.map(\.name))")
                return
            }
            trace("reopened on \(probe.extensionProfile); switching to \(check.extensionSecondProfile)")
            probe.selectExtensionProfile(check.extensionSecondProfile)
            step(16)
        case 16:
            guard probe.extensionProfile == check.extensionSecondProfile,
                  probe.extensions.contains(where: { $0.id == check.extensionSecondID }) else {
                note("after reopen on the second profile: profile=\(probe.extensionProfile) rows=\(probe.extensions.map(\.name))")
                return
            }
            probe.selectExtensionProfile(check.extensionDefaultProfile)
            step(17)
        case 17:
            guard let row = fixtureRow(probe, check.extensionDefaultID), row.enabled,
                  !row.needsReview, row.siteAccess == .onClick, row.pinned else {
                note("reopen state: row=\(fixtureRow(probe, check.extensionDefaultID).map { "\($0.enabled)/\($0.needsReview)/\($0.siteAccess.rawValue)/\($0.pinned)" } ?? "nil")")
                return
            }
            check.report("reopen_state", true)
            trace("reopen reads the same state: enabled, On click, pinned")
            guard capture("extensions-reopen") else { end("capture", false); return }
            finish()
        default: break
        }
    }
}
