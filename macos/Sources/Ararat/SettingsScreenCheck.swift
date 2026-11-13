import AppKit
import AraratKit
import AraratUI

// U27a's settings screen checks: `--ararat-screen=settings-<pane>` opens the settings window on
// that pane and reads it through marker views and the model (the VM's accessibility tree is empty
// in process, as `SidebarChecks.swift` and `SiteControlsCheck.swift` say). One launch per pane
// keeps a failure attributable: the five built panes name their own rows, and `settings-frame` and
// `settings-search` cover the frame and the search's keyboard model.
@MainActor
final class SettingsScreenCheck {
    /// One mode per `--ararat-screen=` argument. The app's check mode is `screen-` plus the raw
    /// value, the form every check family uses, and `screenMode`/`mode` are the only two ways in.
    enum Mode: String, CaseIterable {
        case frame = "settings-frame"
        case search = "settings-search"
        case tabs = "settings-tabs"
        case shortcuts = "settings-shortcuts"
        case airTraffic = "settings-air-traffic"
        case appearance = "settings-appearance"
        case spaces = "settings-spaces"
        case littleWindow = "settings-little-window"

        /// The pane the window opens on. The frame and search checks both run on Tabs.
        var paneID: String {
            switch self {
            case .frame, .search, .tabs: "tabs"
            case .shortcuts, .airTraffic, .appearance, .spaces: String(rawValue.dropFirst("settings-".count))
            case .littleWindow: "little-window"
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
            case .tabs, .shortcuts, .airTraffic: ["rows"]
            case .appearance: ["rows", "new_tab_hidden", "new_tab_reopen", "tooltips_off", "look_to_space"]
            case .spaces: ["rows", "space_page", "scroll_card", "scroll_write_reopen", "scroll_wheel_natural", "scroll_wheel_reversed"]
            case .littleWindow: ["rows", "atc_link", "shortcut_recorder", "hot_key_registration",
                                 "open_in_write_reopen", "open_in_bar", "close_after_keeps", "remember_off_frame"]
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
    // A screenshot spins the run loop, so a tick that re-enters while one is in flight would
    // read a half-updated phase.
    var capturing = false
    // The last wait a phase described, so a stall names its condition in the trace and in the
    // timeout diagnostics without a second VM round.
    var lastWait = ""
    // The row a Return opens, recorded before the action, and the page the detail kept while a
    // query had no results.
    var expectedRowID = ""
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
    // U27d: the Today row the New Tab row's close-up is measured on, its frame before the switch,
    // and whether the header tooltip showed before the Tooltips switch was turned off.
    var appearanceTodayRow = ""
    var appearanceRowY: CGFloat = 0
    var appearanceTooltipShown = false
    // U27i: the Little Window check's page, destination space and the window whose Open in is
    // driven (kept after it closes so its handoff record stays readable).
    var littlePageURL = "data:text/html,<title>Little Window settings page</title>"
    var littleSpaceID = ""
    var littleSpaceTitle = ""
    var littlePageLive = ""
    var littlePageNavigation: UInt = 0
    var littleOpening: LittleWindowController?

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
                               values: ["conditions": check.conditions, "failed_conditions": failed, "images": check.images])
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
        case .frame:
            settingsFrameTick(probe, check: check, note: note, trace: trace, step: step, end: end, finish: finish, capture: capture, near: near)
        case .search:
            settingsSearchTick(probe, check: check, note: note, trace: trace, step: step, end: end, finish: finish, capture: capture, near: near)
        case .tabs, .shortcuts, .airTraffic, .spaces, .appearance, .littleWindow:
            if mode == .spaces, check.phase >= 4 {
                settingsSpacesScrollTick(probe, check: check, note: note, trace: trace, step: step,
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
            check.historyBefore = probe.historyIndex
            trace("return on \(check.expectedRowID)")
            _ = probe.searchKey(.return)
            step(6)
        case 6:
            guard !check.expectedRowID.isEmpty, probe.highlightedRowID == check.expectedRowID,
                  probe.marker(SettingsModel.rowMarker(check.expectedRowID)) != nil else {
                note("highlight \(probe.highlightedRowID ?? "-") want \(check.expectedRowID)"); return
            }
            check.report("return_opens", probe.historyIndex > check.historyBefore && probe.pageID == "shortcuts")
            probe.setQuery("Move to Space 9")
            step(7)
        case 7:
            guard probe.resultTitles.count == 1, probe.selectedIndex == 0 else {
                note("results for Move to Space 9: \(probe.resultTitles)"); return
            }
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
                  probe.pageID == "shortcuts" else {
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
                check.report("rows", rows.allSatisfy { $0.frame.height >= 54 })
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
            case .tabs:
                let markers = ["width", "archive-after"].map(SettingsModel.rowMarker)
                guard markers.allSatisfy({ probe.marker($0) != nil }) else {
                    note("rows missing: \(markers.filter { probe.marker($0) == nil })"); return
                }
                check.report("rows", true)
            case .airTraffic:
                let markers = [SettingsModel.airTrafficCardId, "atc-test"].map(SettingsModel.rowMarker)
                guard markers.allSatisfy({ probe.marker($0) != nil }) else {
                    note("rows missing: \(markers.filter { probe.marker($0) == nil })"); return
                }
                check.report("rows", true)
            // The frame and search modes have their own phase machines, and the appearance pane
            // has its own below; leaving them here keeps the pane switch total.
            case .frame, .search, .appearance, .littleWindow:
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
        default: break
        }
    }

    // MARK: settings-appearance, U27d: the switches and the Look row

    /// Phases 2 to 7 of `settings-appearance`: the pane's three rows; the New Tab row switch off
    /// hiding the row (the Today rows close up by its 41 pt) and the reopened window reading it
    /// back; the Tooltips switch off leaving a hovered header control silent; and the Look row
    /// pushing the shown space's page.
    private func settingsAppearanceTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                                        note: (String) -> Void, trace: (String) -> Void,
                                        step: (Int) -> Void, end: (String, Bool) -> Void,
                                        finish: () -> Void, capture: (String) -> Bool) {
        let owner = root ?? self
        switch check.phase {
        case 2:
            let markers = [SettingsModel.lookRowId, SettingsModel.newTabRowId, SettingsModel.tooltipsRowId]
                .map(SettingsModel.rowMarker)
            let rows = markers.map { probe.marker($0) }
            let switches = [SettingsModel.newTabRowSwitchMarker, SettingsModel.tooltipsSwitchMarker].map { probe.marker($0) }
            guard let look = rows[0], let newTab = rows[1], let tips = rows[2],
                  switches.allSatisfy({ $0 != nil }) else {
                note("appearance rows \(rows.map { $0 != nil }) switches \(switches.map { $0 != nil })")
                return
            }
            // The board's order: the Look link, then the Sidebar group's two switches.
            check.report("rows", look.maxY <= newTab.minY + 1 && newTab.maxY <= tips.minY + 1
                && switches.allSatisfy { ($0?.width ?? 0) > 0 && ($0?.height ?? 0) >= 16 })
            guard let today = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first?.id,
                  let before = sidebar?.checkRowFrame(today) else {
                note("no Today row to measure the New Tab row's close-up on"); return
            }
            check.appearanceTodayRow = today
            check.appearanceRowY = before.minY
            trace("New Tab row off, Today row at \(before.minY)")
            probe.setNewTabRowShown(false)
            step(3)
        case 3:
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
            step(4)
        case 4:
            guard owner.settings?.window?.isVisible != true else { note("the settings window is still visible"); return }
            trace("reopening the settings window")
            owner.settings?.checkOpen(paneID: "appearance", shownSpaceID: snapshot.shownSpaceId)
            step(5)
        case 5:
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
            step(6)
        case 6:
            guard probe.tooltipsShown == false else { note("the switch is still on"); return }
            let hidden = owner.container?.header.checkTooltip("back")
            trace("header tooltip off: \(hidden?.0 ?? "nil") \(hidden?.1 ?? [])")
            check.report("tooltips_off", check.appearanceTooltipShown && hidden?.0 == nil)
            trace("pushing the space page from the Look row")
            probe.openLook()
            step(7)
        case 7:
            guard let shown = snapshot.shownSpaceId, probe.pageID == "space-" + shown else {
                note("page after the Look row: \(probe.pageID), want space-\(snapshot.shownSpaceId ?? "-")"); return
            }
            check.report("look_to_space", probe.highlightedRowID == SettingsModel.lookRowId
                && probe.marker(SettingsModel.rowMarker(SettingsModel.lookRowId)) != nil)
            guard capture("appearance") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-spaces, U27c: the direction card's write, and both wheels

    /// Sends a sideways wheel to the sidebar the way a trackball does. The pipeline judges a
    /// wheel after cancelling the system's natural-scrolling inversion, so a machine with
    /// natural scrolling on gets the inverse CGEvent and lands on the same delta.
    @discardableResult
    func settingsSpacesSendWheel() -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -5, wheel3: 0),
              var input = NSEvent(cgEvent: event) else { return false }
        if input.isDirectionInvertedFromDevice,
           let inverse = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 5, wheel3: 0),
           let corrected = NSEvent(cgEvent: inverse) { input = corrected }
        FileHandle.standardError.write(Data("ararat-trace: settings-spaces send wheel\n".utf8))
        sidebar?.scrollWheel(with: input)
        return true
    }

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
            // The reopened window's card shows the value the record kept.
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
}
