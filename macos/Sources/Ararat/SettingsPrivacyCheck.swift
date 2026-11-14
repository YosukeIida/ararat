// The settings-privacy tick (U27p P2–P4), appended to SettingsScreenCheck's extension.
import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

extension Runtime {
    /// Phases 2 to 17 of `settings-privacy`: the pane's four rows after the core has answered; the
    /// retention visits seeded and One week written in phase 2, before the first expiry pass
    /// (R2-1); the cross-site cookie fixture allowed then blocked; the GPC switch on (the fixture
    /// reads the navigation's and the fetch's `Sec-GPC` and `navigator.globalPrivacyControl`) and
    /// off (reads none), which covers the wait; the two visits read within a 40 s bound from the
    /// seed; the clear sheet over the Settings window clearing the last hour's history and a
    /// fixture cookie while an older visit stays; and a reopen, after a sentinel the core does not
    /// hold, reading the record from the core.
    func settingsPrivacyTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                             note: @escaping (String) -> Void, trace: @escaping (String) -> Void,
                             step: @escaping (Int) -> Void, end: (String, Bool) -> Void,
                             finish: @escaping () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        if let ports = siteFixturePorts, check.websiteSecureBase.isEmpty {
            check.websiteSecureBase = "https://127.0.0.1:\(ports.secure)"
            check.websitePlainBase = "http://ararat.test:\(ports.plain)"
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
        // The cookie fixture's parent is the plain origin and the iframe the TLS origin: an https
        // page embedding an http iframe would be blocked as mixed content before the frame's
        // cookie is touched, so the direction is the other way round.
        func openPlainTab(_ path: String) {
            guard let adapter, !check.websiteShownSpace.isEmpty else { return }
            adapter.openCommandURL(check.websitePlainBase + path, expectedSpace: check.websiteShownSpace,
                                   profile: check.websiteProfile)
        }
        func tab(_ prefix: String) -> (any ARTabAPI)? {
            guard let host else { return nil }
            return (host.tabs() as? [any ARTabAPI])?.last { $0.url.hasPrefix(prefix) }
        }
        func plainTab(_ path: String) -> (any ARTabAPI)? { tab(check.websitePlainBase + path) }
        func fixtureTab(_ path: String) -> (any ARTabAPI)? { tab(check.websiteSecureBase + path) }

        switch check.phase {
        case 2:
            let rows = [SettingsModel.privacyClearRowID, SettingsModel.privacyCookiesRowID,
                        SettingsModel.privacyGPCRowID, SettingsModel.privacyHistoryRowID]
                .map { probe.marker(SettingsModel.rowMarker($0)) }
            let controls = [SettingsModel.privacyClearButtonMarker, SettingsModel.privacyCookiesMenuMarker,
                            SettingsModel.privacyGPCSwitchMarker, SettingsModel.privacyHistoryMenuMarker]
                .map { probe.marker($0) }
            guard siteFixturePorts != nil, !check.websiteSecureBase.isEmpty,
                  rows.allSatisfy({ $0 != nil }), controls.allSatisfy({ $0 != nil }) else {
                note("privacy rows \(rows.map { $0 != nil }) controls \(controls.map { $0 != nil }) fixture \(siteFixturePorts != nil)")
                return
            }
            // M4: `rows` must not pass on the model's initial value; the read has to have answered.
            guard probe.privacyLoaded else { note("privacy record read pending"); return }
            let ordered = zip(rows, rows.dropFirst()).allSatisfy { first, second in
                guard let first, let second else { return false }
                return first.maxY <= second.minY + 1
            }
            // The board's built-in record: Block, GPC on, One year; the Protection card is absent
            // (P1), so no ads or dangerous-sites marker is drawn either.
            let stored = probe.privacy
            let noProtection = probe.marker(SettingsModel.rowMarker("privacy-protection")) == nil
            check.report("rows", ordered && noProtection
                         && stored.thirdPartyCookies == .block && stored.globalPrivacyControl
                         && stored.historyRetention == .year)
            guard capture("privacy") else { end("capture", false); return }
            // R2-1: a fresh profile's only all-visits expiry pass inside the run's limits is the
            // one at t0+30 s (t0 = profile load): seed both visits and write One week now, before
            // the cookie and GPC phases, so the pass sees them. AddPage keeps a 10-day-old visit
            // whatever the retention, so posting both before the pass is enough.
            check.privacySeedTime = Date()
            check.privacySeedUptime = ProcessInfo.processInfo.systemUptime
            trace("seeded retention visits at +\(Int(check.privacySeedUptime ?? 0))s from launch; waiting for the first expiry pass")
            PrivacyCheckEngine.seedVisit(profile: check.websiteProfile, url: check.privacyTenDayVisitURL, daysAgo: 10) { _ in }
            PrivacyCheckEngine.seedVisit(profile: check.websiteProfile, url: check.privacyTwoDayVisitURL, daysAgo: 2) { _ in }
            probe.setHistoryRetention(.week)
            step(3)
        case 3:
            // One privacy write at a time: the model's write builds on the previous answer, so
            // waiting for Week before Allow keeps both values (two immediate writes would have the
            // later one overwrite the earlier).
            guard probe.privacy.historyRetention == .week else {
                note("retention before the cookie fixture: \(probe.privacy.historyRetention.label)")
                return
            }
            check.report("retention_write", true)
            probe.setThirdPartyCookies(.allow)
            step(4)
        case 4:
            guard probe.privacy.thirdPartyCookies == .allow else {
                note("cookies after Allow: \(probe.privacy.thirdPartyCookies.label)"); return
            }
            trace("opening the cross-site cookie fixture under Allow")
            openPlainTab("/privacy?do=cookie&n=allow&frame=\(check.websiteSecureBase)")
            step(5)
        case 5:
            guard let tab = plainTab("/privacy?do=cookie&n=allow"), !tab.isLoading,
                  tab.title.hasPrefix("cookie:") else { note("cookie fixture under Allow"); return }
            check.privacyCookieTitle = tab.title
            check.report("cookies_allowed", tab.title == "cookie:set:present")
            trace("blocking third-party cookies")
            probe.setThirdPartyCookies(.block)
            step(6)
        case 6:
            guard probe.privacy.thirdPartyCookies == .block else {
                note("cookies after Block: \(probe.privacy.thirdPartyCookies.label)"); return
            }
            openPlainTab("/privacy?do=cookie&n=block&frame=\(check.websiteSecureBase)")
            step(7)
        case 7:
            guard let tab = plainTab("/privacy?do=cookie&n=block"), !tab.isLoading,
                  tab.title.hasPrefix("cookie:") else { note("cookie fixture under Block"); return }
            check.privacyCookieTitle += " / " + tab.title
            check.report("cookies_blocked", tab.title == "cookie:blocked:absent")
            // GPC is on in the built-in record; read the navigation's and the fetch's header and
            // the API from the fixture.
            trace("reading the GPC signal on")
            openTab("/privacy?do=gpc&n=on")
            step(8)
        case 8:
            guard let tab = fixtureTab("/privacy?do=gpc&n=on"), !tab.isLoading,
                  tab.title.hasPrefix("gpc:") else { note("GPC fixture on"); return }
            check.privacyGPCTitle = tab.title
            check.report("gpc_on", tab.title == "gpc:1:1:api")
            trace("turning GPC off")
            probe.setGlobalPrivacyControl(false)
            step(9)
        case 9:
            guard probe.privacy.globalPrivacyControl == false else { note("GPC still on"); return }
            openTab("/privacy?do=gpc&n=off")
            step(10)
        case 10:
            guard let tab = fixtureTab("/privacy?do=gpc&n=off"), !tab.isLoading,
                  tab.title.hasPrefix("gpc:") else { note("GPC fixture off"); return }
            check.privacyGPCTitle += " / " + tab.title
            check.report("gpc_off", tab.title == "gpc:none:none:noapi")
            trace("reading the retention visits (seeded at +\(Int(check.privacySeedUptime ?? 0))s from launch)")
            step(11)
        case 11:
            // R2-1: the t0+30 s pass is at most 30 s after the seed (t0 <= seed), so 40 s leaves
            // ten seconds of margin and fits the run's ~90 s tick budget.
            if check.privacyRetentionTimedOut {
                check.privacyRetentionTimedOut = false
                end("retention_removes", false)
                return
            }
            guard !check.privacyPolling else { return }
            check.privacyPolling = true
            PrivacyCheckEngine.visitTimes(profile: check.websiteProfile, url: check.privacyTenDayVisitURL) { ten in
                guard check.phase == 11 else { check.privacyPolling = false; return }
                PrivacyCheckEngine.visitTimes(profile: check.websiteProfile, url: check.privacyTwoDayVisitURL) { two in
                    check.privacyPolling = false
                    guard check.phase == 11 else { return }
                    check.privacyLastTen = ten.count
                    check.privacyLastTwo = two.count
                    if ten.isEmpty && !two.isEmpty {
                        check.report("retention_removes", true)
                        check.report("retention_keeps", true)
                        trace("seeding the clear sheet's visits and cookie")
                        PrivacyCheckEngine.seedVisit(profile: check.websiteProfile, url: check.privacyRecentVisitURL, daysAgo: 0.014) { _ in }
                        PrivacyCheckEngine.seedVisit(profile: check.websiteProfile, url: check.privacyOlderVisitURL, daysAgo: 3) { _ in }
                        openPlainTab("/privacy?do=firstcookie")
                        step(12)
                        return
                    }
                    let elapsed = check.privacySeedTime.map { Date().timeIntervalSince($0) } ?? 0
                    if elapsed > 40 {
                        check.details["retention_wait"] = ["elapsed": Int(elapsed), "ten": ten.count,
                                                           "two": two.count,
                                                           "seed_offset": Int(check.privacySeedUptime ?? 0)]
                        check.report("retention_removes", false)
                        check.report("retention_keeps", false)
                        check.privacyRetentionTimedOut = true
                        return
                    }
                    note("expiry pass: ten=\(ten.count) two=\(two.count) seed+\(Int(elapsed))s")
                }
            }
        case 12:
            guard let tab = plainTab("/privacy?do=firstcookie"), !tab.isLoading,
                  tab.title == "clear:cookie" else { note("first-party cookie fixture"); return }
            trace("opening the clear sheet")
            probe.openClearSheet()
            step(13)
        case 13:
            let types = (0..<3).map { probe.sheetMarker(SettingsModel.privacySheetTypeMarker($0)) }
            let range = probe.sheetMarker(SettingsModel.privacySheetRangeMenuMarker)
            let profile = probe.sheetMarker(SettingsModel.privacySheetProfileMarker)
            let cancel = probe.sheetMarker(SettingsModel.privacySheetCancelMarker)
            let clear = probe.sheetMarker(SettingsModel.privacySheetClearMarker)
            guard probe.clearSheetVisible, probe.clearSheetShown,
                  types.allSatisfy({ $0 != nil }), range != nil, profile != nil,
                  cancel != nil, clear != nil else {
                note("sheet visible=\(probe.clearSheetVisible) shown=\(probe.clearSheetShown) types=\(types.map { $0 != nil })")
                return
            }
            check.privacySheetTitle = probe.clearSheetTitle ?? ""
            let titleFrame = probe.sheetMarker(SettingsModel.privacySheetTitleMarker)
            check.report("sheet_rows", titleFrame != nil && (titleFrame?.height ?? 0) > 0
                         && probe.privacyProfile == check.websiteProfile)
            check.report("sheet_range", probe.clearRange == .lastHour
                         && probe.clearTypes.contains(.history) && probe.clearTypes.contains(.cookies)
                         && probe.clearTypes.contains(.cache))
            // The sheet is its own window, so the capture names it rather than the Settings window.
            check.capturing = true
            let sheetImage = (owner.settings?.window?.attachedSheet).flatMap { sheet in
                promptScreenScreenshot(sheet, name: "\(check.mode.rawValue)-privacy-sheet", withoutShadow: true)
            }
            check.capturing = false
            if let sheetImage { check.images["privacy-sheet"] = sheetImage }
            check.conditions["capture"] = (check.conditions["capture"] ?? true) && sheetImage != nil
            guard sheetImage != nil else { end("capture", false); return }
            trace("clearing the last hour's history, cookies and cache")
            probe.setClearRange(.lastHour)
            probe.setClearTypes(.all)
            probe.confirmClearSheet()
            step(14)
        case 14:
            guard !probe.clearing, !probe.clearSheetShown, !probe.clearSheetVisible else {
                note("clear sheet still running shown=\(probe.clearSheetShown) clearing=\(probe.clearing)")
                return
            }
            guard !check.privacyClearPolling else { return }
            check.privacyClearPolling = true
            PrivacyCheckEngine.visitTimes(profile: check.websiteProfile, url: check.privacyRecentVisitURL) { recent in
                guard check.phase == 14 else { check.privacyClearPolling = false; return }
                PrivacyCheckEngine.visitTimes(profile: check.websiteProfile, url: check.privacyOlderVisitURL) { older in
                    check.privacyClearPolling = false
                    guard check.phase == 14 else { return }
                    check.privacyRecentGone = recent.isEmpty
                    check.privacyOlderKept = !older.isEmpty
                    check.report("sheet_clears_history", recent.isEmpty)
                    check.report("sheet_keeps_older_history", !older.isEmpty)
                    openPlainTab("/privacy?do=clear&n=after")
                    step(15)
                }
            }
        case 15:
            guard let tab = plainTab("/privacy?do=clear&n=after"), !tab.isLoading,
                  tab.title.hasPrefix("clear:") else { note("cookie read-back after Clear"); return }
            check.privacyClearCookieTitle = tab.title
            check.report("sheet_clears_cookie", tab.title == "clear:nocookie")
            trace("closing and reopening the settings window")
            // M4: the controller and model survive the close, so put a value the core does not hold
            // in the model; `reopen_reads_record` can then only pass on a read that answered.
            probe.resetPrivacyForRead()
            owner.settings?.window?.performClose(nil)
            step(16)
        case 16:
            guard owner.settings?.window?.isVisible != true else { note("settings window still visible"); return }
            owner.settings?.checkOpen(paneID: "privacy", shownSpaceID: snapshot.shownSpaceId)
            step(17)
        case 17:
            guard probe.isVisible, probe.pageID == "privacy", probe.privacyLoaded else {
                note("reopened on \(probe.pageID) visible=\(probe.isVisible) loaded=\(probe.privacyLoaded)"); return
            }
            let stored = probe.privacy
            guard stored.thirdPartyCookies == .block, stored.globalPrivacyControl == false,
                  stored.historyRetention == .week else {
                note("reopened record: \(stored.thirdPartyCookies.label) gpc=\(stored.globalPrivacyControl) \(stored.historyRetention.label)")
                return
            }
            check.report("reopen_reads_record", true)
            trace("Privacy record read back")
            finish()
        default: break
        }
    }
}
