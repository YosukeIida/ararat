import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

// The empty folder's "No tabs" marker, as the sidebar reports it (SidebarView.noTabsRowsForCheck).
typealias NoTabsMarker = (id: String, parent: String, frame: NSRect, text: NSRect, height: CGFloat,
                          fontSize: CGFloat, lineHeight: CGFloat, cellHeight: CGFloat)

// A-Folders: the "No tabs" text sits at the child indent in the sidebar's secondary font,
// centred in the 24 pt row. The tolerances are a point, not a half: the frame's height comes
// from the field's cell and the font metrics round differently on other backing scales.
// Returned beside the verdict so a failing run prints the numbers instead of a bare false.
@MainActor
func noTabsTextVerdict(_ marker: NoTabsMarker, depth: UInt32, secondarySize: CGFloat = 12) -> (ok: Bool, detail: String) {
    let expectedX = 8 + 10 + 16 * CGFloat(depth + 1)
    let x = marker.text.minX - expectedX
    let heightGap = marker.text.height - marker.cellHeight
    let centre = marker.text.midY - marker.frame.midY
    let ok = abs(x) <= 1 && abs(marker.fontSize - secondarySize) <= 0.01 && abs(heightGap) <= 1
        && abs(centre) <= 1 && abs(marker.height - 24) <= 0.5
    func n(_ value: CGFloat) -> String { String(format: "%.2f", value) }
    let detail = "text=\(n(marker.text.minX)),\(n(marker.text.minY)) \(n(marker.text.width))x\(n(marker.text.height))"
        + " wantX=\(n(expectedX)) dx=\(n(x)) size=\(n(marker.fontSize)) cellH=\(n(marker.cellHeight))"
        + " heightGap=\(n(heightGap)) lineH=\(n(marker.lineHeight)) midY=\(n(marker.text.midY))"
        + " rowMidY=\(n(marker.frame.midY)) centreGap=\(n(centre)) rowH=\(n(marker.height))"
        + " depth=\(depth) id=\(marker.id)"
    return (ok, detail)
}

// p4checks: an NSAlert sheet's own button, pressed through the control a person clicks. The
// sheets the app shows (folder and space deletion) carry the alert's buttons in its content view.
@MainActor
func pressSheetButton(_ sheet: NSWindow, title: String) -> Bool {
    func candidates(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(candidates) }
    let roots = [sheet.contentView, (sheet.contentViewController?.view)].compactMap { $0 }
    for root in roots {
        if let button = candidates(root).compactMap({ $0 as? NSButton }).first(where: {
            $0.title == title && !$0.isHidden && $0.isEnabled
        }) {
            button.performClick(nil)
            return true
        }
    }
    return false
}

// U25b part 2's checks: rows, folders, Today and the space name row. One class holds the
// phase, the named conditions and the images; each mode is a small phase machine driven from
// the app's check tick. The VM has an empty accessibility tree, so every condition reads the
// view tree or the core's snapshot, never the AX API.
@MainActor
final class SidebarCheck {
    enum Mode: String {
        case rows = "sidebar-rows"
        case folderEmpty = "folder-empty"
        case today = "today"
        case spaceName = "space-name"

        var screen: String { "screen-\(rawValue)" }
    }

    var mode: Mode = .rows
    var phase = 0
    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    /// p4checks: readings that are not conditions (the create page's selection precondition).
    var details: [String: Any] = [:]
    // Set around a screenshot: screencapture waits by spinning the run loop, so a tick would
    // otherwise re-enter while the capture is in flight.
    var capturing = false
    // Rows seen before a step, so a created row can be told apart by id.
    var seen: Set<String> = []
    // The last wait a phase described, so a stall names its condition in the trace and in
    // the timeout diagnostics without a second VM round.
    var lastWait = ""
    // The unloaded pin the rows check archives: it leaves the sidebar's lists, so its id is
    // read once while the row exists.
    var unloadedPinId = ""
    // The Today tab the rows check archives, recorded for the same reason.
    var todayArchiveId = ""
    // The Today tab ⌘W closes, which leaves the list too.
    var commandWId = ""
    // The Today tab the unread fixture navigates: its seeded url is gone after the
    // navigation, so the later phases read this id instead of the row's url suffix.
    var unreadId = ""
    var statusId = ""
    var statusNavigationCount: UInt = 0
    // folder-empty's delete: the folder and the tab inside it, read before they leave.
    var deletedFolder = ""
    var deletedFolderTab = ""
    // space-name's create and rename: the count before, the new space, the rename title, and
    // whether a row was selected before the create page opened.
    var spacesBefore = 0
    var newSpaceID = ""
    var renamedTitle = ""
    var selectionReady = false
    var cancelDialogCount: UInt = 0
    var clearRequestedClose = false
    var stayRowOrder: [String] = []
    var clearSplitId = ""

    static func conditionNames(mode: Mode, screen: Bool) -> [String] {
        let base: [String]
        switch mode {
        case .rows:
            base = ["rows_present", "loaded_pin_close", "unloaded_pin_archive", "today_archive",
                    "command_w_current", "close_caps_current", "empty_folder_line", "crashed_glyph", "unread_dot", "loading_spinner", "mute_round_trip"]
        case .folderEmpty:
            base = ["line_frame", "line_absent_with_tabs", "line_absent_collapsed", "line_drop",
                    "delete_row_menu", "delete_sheet", "delete_accept", "delete_removed"]
        case .today:
            base = ["divider_visible", "divider_frame", "clear_present", "new_tab_row",
                    "clear_archives", "divider_hidden_without_today", "new_tab_setting_hides",
                    "name_drop_pins", "new_tab_row_press", "beforeunload_stay_keeps_row",
                    "clear_today_stay_keeps_only_refused_row", "clear_today_stay_keeps_one_pane_split",
                    "divider_back_after_stay", "clear_after_stay_without_close_motion"]
        case .spaceName:
            base = ["name_x", "chevron_hover", "name_x_hover", "name_x_collapsed", "click_toggles",
                    "menu_items", "menu_dock_same", "rename_menu_only", "rename_field_height", "look_anchor",
                    "create_page", "create_page_selection", "create_landed", "create_page_closed",
                    "create_space_shown", "create_dock_cell", "rename_commits"]
        }
        return base + (screen ? ["capture"] : [])
    }

    static func conditionResults(_ conditions: [String: Bool], mode: Mode, screen: Bool) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(mode: mode, screen: screen)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                names.filter { conditions[$0] != true })
    }

    func report(_ name: String, _ ok: Bool) {
        conditions[name] = ok
        if let data = try? JSONSerialization.data(withJSONObject: ["check": mode.rawValue, "phase": name, "ok": ok], options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}

extension Runtime {
    func sidebarCheckMode(_ mode: String) -> SidebarCheck.Mode? {
        switch mode {
        case "sidebar-rows", "screen-sidebar-rows": return .rows
        case "folder-empty", "screen-folder-empty": return .folderEmpty
        case "today", "screen-today": return .today
        case "space-name", "screen-space-name": return .spaceName
        default: return nil
        }
    }

    func sidebarCheckDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(sidebarCheckDescendants) }

    func sidebarCheckShownSpace() -> SpaceSnapshot? {
        snapshot.spaces.first { $0.id == snapshot.shownSpaceId }
    }

    func sidebarCheckRow(_ space: SpaceSnapshot?, _ suffix: String) -> Row? {
        guard let space else { return nil }
        // Folders carry no URL, so the seed ids answer for them too.
        return (space.today + space.pinned + space.favorites).first {
            $0.id == "sidebar-\(suffix)" || $0.url?.hasSuffix("?sidebar-\(suffix)") == true
        }
    }

    func sidebarCheckCore() -> WorkspaceSnapshot? {
        guard let store = adapter?.session.store else { return nil }
        return adapter?.session.queue.sync { store.snapshot(windowId: windowID) }
    }

    func sidebarCheckDiagnostics(mode: String, screen: Bool) -> [String: Any] {
        guard let check = sidebarCheck, let mode = sidebarCheckMode(mode) else { return ["phase": browserCheckPhase] }
        let result = SidebarCheck.conditionResults(check.conditions, mode: mode, screen: screen)
        let space = sidebarCheckShownSpace()
        return ["check": mode.rawValue, "conditions": result.values, "failed_conditions": result.failed,
                "phase": check.phase, "capturing": check.capturing, "images": check.images,
                "details": check.details,
                "attempts": browserCheckAttempts, "last_wait": check.lastWait,
                "rows": sidebar?.rowCheckIds.sorted() ?? [],
                "selected": snapshot.selectedId as Any? ?? NSNull(),
                "space_rows": space.map { ($0.today + $0.pinned + $0.favorites).map { row in
                    ["id": row.id, "title": row.title, "parent": row.parentId, "kind": String(describing: row.kind),
                     "unloaded": row.unloaded, "depth": row.depth] as [String: Any] } } ?? [],
                "crash_items": adapter?.crashedItems.sorted() ?? [],
                "name_frames": sidebar.map { view in
                    view.layoutSubtreeIfNeeded()
                    let name = view.spaceNameRow
                    return ["name": rectFields(view.convert(name.checkNameFrame, from: name.superview)),
                            "row": rectFields(name.frame), "sidebar_width": view.bounds.width] as [String: Any]
                } ?? [:],
                "divider_frames": sidebar?.todayDividerForCheck.map { divider in
                    ["frame": rectFields(divider.frame), "line": rectFields(divider.line), "clear": rectFields(divider.clear),
                     "sidebar_width": sidebar?.bounds.width ?? 0] as [String: Any]
                } ?? [:],
                "core_archive": sidebarCheckCore()?.archive.map(\.id).sorted() ?? [],
                "no_tabs": sidebar?.noTabsRowsForCheck.map { marker in
                    let depth = space?.pinned.first { $0.id == marker.parent }?.depth ?? 0
                    var fields: [String: Any] = rectFields(marker.text)
                    fields["x_expected"] = 8 + 10 + 16 * CGFloat(depth + 1)
                    fields["font_size"] = Double(marker.fontSize)
                    fields["line_height"] = Double(marker.lineHeight)
                    fields["cell_height"] = Double(marker.cellHeight)
                    fields["row_height"] = Double(marker.height)
                    fields["row_mid_y"] = Double(marker.frame.midY)
                    fields["parent"] = marker.parent
                    return fields
                } ?? [],
                "has_browser": host?.hasBrowser() ?? false,
                "tabs": host?.tabs().count ?? 0]
    }

    func sidebarCheckTick(_ host: any ARWindowHostAPI, screen: Bool, mode: String) {
        guard let mode = sidebarCheckMode(mode) else { return }
        if sidebarCheck == nil { sidebarCheck = SidebarCheck() }
        guard let check = sidebarCheck, check.mode == mode || check.phase == 0, let sidebar else { return }
        if check.mode != mode { check.mode = mode }
        // A screenshot spins the run loop; a tick that re-enters while one is in flight would
        // read a half-updated phase.
        guard !check.capturing else { return }
        func trace(_ name: String) {
            FileHandle.standardError.write(Data("ararat-trace: \(mode.rawValue) phase \(check.phase) \(name)\n".utf8))
        }
        func step(_ next: Int) { check.phase = next; browserCheckPhase = next }
        func finish() {
            let failed = SidebarCheck.conditionNames(mode: mode, screen: screen).filter { check.conditions[$0] != true }
            finishBrowserCheck(ok: failed.isEmpty,
                               values: ["conditions": check.conditions, "failed_conditions": failed, "images": check.images])
        }
        func waitNote(_ text: @autoclosure () -> String) {
            let now = text()
            if check.lastWait != now || browserCheckAttempts % 30 == 0 {
                check.lastWait = now
                FileHandle.standardError.write(Data("ararat-trace: \(mode.rawValue) wait phase \(check.phase): \(now)\n".utf8))
            }
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            trace("capture \(name)")
            check.capturing = true
            let path = promptScreenScreenshot(host.window(), name: "\(mode.rawValue)-\(name)", withoutShadow: true)
            check.capturing = false
            if let path { check.images[name] = path }
            // The screen variants report a single capture condition for all of their images.
            check.conditions["capture"] = (check.conditions["capture"] ?? true) && path != nil
            return path != nil
        }
        func click(_ view: NSView, at point: NSPoint) -> Bool {
            guard let window = view.window else { return false }
            let location = view.convert(point, to: nil)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 0) else { return false }
            // A control that tracks must see the up after the down is delivered.
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
            return true
        }
        func rows(_ id: String) -> Row? {
            sidebarCheckRow(sidebarCheckShownSpace(), id)
        }
        switch mode {
        case .rows: sidebarRowsTickPhase(host, screen: screen, check: check, note: { waitNote($0) }, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows)
        case .folderEmpty: folderEmptyTickPhase(screen: screen, check: check, note: { waitNote($0) }, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows)
        case .today: todayTickPhase(host, screen: screen, check: check, note: { waitNote($0) }, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows, answerDialog: { self.clickScreenDialog(stay: $0) })
        case .spaceName: spaceNameTickPhase(screen: screen, check: check, note: { waitNote($0) }, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows)
        }
    }

    // MARK: sidebar-rows (R1/R2/R5/R7/F3/F4)

    func sidebarRowsTickPhase(_ host: any ARWindowHostAPI, screen: Bool, check: SidebarCheck, note: (String) -> Void, trace: (String) -> Void,
                              step: (Int) -> Void, finish: () -> Void, capture: (String) -> Bool,
                              click: (NSView, NSPoint) -> Bool, row: (String) -> Row?) {
        guard let sidebar else { return }
        // Why the first phases select seeded rows: the engine only opens a native tab for a
        // row the app selects, and the core unloads every open row the first transaction does
        // not carry — the same slice-seed shape U26b fixed.
        func liveTab(_ id: String) -> Bool {
            (host.tabs() as? [any ARTabAPI])?.contains { $0.itemId == id } == true
        }
        // The row's ✕ button only exists on hover, which a VM check cannot do: press the same
        // rule and callbacks the button runs, and trace the action it resolved.
        func pressClose(_ id: String) -> Bool {
            let action = sidebar.pressRowCloseForCheck(id: id)
            let name = action.map { $0 == .archive ? "archive" : "close" } ?? "no target"
            trace("press close for \(id): \(name)")
            if action == nil { note("no close target for \(id)") }
            return action != nil
        }
        switch check.phase {
        case 0:
            let space = sidebarCheckShownSpace()
            let needed = ["today-a", "today-b", "today-c", "pin", "pin-off", "folder-tab", "empty", "folder"]
            let rowIDs = Set(sidebar.rowCheckIds)
            guard let space,
                  needed.allSatisfy({ suffix in sidebarCheckRow(space, suffix).map { rowIDs.contains($0.id) } == true }) else {
                note("rows missing: \(needed.filter { suffix in !(sidebarCheckShownSpace().flatMap { sidebarCheckRow($0, suffix) }.map { rowIDs.contains($0.id) } ?? false) })")
                return
            }
            check.report("rows_present", true)
            guard let pin = row("pin") else { return }
            trace("open the pin's native tab")
            sidebar.selectRow(id: pin.id)
            step(1)
        case 1:
            guard let pin = row("pin"), snapshot.selectedId == pin.id, liveTab(pin.id),
                  let todayA = row("today-a") else {
                let id = row("pin")?.id ?? "-"
                note("selected=\(snapshot.selectedId ?? "-") pin=\(id) live=\(liveTab(id)) today-a=\(row("today-a")?.id ?? "-")")
                return
            }
            trace("open a Today tab beside it")
            sidebar.selectRow(id: todayA.id)
            step(2)
        case 2:
            guard let todayA = row("today-a"), let pin = row("pin") else {
                note("today-a or pin row missing"); return
            }
            let core = sidebarCheckCore()
            let corePin = core.flatMap { $0.spaces.flatMap(\.pinned).first(where: { $0.id == pin.id }) }
            let label = sidebar.rowCheckInfo(id: pin.id)?.closeLabel
            guard snapshot.selectedId == todayA.id, liveTab(todayA.id),
                  let info = sidebar.rowCheckInfo(id: pin.id), let corePin, !corePin.unloaded else {
                note("selected=\(snapshot.selectedId ?? "-") today-a=\(todayA.id) live=\(liveTab(todayA.id)) pin-unloaded=\(String(describing: corePin?.unloaded)) label=\(label ?? "-")")
                return
            }
            guard info.closeLabel == "Close Tab" else {
                note("pin label is \(info.closeLabel ?? "-"), expected Close Tab"); return
            }
            if screen {
                _ = capture("selected")
                let hover = sidebar.captureRowPointerState(id: pin.id, pressed: false) { capture("hover") }
                let pressed = sidebar.captureRowPointerState(id: pin.id, pressed: true) { capture("pressed") }
                check.conditions["capture"] = check.conditions["capture"] == true && hover && pressed
            }
            trace("press the loaded pin's close")
            let action = sidebar.pressRowCloseForCheck(id: pin.id)
            trace("close action for \(pin.id): \(action.map { $0 == .archive ? "archive" : "close" } ?? "no target")")
            check.report("loaded_pin_close", action != nil)
            if action != nil { step(3) } else { note("the close action did not fire: no close target for \(pin.id)") }
        case 3:
            guard let pin = row("pin") else { note("pin row gone"); return }
            let core = sidebarCheckCore()
            let corePin = core?.spaces.flatMap(\.pinned).first(where: { $0.id == pin.id })
            let live = (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == pin.id }?.liveId ?? "-"
            let archived = core?.archive.contains(where: { $0.id == pin.id }) ?? false
            guard let corePin, corePin.unloaded, !archived else {
                note("pin lifecycle=\(corePin.map(\.unloaded) == true ? "unloaded" : "loaded"), archived=\(archived), native live=\(live), tabs=\((host.tabs() as? [any ARTabAPI])?.count ?? 0)")
                return
            }
            guard let off = row("pin-off"), let info = sidebar.rowCheckInfo(id: off.id) else {
                note("pin-off row missing"); return
            }
            guard info.closeLabel == "Archive Tab" else { check.report("unloaded_pin_archive", false); finish(); return }
            trace("press the unloaded pin's close")
            check.unloadedPinId = off.id
            check.report("unloaded_pin_archive", pressClose(off.id))
            step(4)
        case 4:
            // The archived pin leaves pinned and the sidebar's lists, so the wait reads the
            // core through the id recorded at the press.
            guard let core = sidebarCheckCore() else { note("no core"); return }
            guard !check.unloadedPinId.isEmpty else { note("the unloaded pin id was not recorded"); return }
            guard !core.spaces.flatMap(\.pinned).contains(where: { $0.id == check.unloadedPinId }),
                  core.archive.contains(where: { $0.id == check.unloadedPinId }) else {
                note("pin-off still pinned=\(core.spaces.flatMap(\.pinned).contains { $0.id == check.unloadedPinId }) archived=\(core.archive.contains { $0.id == check.unloadedPinId })")
                return
            }
            guard let todayA = row("today-a"), let info = sidebar.rowCheckInfo(id: todayA.id), info.closeLabel == "Archive Tab" else {
                note("today-a label is \(row("today-a").flatMap { sidebar.rowCheckInfo(id: $0.id)?.closeLabel } ?? "-"), expected Archive Tab")
                return
            }
            trace("press a Today tab's close")
            check.todayArchiveId = todayA.id
            check.report("today_archive", pressClose(todayA.id))
            step(5)
        case 5:
            // The archived Today tab leaves the list, so the wait reads the core by id.
            guard let core = sidebarCheckCore() else { note("no core"); return }
            guard !check.todayArchiveId.isEmpty else { note("the Today tab id was not recorded"); return }
            guard !core.spaces.flatMap(\.today).contains(where: { $0.id == check.todayArchiveId }),
                  core.archive.contains(where: { $0.id == check.todayArchiveId }) else {
                note("today-a still in today=\(core.spaces.flatMap(\.today).contains { $0.id == check.todayArchiveId }) archived=\(core.archive.contains { $0.id == check.todayArchiveId })")
                return
            }
            // R2: ⌘W acts on the current tab and only its row shows the binding's caps.
            guard let todayB = row("today-b") else { note("today-b row missing"); return }
            if sidebar.selectedRowID != todayB.id {
                sidebar.selectRow(id: todayB.id)
                guard sidebar.selectedRowID == todayB.id else { note("today-b not selected: \(sidebar.selectedRowID ?? "-")"); return }
            }
            // ⌘W reads the core's selection, which is recorded when the engine answers the
            // selection command: press only once today-b is the core's current tab.
            let coreNow = sidebarCheckCore()
            let active = host.activeItemId()
            guard coreNow?.selectedId == todayB.id, liveTab(todayB.id) else {
                note("today-b waiting to be current: core=\(coreNow?.selectedId ?? "-") active=\(active ?? "-") live=\(liveTab(todayB.id))")
                return
            }
            let ready = sidebar.closeSelectedReadyForCheck
            trace("press ⌘W allowed=\(ready.allowed) selected=\(ready.selected ?? "-")")
            // R2: only the current row draws ⌘W's caps, and they follow the close_tab binding.
            let caps = sidebar.rowCheckInfo(id: todayB.id)?.closeCaps
            let bindingCaps = sidebar.closeBindingCapsForCheck
            guard let caps, !caps.isEmpty, caps == bindingCaps, sidebar.closeCapsForCheck == caps else {
                note("today-b caps=\(caps ?? []) binding=\(bindingCaps) current-row=\(sidebar.closeCapsForCheck ?? []) selected=\(sidebar.selectedRowID ?? "-")")
                return
            }
            check.report("close_caps_current", true)
            if screen {
                check.capturing = true
                let image = sidebar.tabMenuForCheck(id: todayB.id).flatMap { menu in
                    sidebar.rowFrameForCheck(todayB.id).flatMap { frame in
                        let point = sidebar.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)
                        return promptScreenMenuScreenshot(menu, window: host.window(), name: "sidebar-rows-tab-menu") {
                            menu.popUp(positioning: nil, at: point, in: sidebar)
                        }
                    }
                }
                check.capturing = false
                check.images["tab-menu"] = image
                check.conditions["capture"] = check.conditions["capture"] == true && image != nil
            }
            check.commandWId = todayB.id
            sidebar.closeSelectedTab(nil)
            step(6)
        case 6:
            // ⌘W archives the selected Today tab, which then leaves the list: read the core by id.
            guard let core = sidebarCheckCore() else { note("no core"); return }
            guard !check.commandWId.isEmpty else { note("the ⌘W tab id was not recorded"); return }
            guard core.archive.contains(where: { $0.id == check.commandWId }) else {
                note("⌘W has not archived \(check.commandWId) yet: core selected=\(core.selectedId ?? "-") archive=\(core.archive.map(\.id))")
                return
            }
            check.report("command_w_current", true)
            // F3: the open, empty folder shows its "No tabs" text at the child indent.
            guard let empty = row("empty"), let marker = sidebar.noTabsRowsForCheck.first(where: { $0.parent == empty.id }) else {
                check.report("empty_folder_line", false); step(7); return
            }
            let folderDepth = (sidebarCheckShownSpace()?.pinned ?? []).first { $0.id == empty.id }?.depth ?? 0
            let verdict = noTabsTextVerdict(marker, depth: folderDepth)
            trace("no tabs \(verdict.detail)")
            check.report("empty_folder_line", verdict.ok)
            _ = capture("line")
            trace("empty folder line")
            step(7)
        case 7:
            // R7 needs a loaded tab the window is not showing, with a title that changes while
            // it is hidden. Open a seeded Today row instead of asking the engine for a new
            // background tab: by this phase the check has closed every native tab, so the
            // window has no browser and checkNavigate would return without creating one
            // (ararat_window_host.mm checkNavigate's browser_ gate).
            guard let todayC = row("today-c") else { note("today-c row missing"); return }
            trace("unread fixture: open today-c")
            check.unreadId = todayC.id
            sidebar.selectRow(id: todayC.id)
            step(8)
        case 8:
            // The id is read once: the navigation below replaces the row's seeded url, so a
            // later lookup by url suffix would miss it.
            guard !check.unreadId.isEmpty else { note("the unread row id was not recorded"); return }
            guard snapshot.selectedId == check.unreadId, host.activeItemId() == check.unreadId,
                  liveTab(check.unreadId) else {
                note("today-c not current yet for the title fixture: snapshot=\(snapshot.selectedId ?? "-") host=\(host.activeItemId() ?? "-") live=\(liveTab(check.unreadId))")
                return
            }
            guard host.hasBrowser() else {
                note("no browser to navigate today-c: host.hasBrowser() is false")
                return
            }
            // The page's title changes 300 ms after it loads; the pin takes the window first, so
            // the change lands on a background tab. (A crashed contents would not navigate.)
            trace("unread fixture: navigate today-c, then hide it behind the pin")
            host.checkNavigate("data:text/html,<title>Unread</title><script>setTimeout(function(){document.title='Unread changed'},300)</script>",
                               disposition: "current")
            guard let pin = row("pin") else { note("pin row missing for the unread fixture"); return }
            sidebar.selectRow(id: pin.id)
            step(9)
        case 9:
            guard !check.unreadId.isEmpty else { note("the unread row id was not recorded"); return }
            guard sidebar.rowCheckInfo(id: check.unreadId)?.unreadDot == true else {
                note("no unread dot yet on \(check.unreadId): selected=\(sidebar.selectedRowID ?? "-") active=\(host.activeItemId() ?? "-") dot=\(String(describing: sidebar.rowCheckInfo(id: check.unreadId)?.unreadDot)) tabs=\((host.tabs() as? [any ARTabAPI])?.map(\.itemId) ?? [])")
                return
            }
            check.report("unread_dot", true)
            _ = capture("unread")
            sidebar.selectRow(id: check.unreadId)
            step(10)
        case 10:
            guard !check.unreadId.isEmpty else { note("the unread row id was not recorded"); return }
            guard sidebar.rowCheckInfo(id: check.unreadId)?.unreadDot == false else {
                note("unread dot not cleared yet on \(check.unreadId)"); return
            }
            // R5: a crashed renderer's row draws the warning glyph at 45 %.
            guard snapshot.selectedId == check.unreadId, host.activeItemId() == check.unreadId,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.unreadId }) else {
                note("today-c not active yet for the crash: snapshot=\(snapshot.selectedId ?? "-") host=\(host.activeItemId() ?? "-") tabs=\((host.tabs() as? [any ARTabAPI])?.map(\.itemId) ?? [])")
                return
            }
            trace("crash the renderer")
            guard tab.checkCrashRenderer() else {
                // The engine's gate refuses a crash for modes it does not know; say so rather
                // than finishing with a bare false.
                check.report("crashed_glyph", false)
                trace("crash refused for \(check.unreadId)")
                finish()
                return
            }
            step(11)
        case 11:
            guard let info = sidebar.rowCheckInfo(id: check.unreadId),
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.unreadId }), tab.crashed else {
                let tab = (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == check.unreadId }
                note("today-c not crashed yet: tab crashed=\(tab?.crashed ?? false) crashedItems=\(adapter?.crashedItems.sorted() ?? []) icon=\(sidebar.rowCheckInfo(id: check.unreadId)?.iconDescription ?? "-") opacity=\(sidebar.rowCheckInfo(id: check.unreadId)?.opacity ?? -1)")
                return
            }
            guard info.iconDescription == "Crashed", abs(info.opacity - 0.45) < 0.01 else {
                note("crashed glyph is \(info.iconDescription ?? "-") at \(info.opacity), crashedItems=\(adapter?.crashedItems.sorted() ?? [])"); return
            }
            check.report("crashed_glyph", true)
            _ = capture("crashed")
            _ = capture("rows")
            guard let pin = row("pin") else { note("pin missing for loading fixture"); return }
            check.statusId = pin.id
            trace("select pin for pending page")
            sidebar.selectRow(id: pin.id)
            step(12)
        case 12:
            guard let port = promptFixturePort, host.activeItemId() == check.statusId,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.statusId }),
                  sidebar.rowCheckInfo(id: check.statusId)?.loading == false else {
                note("waiting for selected pin and non-loading baseline on \(check.statusId)"); return
            }
            check.statusNavigationCount = tab.navigationCount
            trace("navigate pin to pending loopback page")
            host.checkNavigate("http://127.0.0.1:\(port)/pending", disposition: "current")
            step(13)
        case 13:
            guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.statusId }),
                  tab.url.hasSuffix("/pending"), tab.navigationCount > check.statusNavigationCount,
                  sidebar.rowCheckInfo(id: check.statusId)?.loading == true else {
                note("waiting for committed /pending and spinner on \(check.statusId)"); return
            }
            check.report("loading_spinner", true)
            _ = capture("loading")
            adapter?.setMuted(true, item: check.statusId)
            step(14)
        case 14:
            guard adapter?.rowStates[check.statusId]?.muted == true,
                  adapter?.rowStates[check.statusId]?.loading == true,
                  sidebar.rowCheckInfo(id: check.statusId)?.audioLabel == "Unmute Tab",
                  let port = promptFixturePort,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.statusId }) else {
                note("waiting for muted strip and speaker on a still-loading /pending on \(check.statusId): loading=\(adapter?.rowStates[check.statusId].map { "\($0.loading)" } ?? "-") muted=\(adapter?.rowStates[check.statusId].map { "\($0.muted)" } ?? "-") label=\(sidebar.rowCheckInfo(id: check.statusId)?.audioLabel ?? "-")")
                return
            }
            _ = capture("muted")
            check.statusNavigationCount = tab.navigationCount
            trace("navigate muted pin across documents")
            host.checkNavigate("http://127.0.0.1:\(port)/keyboard", disposition: "current")
            step(15)
        case 15:
            // `rowStates` is replaced wholesale by each applied transaction (EngineAdapter.swift:
            // 1122-1124), so a tick between `navigationFinished` and that delivery reads the new
            // `tab.url` beside the old `muted == true` and passes even when M1 has regressed.
            // Waiting for `loading == false` closes that window: /pending never finishes its body
            // (PromptFixtureServer holds the connection), so the strip is still loading when the
            // check navigates away, and only /keyboard's own load stop turns the spinner off —
            // after the commit whose PrimaryPageChanged is where a regressed M1 unmutes. The store
            // snapshot row cannot be the barrier: this row is a pin, and the core refreshes URL
            // metadata for Today rows only (live.rs:710). Reading the tab's mute needs a getter
            // ARTab lacks, and this unit takes no engine change.
            let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == check.statusId })
            let state = adapter?.rowStates[check.statusId]
            guard let tab,
                  tab.url.hasSuffix("/keyboard"), tab.navigationCount > check.statusNavigationCount,
                  state?.loading == false, state?.muted == true,
                  sidebar.rowCheckInfo(id: check.statusId)?.audioLabel == "Unmute Tab" else {
                note("waiting for the applied /keyboard transaction with mute retained on \(check.statusId): tab=\(tab?.url ?? "-") count=\(tab?.navigationCount ?? 0)/after=\(check.statusNavigationCount) loading=\(state.map { "\($0.loading)" } ?? "-") muted=\(state.map { "\($0.muted)" } ?? "-") label=\(sidebar.rowCheckInfo(id: check.statusId)?.audioLabel ?? "-")")
                return
            }
            sidebar.pressRowAudioForCheck(id: check.statusId)
            step(16)
        case 16:
            guard adapter?.rowStates[check.statusId]?.muted == false,
                  sidebar.rowCheckInfo(id: check.statusId)?.audioLabel == nil else {
                note("waiting for speaker click to unmute \(check.statusId)"); return
            }
            check.report("mute_round_trip", true)
            trace("done")
            finish()
        default: break
        }
    }

    // MARK: folder-empty (F3)

    func folderEmptyTickPhase(screen: Bool, check: SidebarCheck, note: (String) -> Void, trace: (String) -> Void, step: (Int) -> Void,
                              finish: () -> Void, capture: (String) -> Bool, click: (NSView, NSPoint) -> Bool, row: (String) -> Row?) {
        guard let sidebar else { return }
        switch check.phase {
        case 0:
            guard let empty = row("empty"), let marker = sidebar.noTabsRowsForCheck.first(where: { $0.parent == empty.id }) else {
                note("empty folder or its marker missing: \(sidebar.noTabsRowsForCheck.map(\.parent))")
                return
            }
            let folderDepth = (sidebarCheckShownSpace()?.pinned ?? []).first { $0.id == empty.id }?.depth ?? 0
            let verdict = noTabsTextVerdict(marker, depth: folderDepth)
            trace("no tabs \(verdict.detail)")
            check.report("line_frame", verdict.ok)
            _ = capture("line")
            trace("line frame")
            step(1)
        case 1:
            guard let folder = row("folder") else { return }
            check.report("line_absent_with_tabs", sidebar.noTabsRowsForCheck.allSatisfy { $0.parent != folder.id })
            trace("collapse empty folder")
            if let store = adapter?.session.store {
                _ = adapter?.session.queue.sync { try? store.setFolderCollapsed(windowId: windowID, id: "sidebar-empty", collapsed: true) }
            }
            if let core = sidebarCheckCore() { sidebar.update(snapshot: core) }
            step(2)
        case 2:
            guard let empty = row("empty") else { return }
            check.report("line_absent_collapsed", sidebar.noTabsRowsForCheck.allSatisfy { $0.parent != empty.id })
            if let store = adapter?.session.store {
                _ = adapter?.session.queue.sync { try? store.setFolderCollapsed(windowId: windowID, id: "sidebar-empty", collapsed: false) }
            }
            if let core = sidebarCheckCore() { sidebar.update(snapshot: core) }
            step(3)
        case 3:
            guard let empty = row("empty"), let dragged = row("today-a"),
                  let marker = sidebar.noTabsRowsForCheck.first(where: { $0.parent == empty.id }),
                  let drop = sidebar.resolveDropForCheck(position: NSPoint(x: marker.frame.midX, y: marker.frame.midY), draggedID: dragged.id) else { return }
            check.report("line_drop", drop.kind == "folder" && drop.container == empty.id)
            _ = capture("drop")
            // p4checks: a folder that holds tabs is deleted from its row menu, and the sheet the
            // app asks first is answered with its own Delete Folder button.
            guard let folder = row("folder"), folder.kind == .folder else {
                check.report("delete_row_menu", false); finish(); return
            }
            check.deletedFolder = folder.id
            let children = (sidebarCheckShownSpace()?.pinned ?? []).filter { $0.parentId == folder.id }
            // The row is "delete a folder with tabs": without a tab inside, nothing proves the
            // sheet's archive rule and the condition is reported false rather than skipped.
            guard let tab = children.first(where: { $0.kind == .tab }) else {
                check.report("delete_row_menu", false); finish(); return
            }
            check.deletedFolderTab = tab.id
            let titles = sidebar.checkRowMenuTitles(id: folder.id)
            check.report("delete_row_menu", titles.contains("Delete"))
            trace("folder menu \(titles); delete \(folder.id) with \(children.count) children")
            guard sidebar.checkPerformRowMenuCommand(id: folder.id, title: "Delete") else {
                check.report("delete_sheet", false); finish(); return
            }
            step(4)
        case 4:
            guard let sheet = sidebar.window?.attachedSheet, sheet.isVisible else {
                note("the delete folder sheet has not opened"); return
            }
            check.report("delete_sheet", true)
            _ = capture("delete-sheet")
            trace("accept the delete sheet \(sheet.title)")
            guard pressSheetButton(sheet, title: "Delete Folder") else {
                note("the sheet has no Delete Folder button"); check.report("delete_accept", false); finish(); return
            }
            check.report("delete_accept", true)
            step(5)
        case 5:
            guard sidebar.window?.attachedSheet == nil else { note("the delete sheet has not closed"); return }
            guard let core = sidebarCheckCore() else { return }
            let gone = !core.spaces.flatMap(\.pinned).contains { $0.id == check.deletedFolder }
            let archived = core.archive.contains { $0.id == check.deletedFolderTab }
            let visible = !sidebar.rowCheckIds.contains(check.deletedFolder)
            check.report("delete_removed", gone && archived && visible)
            // p4checks: one screen image per phase that asserts something a person sees.
            _ = capture("deleted")
            trace("folder deleted gone=\(gone) archived=\(archived) visible=\(visible)")
            finish()
        default: break
        }
    }

    // MARK: today (T1–T4)

    func todayTickPhase(_ host: any ARWindowHostAPI, screen: Bool, check: SidebarCheck, note: (String) -> Void, trace: (String) -> Void,
                        step: (Int) -> Void, finish: () -> Void, capture: (String) -> Bool,
                        click: (NSView, NSPoint) -> Bool, row: (String) -> Row?, answerDialog: (Bool) -> Bool) {
        guard let sidebar else { return }
        switch check.phase {
        case 0:
            guard let space = sidebarCheckShownSpace(), !space.today.isEmpty,
                  let divider = sidebar.todayDividerForCheck else { return }
            let width = sidebar.bounds.width
            check.report("divider_visible", true)
            check.report("divider_frame", abs(divider.line.minX - 18) < 0.5
                         && abs(divider.line.maxX - (width - 80)) < 0.5
                         && abs(divider.frame.height - 16) < 0.5
                         && abs(divider.clear.maxX - (width - 16)) < 0.5)
            check.report("clear_present", divider.clear.height >= 24)
            check.report("new_tab_row", sidebar.newTabRowForCheck.map { abs($0.height - 41) < 0.5 } ?? false)
            _ = capture("today")
            trace("divider and new tab")
            step(1)
        case 1:
            // The mock's no-pins layout is about an empty pinned section, so the seed's pin
            // tabs and its two folders are removed through the core on the store's queue;
            // the next tick reads the section gone and the sidebar is refreshed from it.
            guard let shown = sidebarCheckShownSpace() else { return }
            if let store = adapter?.session.store {
                let remaining = adapter?.session.queue.sync { () -> Int in
                    let core = store.snapshot(windowId: windowID)
                    guard let pinned = core.spaces.first(where: { $0.id == shown.id })?.pinned else { return 0 }
                    for pin in pinned where pin.kind == .tab {
                        _ = try? store.archiveItem(windowId: windowID, id: pin.id)
                    }
                    // Folders first, deepest last: deleteFolder moves their tabs out, and the
                    // seed's folder tab goes with them.
                    for folder in pinned.filter({ $0.kind == .folder }).sorted(by: { $0.depth > $1.depth }) {
                        _ = try? store.deleteFolder(windowId: windowID, id: folder.id)
                    }
                    return core.spaces.first(where: { $0.id == shown.id })?.pinned.count ?? 0
                } ?? 0
                if let core = sidebarCheckCore() { sidebar.update(snapshot: core) }
                if remaining > 0 {
                    note("pinned still holds \(remaining) rows, waiting for an empty section")
                    return
                }
            }
            guard let core = sidebarCheckCore(), let fresh = core.spaces.first(where: { $0.id == shown.id }),
                  fresh.pinned.isEmpty else {
                let pinned = sidebarCheckCore()?.spaces.first { $0.id == shown.id }?.pinned.map(\.id) ?? []
                note("pinned still \(pinned)")
                return
            }
            guard let dragged = row("today-a") else { note("today-a row missing"); return }
            let rect = sidebar.convert(sidebar.spaceNameRow.bounds, from: sidebar.spaceNameRow)
            let point = CGPoint(x: rect.midX, y: sidebar.bounds.height - rect.midY)
            guard let drop = sidebar.resolveDropForCheck(position: point, draggedID: dragged.id),
                  drop.kind == "insert", drop.container == shown.pinnedId, drop.index == 0 else {
                note("drop is \(String(describing: sidebar.resolveDropForCheck(position: point, draggedID: dragged.id)))")
                check.report("name_drop_pins", false); step(2); return
            }
            workspace?.move(id: dragged.id, container: shown.pinnedId, index: 0, openFolder: false) { [weak self] result in
                if case .success(let snapshot) = result { self?.show(snapshot) }
            }
            step(2)
        case 2:
            guard let core = sidebarCheckCore(), let shown = sidebarCheckShownSpace(),
                  let pinned = core.spaces.first(where: { $0.id == shown.id })?.pinned,
                  pinned.count == 1, pinned.first?.url?.hasSuffix("?sidebar-today-a") == true else {
                let first = sidebarCheckCore()?.spaces.first { $0.id == sidebarCheckShownSpace()?.id }?.pinned.first?.url ?? "-"
                note("pinned first is \(first)")
                return
            }
            check.report("name_drop_pins", true)
            _ = capture("name-drop")
            // T4: the core setting hides the New Tab row.
            if let store = adapter?.session.store {
                _ = adapter?.session.queue.sync { try? store.setNewTabRowShown(windowId: windowID, shown: false) }
            }
            workspace?.newTabRowShown { [weak self] result in
                if case .success(let shown) = result { self?.sidebar?.newTabRowShown = shown }
            }
            step(3)
        case 3:
            guard sidebar.newTabRowForCheck == nil else { return }
            check.report("new_tab_setting_hides", true)
            _ = capture("new-tab-hidden")
            if let store = adapter?.session.store {
                _ = adapter?.session.queue.sync { try? store.setNewTabRowShown(windowId: windowID, shown: true) }
            }
            workspace?.newTabRowShown { [weak self] result in
                if case .success(let shown) = result { self?.sidebar?.newTabRowShown = shown }
            }
            step(4)
        case 4:
            guard sidebar.newTabRowForCheck != nil else { note("New Tab row still hidden"); return }
            // D6: Clear runs live_clear_today and closes the pages. One Today row is selected
            // first so Clear has a live tab to close, not only core rows to archive.
            guard let space = sidebarCheckShownSpace(), !space.today.isEmpty else { return }
            if let todayB = row("today-b") {
                if snapshot.selectedId != todayB.id { sidebar.selectRow(id: todayB.id); return }
                guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == todayB.id }),
                      !tab.isLoading, tab.navigationCount > 0 else { note("waiting for a native tab on \(todayB.id)"); return }
                tab.prepareCheckBeforeUnload()
                step(40)
            }
        case 40:
            guard let todayB = row("today-b"),
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == todayB.id }),
                  tab.checkHasBeforeUnload() else { return }
            check.commandWId = todayB.id
            check.stayRowOrder = sidebarCheckShownSpace()?.today.map(\.id) ?? []
            check.cancelDialogCount = host.checkDialogCount()
            if !screen { host.expectCheckDialogs(1) }
            sidebar.closeSelectedTab(nil)
            step(41)
        case 41:
            if screen && check.conditions["beforeunload_stay_keeps_row"] == nil {
                guard answerDialog(true) else { note("wait=command-w-stay-dialog"); return }
                trace("dialog=command-w answer=stay")
                check.conditions["beforeunload_stay_keeps_row"] = false
            }
            guard screen || host.checkDialogCount() > check.cancelDialogCount else { return }
            guard screen || host.checkDialogIntegrity() else { return }
            guard let core = sidebarCheckCore(), let space = core.spaces.first(where: { $0.id == core.shownSpaceId }),
                  space.today.contains(where: { $0.id == check.commandWId && !$0.unloaded }),
                  (host.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == check.commandWId }) == true else { return }
            check.report("beforeunload_stay_keeps_row", space.today.map(\.id) == check.stayRowOrder)
            guard let other = row("today-c") else { return }
            step(42)
            adapter?.makeSplit(dragged: other.id, target: check.commandWId, side: .right) { made in
                if !made { check.report("clear_today_stay_keeps_one_pane_split", false) }
            }
        case 42:
            guard let core = sidebarCheckCore(), let space = core.spaces.first(where: { $0.id == core.shownSpaceId }),
                  let split = adapter?.session.queue.sync(execute: { adapter?.session.store?.splitLayout(itemId: check.commandWId) }),
                  split.children.count == 2,
                  split.children.allSatisfy({ pane in (host.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == pane.id && !$0.isLoading }) == true }) else { return }
            check.clearSplitId = split.id
            let previous = adapter?.onRowClose
            adapter?.onRowClose = { id in
                check.clearRequestedClose = true
                previous?(id)
            }
            check.seen = Set(space.today.filter { $0.kind == .tab }.map(\.id))
            check.cancelDialogCount = host.checkDialogCount()
            if !screen { host.expectCheckDialogs(2) }
            trace("press Clear")
            guard sidebar.pressClearToday(trace: trace) else { check.report("clear_archives", false); step(5); return }
            step(43)
        case 43:
            if screen && check.conditions["clear_today_stay_keeps_only_refused_row"] == nil {
                guard answerDialog(true) else { note("wait=clear-stay-dialog"); return }
                trace("dialog=clear answer=stay")
                check.conditions["clear_today_stay_keeps_only_refused_row"] = false
                return
            }
            guard screen || (host.checkDialogCount() > check.cancelDialogCount && host.checkDialogIntegrity()) else { return }
            guard let core = sidebarCheckCore(), let space = core.spaces.first(where: { $0.id == core.shownSpaceId }),
                  space.today.filter({ $0.kind == .tab }).map(\.id) == [check.commandWId],
                  space.today.first(where: { $0.id == check.commandWId })?.unloaded == false,
                  (host.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == check.commandWId }) == true else { return }
            let others = check.seen.subtracting([check.commandWId])
            // Do not press from core state alone: its restore can precede main-queue delivery.
            let restoredRow = check.clearSplitId.isEmpty
                ? sidebar.rowCheckInfo(id: check.commandWId)?.unloaded == false
                : sidebar.rowCheckInfo(id: check.clearSplitId) != nil
            guard restoredRow,
                  sidebar.todayDividerForCheck != nil else { note("wait=clear-stay-sidebar-restore"); return }
            check.report("divider_back_after_stay", true)
            check.report("clear_today_stay_keeps_only_refused_row", !others.isEmpty && others.allSatisfy { id in core.archive.contains { $0.id == id } })
            let split = adapter?.session.queue.sync { adapter?.session.store?.splitLayout(itemId: check.commandWId) }
            check.report("clear_today_stay_keeps_one_pane_split", split?.id == check.clearSplitId && split?.children.map(\.id) == [check.commandWId]
                         && space.today.contains(where: { $0.id == check.clearSplitId && $0.kind == .split })
                         && sidebar.rowCheckInfo(id: check.clearSplitId) != nil)
            if !screen { host.expectCheckDialogs(3) }
            trace("action=clear-after-stay today=\(space.today.map(\.id)) live=\(host.tabs().count)")
            guard sidebar.pressClearToday(trace: trace) else { check.report("clear_archives", false); step(5); return }
            step(5)
        case 5:
            // Do not gate Leave on a snapshot that a modal close may still be withholding.
            if screen && answerDialog(false) { trace("dialog=clear-after-stay answer=leave"); return }
            guard let core = sidebarCheckCore(), let space = core.spaces.first(where: { $0.id == core.shownSpaceId }) else {
                note("wait=clear-core-snapshot"); return
            }
            guard space.today.isEmpty else {
                note("wait=clear-today-empty today=\(space.today.map(\.id)) live=\(host.tabs().count)"); return
            }
            if (host.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId.map(check.seen.contains) == true }) == true {
                note("wait=clear-live-tab-removal live=\(host.tabs().count)")
                return
            }
            let stored = captureCheckRows()
            let archived = check.seen.allSatisfy { id in
                if core.archive.contains(where: { $0.id == id }) { return true }
                guard let row = stored?.first(where: { $0.count == 3 && $0[0] == "item" && $0[1] == id }),
                      let data = row[2].data(using: .utf8),
                      let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      ["Closed", "Archived"].contains(item["lifecycle"] as? String ?? ""),
                      let archive = item["archive"] as? [String: Any],
                      let group = archive["group"] as? String else { return false }
                return core.archive.contains { $0.id == group }
            }
            check.report("clear_archives", archived)
            check.report("clear_after_stay_without_close_motion", !check.clearRequestedClose)
            check.report("divider_hidden_without_today", sidebar.todayDividerForCheck == nil)
            _ = capture("cleared")
            trace("clear done; press the New Tab row")
            step(6)
        case 6:
            // p4checks (T4): the New Tab row's own press runs the app's onNewTab, which opens the
            // new-tab command bar the way the row, the menu and the key all do.
            guard commandPresenter == nil else { note("a command bar is already open"); return }
            guard sidebar.newTabRowForCheck != nil else { note("the New Tab row is missing"); return }
            trace("press the New Tab row")
            guard sidebar.pressNewTabRowForCheck() else {
                check.report("new_tab_row_press", false); finish(); return
            }
            step(7)
        case 7:
            guard let controller = commandPresenter?.controller, controller.isOpen else {
                note("the New Tab row did not open a command bar"); return
            }
            check.report("new_tab_row_press", controller.mode == .newTab)
            _ = capture("new-tab-row")
            trace("new tab row press mode=\(controller.mode)")
            commandPresenter?.close()
            finish()
        default: break
        }
    }

    // MARK: space-name (S1–S4, D13)

    func spaceNameTickPhase(screen: Bool, check: SidebarCheck, note: (String) -> Void, trace: (String) -> Void, step: (Int) -> Void,
                            finish: () -> Void, capture: (String) -> Bool, click: (NSView, NSPoint) -> Bool, row: (String) -> Row?) {
        guard let sidebar, let space = sidebarCheckShownSpace() else { return }
        let name = sidebar.spaceNameRow
        func nameX() -> CGFloat {
            // The row is laid out by the sidebar; a check tick can run before a display pass.
            sidebar.layoutSubtreeIfNeeded()
            name.layoutSubtreeIfNeeded()
            return sidebar.convert(name.checkNameFrame, from: name.superview).minX
        }
        switch check.phase {
        case 0:
            guard space.id == "sidebar-work" else { return }
            sidebar.layoutSubtreeIfNeeded()
            check.report("name_x", abs(nameX() - 16) < 0.5)
            check.report("chevron_hover", !name.checkChevronVisible)
            name.hovered = true
            sidebar.layoutSubtreeIfNeeded()
            check.report("name_x_hover", abs(nameX() - 40) < 0.5 && name.checkChevronVisible)
            _ = capture("hover")
            trace("hover")
            step(1)
        case 1:
            guard !sidebar.isSectionCollapsed(space.id) else { return }
            guard click(name, NSPoint(x: name.bounds.midX, y: name.bounds.midY)) else { return }
            trace("click toggles")
            step(2)
        case 2:
            guard sidebar.isSectionCollapsed(space.id) else { note("section not collapsed yet"); return }
            name.hovered = false
            sidebar.layoutSubtreeIfNeeded()
            check.report("click_toggles", true)
            check.report("name_x_collapsed", abs(nameX() - 40) < 0.5 && name.checkChevronVisible)
            _ = capture("collapsed")
            trace("menu")
            step(3)
        case 3:
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            guard let event, let menu = name.menu(for: event) else { return }
            let titles = menu.items.map { $0.isSeparatorItem ? nil : $0.title }
            check.report("menu_items", titles == ["Rename Space…", "Edit Look…", "Space Settings…", nil, "New Folder", nil, "Delete Space…"])
            check.report("menu_dock_same", titles == sidebar.dockMenuItems(for: space.id).map { $0.isSeparatorItem ? nil : $0.title })
            // S4: the click above toggled rather than renaming, and the menu's item starts it.
            check.report("rename_menu_only", name.checkRenameFieldFrame == nil)
            if screen, let window = name.window {
                check.capturing = true
                let point = NSPoint(x: name.bounds.midX, y: name.bounds.midY)
                let image = promptScreenMenuScreenshot(menu, window: window, name: "space-name-menu") {
                    menu.popUp(positioning: nil, at: point, in: name)
                }
                check.capturing = false
                check.images["menu"] = image
                check.conditions["capture"] = check.conditions["capture"] == true && image != nil
            }
            guard let rename = menu.items.first(where: { $0.title == "Rename Space…" }), let action = rename.action else {
                check.report("rename_field_height", false); step(4); return
            }
            NSApp.sendAction(action, to: rename.target, from: rename)
            step(4)
        case 4:
            guard let frame = name.checkRenameFieldFrame else { return }
            check.report("rename_field_height", abs(frame.height - 24) < 0.5)
            name.finishRenameForCheck(false)
            trace("look anchor")
            step(5)
        case 5:
            guard sidebar.lookSettings != nil else { check.report("look_anchor", false); finish(); return }
            guard let probe = sidebar.openLookForCheck() else { return }
            sharedLookProbe = probe
            step(6)
        case 6:
            guard let probe = sharedLookProbe, let popover = probe.window else { return }
            // The capture must show the finished popover, not points of its open animation:
            // wait until the window is opaque and its frame has stopped changing.
            if popover.alphaValue < 1 || sharedLookFrame != popover.frame {
                sharedLookFrame = popover.frame
                note("look popover still opening: alpha=\(popover.alphaValue) frame=\(rectFields(popover.frame)) content=\(probe.contentSize.map { rectFields(NSRect(origin: .zero, size: $0)) } ?? [:])")
                return
            }
            let row = sidebar.convert(name.bounds, from: name)
            let rowOnScreen = sidebar.window?.convertToScreen(row) ?? .zero
            let near = abs(popover.frame.midX - rowOnScreen.midX) < rowOnScreen.width + 40
            // The content is its designed width once the animation has landed.
            let width = probe.contentSize?.width ?? 0
            check.report("look_anchor", near && popover.isVisible && abs(width - LookCheckProbe.designedContentWidth) < 0.5)
            _ = capture("look")
            sharedLookProbe = nil
            sharedLookFrame = nil
            probe.closePopover()
            step(61)
        case 61:
            guard let selected = row("today-a") else { note("today-a is missing"); return }
            if sidebar.selectedRowID != selected.id { sidebar.selectRow(id: selected.id) }
            guard container?.sidebarHasSelection == true else {
                note("waiting for selection before create: row=\(sidebar.selectedRowID ?? "nil") core=\(snapshot.selectedId ?? "nil") hasSelection=\(container?.sidebarHasSelection == true)"); return
            }
            check.selectionReady = true
            check.details["selection_before_create"] = true
            check.spacesBefore = snapshot.spaces.count
            trace("open the create space page with a row selected")
            sidebar.showCreateSpace(nil)
            step(7)
        case 7:
            guard sidebar.createSpaceOpen else { note("the create page did not open"); return }
            // onCreatePageChanged reaches the container's selection rule: a create page has none.
            check.report("create_page", sidebar.checkCreateSpace.open)
            check.report("create_page_selection", check.selectionReady && container?.sidebarHasSelection == false)
            _ = capture("create-page")
            sidebar.checkTypeSpaceName("Research")
            guard sidebar.checkCreateSpace.name == "Research", sidebar.checkCreateSpace.buttonEnabled else {
                note("the create field did not take the name"); return
            }
            guard sidebar.checkSubmitSpaceName() else {
                check.report("create_landed", false); finish(); return
            }
            trace("submitted Research")
            step(8)
        case 8:
            guard snapshot.spaces.count == check.spacesBefore + 1, let created = snapshot.spaces.last,
                  !sidebar.createSpaceOpen else {
                note("created space not landed: spaces=\(snapshot.spaces.count)/\(check.spacesBefore + 1) page=\(sidebar.createSpaceOpen)")
                return
            }
            check.newSpaceID = created.id
            check.report("create_landed", created.title == "Research")
            check.report("create_page_closed", !sidebar.createSpaceOpen && !sidebar.checkCreateSpace.open)
            check.report("create_space_shown", snapshot.shownSpaceId == created.id
                         && sidebar.spaceShown == snapshot.spaces.count - 1)
            check.report("create_dock_cell", sidebar.checkDockShowsSpace(created.id))
            _ = capture("created")
            sidebar.layoutSubtreeIfNeeded()
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            guard let event, let menu = name.menu(for: event),
                  let rename = menu.items.first(where: { $0.title == "Rename Space…" }), let action = rename.action else {
                check.report("rename_commits", false); finish(); return
            }
            NSApp.sendAction(action, to: rename.target, from: rename)
            step(9)
        case 9:
            guard name.checkRenameFieldFrame != nil else { note("the rename field did not open"); return }
            check.renamedTitle = "Research Lab"
            name.checkTypeRename(check.renamedTitle)
            trace("commit the rename \(check.renamedTitle)")
            name.finishRenameForCheck(true)
            step(10)
        case 10:
            guard let core = sidebarCheckCore(),
                  let space = core.spaces.first(where: { $0.id == check.newSpaceID }) else {
                note("the created space is gone from the core"); return
            }
            let rowTitle = sidebar.spaceNameRow.checkName
            guard space.title == check.renamedTitle, rowTitle == check.renamedTitle else {
                note("title core=\(space.title) row=\(rowTitle) want=\(check.renamedTitle)")
                return
            }
            check.report("rename_commits", true)
            _ = capture("renamed")
            trace("done")
            finish()
        default: break
        }
    }
}
