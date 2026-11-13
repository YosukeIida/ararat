import AppKit
import AraratKit
import AraratUI

// U27a's settings screen checks: `--ararat-screen=settings-<pane>` opens the settings window on
// that pane and reads it through marker views and the model (the VM has no accessibility tree in
// process, `docs/HANDOVER.md:251`). One launch per pane keeps a failure attributable: the four
// built panes name their own rows, and `settings-frame` and `settings-search` cover the frame
// and the search's keyboard model.
@MainActor
final class SettingsScreenCheck {
    enum Mode: String, CaseIterable {
        case frame = "settings-frame"
        case search = "settings-search"
        case tabs = "settings-tabs"
        case shortcuts = "settings-shortcuts"
        case airTraffic = "settings-airtraffic"
        case spaces = "settings-spaces"

        /// The pane the window opens on. The frame and search checks both run on Tabs.
        var paneID: String {
            switch self {
            case .frame, .search, .tabs: "tabs"
            case .shortcuts: "shortcuts"
            case .airTraffic: "air-traffic"
            case .spaces: "spaces"
            }
        }

        var ledger: [String] {
            switch self {
            case .frame: ["cards", "header_fade", "search_replaces_rail", "grouping", "no_results"]
            case .search: ["first_selected", "arrow_moves", "return_opens", "hit_look", "hit_scrolled", "highlight_stays"]
            case .tabs, .shortcuts, .airTraffic: ["rows"]
            case .spaces: ["rows", "space_page"]
            }
        }

        /// The screen name maps to the mode (`--ararat-screen=settings-tabs`); the hidden
        /// variant is not built, because every condition reads the visible window.
        static func mode(_ name: String) -> Mode? {
            name.hasPrefix("screen-") ? Mode(rawValue: String(name.dropFirst("screen-".count))) : nil
        }
    }

    /// Every check reads the frame first, then its own pane (or the search).
    static let common = ["window_open", "window_size", "rail_width", "pane_rows", "header", "title"]

    static func conditionNames(_ mode: Mode, screen: Bool) -> [String] {
        common + mode.ledger + (screen ? ["capture"] : [])
    }

    static func conditionResults(_ conditions: [String: Bool], mode: Mode, screen: Bool) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(mode, screen: screen)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                names.filter { conditions[$0] != true })
    }

    var mode: Mode = .frame
    var phase = 0
    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
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
    // The selection before an arrow moved it, so the check can see it moved rather than stayed.
    // The history length before a Return, so the check can tell the page was pushed.
    var historyBefore = -1

    func report(_ name: String, _ ok: Bool) {
        conditions[name] = ok
        if let data = try? JSONSerialization.data(withJSONObject: ["check": mode.rawValue, "phase": name, "ok": ok], options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}

extension Runtime {
    func settingsCheckDiagnostics(mode: String, screen: Bool) -> [String: Any] {
        guard let check = settingsCheck, let mode = SettingsScreenCheck.Mode.mode(mode) else { return ["phase": browserCheckPhase] }
        let result = SettingsScreenCheck.conditionResults(check.conditions, mode: mode, screen: screen)
        let probe = (root ?? self).settings?.checkProbe()
        var values: [String: Any] = [
            "check": mode.rawValue, "screen": mode.rawValue,
            "conditions": result.values, "failed_conditions": result.failed,
            "phase": check.phase, "attempts": browserCheckAttempts, "last_wait": check.lastWait,
            "images": check.images, "expected_row": check.expectedRowID,
            "settings_owner": (root ?? self).settingsOwner != nil,
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
            values["markers"] = probe.markers(prefix: "").map { ["id": $0.id, "frame": rectFields($0.frame)] }
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
            if !ok { finishBrowserCheck(ok: false, values: settingsCheckDiagnostics(mode: screenName, screen: true)) }
            else { step(check.phase + 1) }
        }
        func finish() {
            let failed = SettingsScreenCheck.conditionNames(mode, screen: true).filter { check.conditions[$0] != true }
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
        case .tabs, .shortcuts, .airTraffic, .spaces:
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
            guard !probe.noResults else { note("query not cleared"); return }
            check.report("no_results", check.noResultsShown && probe.pageID == check.pageWithoutResults
                && probe.marker(SettingsModel.noResultsMarker) == nil)
            guard capture("frame") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-search

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
                && probe.selectedResultTitle == probe.resultTitles.first)
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
            check.report("arrow_moves", true)
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
            check.report("hit_scrolled", offset > 300)
            // Outside the 3 pt fill but inside the card, then inside the fill: the two greys
            // differ, which is the inset render D7 asks for rather than a whole-card fill.
            check.report("hit_look", row.height >= SettingsMetrics.hitRowHeight
                && abs((greys[0] ?? 0) - (greys[1] ?? 0)) > 10)
            check.report("highlight_stays", probe.marker(SettingsModel.rowMarker(id)) != nil)
            guard capture("search") else { end("capture", false); return }
            finish()
        default: break
        }
    }

    // MARK: settings-tabs, settings-shortcuts, settings-airtraffic, settings-spaces

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
                check.report("rows", rows.count == probe.spaceIDs.count
                    && zip(rows, rows.dropFirst()).allSatisfy { $0.frame.minY < $1.frame.minY })
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
            default:
                check.report("rows", false)
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
            check.report("space_page", probe.canGoBack)
            guard capture("space-page") else { end("capture", false); return }
            finish()
        default: break
        }
    }
}
