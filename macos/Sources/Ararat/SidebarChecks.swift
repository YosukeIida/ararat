import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

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
    // Set around a screenshot: screencapture waits by spinning the run loop, so a tick would
    // otherwise re-enter while the capture is in flight.
    var capturing = false
    // Rows seen before a step, so a created row can be told apart by id.
    var seen: Set<String> = []

    static func conditionNames(mode: Mode, screen: Bool) -> [String] {
        let base: [String]
        switch mode {
        case .rows:
            base = ["rows_present", "loaded_pin_close", "unloaded_pin_archive", "today_archive",
                    "command_w_current", "close_caps_current", "empty_folder_line", "crashed_glyph", "unread_dot"]
        case .folderEmpty:
            base = ["line_frame", "line_absent_with_tabs", "line_absent_collapsed", "line_drop"]
        case .today:
            base = ["divider_visible", "divider_frame", "clear_present", "new_tab_row",
                    "clear_archives", "divider_hidden_without_today", "new_tab_setting_hides",
                    "name_drop_pins"]
        case .spaceName:
            base = ["name_x", "chevron_hover", "name_x_hover", "name_x_collapsed", "click_toggles",
                    "menu_items", "menu_dock_same", "rename_menu_only", "rename_field_height", "look_anchor"]
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
        return (space.today + space.pinned + space.favorites).first { $0.url?.hasSuffix("?sidebar-\(suffix)") == true }
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
                "rows": sidebar?.rowCheckIds.sorted() ?? [],
                "selected": snapshot.selectedId as Any? ?? NSNull(),
                "space_rows": space.map { ($0.today + $0.pinned + $0.favorites).map { row in
                    ["id": row.id, "title": row.title, "parent": row.parentId, "kind": String(describing: row.kind),
                     "unloaded": row.unloaded, "depth": row.depth] as [String: Any] } } ?? [],
                "crash_items": adapter?.crashedItems.sorted() ?? [],
                "core_archive": sidebarCheckCore()?.archive.map(\.id).sorted() ?? []]
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
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            trace("capture \(name)")
            check.capturing = true
            let path = promptScreenScreenshot(host.window(), name: "\(mode.rawValue)-\(name)", withoutShadow: true)
            check.capturing = false
            guard let path else { return false }
            check.images[name] = path
            return true
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
        case .rows: sidebarRowsTickPhase(host, screen: screen, check: check, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows)
        case .folderEmpty: folderEmptyTickPhase(screen: screen, check: check, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows)
        case .today: todayTickPhase(screen: screen, check: check, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows)
        case .spaceName: spaceNameTickPhase(screen: screen, check: check, trace: trace, step: step, finish: finish, capture: capture, click: click, row: rows)
        }
    }

    // MARK: sidebar-rows (R1/R2/R5/R7/F3/F4)

    func sidebarRowsTickPhase(_ host: any ARWindowHostAPI, screen: Bool, check: SidebarCheck, trace: (String) -> Void,
                              step: (Int) -> Void, finish: () -> Void, capture: (String) -> Bool,
                              click: (NSView, NSPoint) -> Bool, row: (String) -> Row?) {
        guard let sidebar else { return }
        switch check.phase {
        case 0:
            let space = sidebarCheckShownSpace()
            let needed = ["today-a", "today-b", "today-c", "pin", "pin-off", "folder-tab"]
            let rowIDs = Set(sidebar.rowCheckIds)
            guard let space,
                  needed.allSatisfy({ suffix in sidebarCheckRow(space, suffix).map { rowIDs.contains($0.id) } == true }) else { return }
            check.report("rows_present", true)
            trace("rows present")
            step(1)
        case 1:
            // R1/D2: a loaded pin's − is Close Tab and unloads it; the pin stays.
            guard let pin = row("pin"), let info = sidebar.rowCheckInfo(id: pin.id) else { return }
            guard info.closeLabel == "Close Tab" else { return }
            trace("press loaded pin close")
            check.report("loaded_pin_close", sidebar.pressCloseButton(id: pin.id))
            check.seen.insert(pin.id)
            step(2)
        case 2:
            guard let pin = row("pin"), let core = sidebarCheckCore(),
                  let corePin = core.spaces.flatMap(\.pinned).first(where: { $0.id == pin.id }) else { return }
            guard corePin.unloaded, !core.archive.contains(where: { $0.id == pin.id }) else { return }
            trace("press unloaded pin close")
            guard let off = row("pin-off"), let info = sidebar.rowCheckInfo(id: off.id) else { return }
            guard info.closeLabel == "Archive Tab" else { check.report("unloaded_pin_archive", false); finish(); return }
            check.report("unloaded_pin_archive", sidebar.pressCloseButton(id: off.id))
            step(3)
        case 3:
            guard let off = row("pin-off"), let core = sidebarCheckCore() else { return }
            guard !core.spaces.flatMap(\.pinned).contains(where: { $0.id == off.id }),
                  core.archive.contains(where: { $0.id == off.id }) else { return }
            guard let todayA = row("today-a"), let info = sidebar.rowCheckInfo(id: todayA.id), info.closeLabel == "Archive Tab" else { return }
            trace("press today close")
            check.report("today_archive", sidebar.pressCloseButton(id: todayA.id))
            step(4)
        case 4:
            guard let todayA = row("today-a"), let core = sidebarCheckCore() else { return }
            guard !core.spaces.flatMap(\.today).contains(where: { $0.id == todayA.id }),
                  core.archive.contains(where: { $0.id == todayA.id }) else { return }
            // R2: ⌘W acts on the current tab, whose button caps follow the binding.
            guard let todayB = row("today-b") else { return }
            sidebar.selectRow(id: todayB.id)
            guard sidebar.selectedRowID == todayB.id else { return }
            let caps = sidebar.rowCheckInfo(id: todayB.id)?.closeCaps
            check.report("close_caps_current", caps == sidebar.closeCapsForCheck && !(caps ?? []).isEmpty)
            trace("press ⌘W")
            sidebar.closeSelectedTab(nil)
            step(5)
        case 5:
            guard let todayB = row("today-b"), let core = sidebarCheckCore() else { return }
            guard core.archive.contains(where: { $0.id == todayB.id }) else { return }
            check.report("command_w_current", true)
            // F3: the open, empty folder shows its line at the child indent.
            guard let empty = row("empty"), let marker = sidebar.noTabsRowsForCheck.first(where: { $0.parent == empty.id }) else {
                check.report("empty_folder_line", false); step(6); return
            }
            let folderDepth = (sidebarCheckShownSpace()?.pinned ?? []).first { $0.id == empty.id }?.depth ?? 0
            let expected = 8 + 10 + 16 * CGFloat(folderDepth + 1)
            check.report("empty_folder_line", abs(marker.line.minX - expected) < 0.5 && abs(marker.height - 24) < 0.5
                         && abs(marker.line.width - 24) < 0.5)
            _ = capture("line")
            trace("empty folder line")
            step(6)
        case 6:
            // R5: a crashed renderer's row draws the warning glyph at 45 %.
            guard let todayC = row("today-c") else { return }
            if sidebar.selectedRowID != todayC.id { sidebar.selectRow(id: todayC.id); return }
            guard snapshot.selectedId == todayC.id, host.activeItemId() == todayC.id else { return }
            guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == todayC.id }) else { return }
            trace("crash renderer")
            guard tab.checkCrashRenderer() else { finish(); return }
            step(7)
        case 7:
            guard let todayC = row("today-c"), let info = sidebar.rowCheckInfo(id: todayC.id),
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == todayC.id }), tab.crashed else { return }
            guard info.iconDescription == "Crashed", abs(info.opacity - 0.45) < 0.01 else { return }
            check.report("crashed_glyph", true)
            _ = capture("crashed")
            trace("unread fixture")
            // R7: a loaded, not-shown tab whose title changes gets a dot.
            check.seen = Set(sidebarCheckShownSpace().map { ($0.today + $0.pinned + $0.favorites).map(\.id) } ?? [])
            host.checkNavigate("data:text/html,<title>Unread</title><script>setTimeout(function(){document.title='Unread changed'},300)</script>",
                               disposition: "background")
            step(8)
        case 8:
            guard let space = sidebarCheckShownSpace(), let candidate = space.today.first(where: { !check.seen.contains($0.id) }),
                  let info = sidebar.rowCheckInfo(id: candidate.id), info.unreadDot else { return }
            check.report("unread_dot", true)
            _ = capture("unread")
            sidebar.selectRow(id: candidate.id)
            step(9)
        case 9:
            guard let space = sidebarCheckShownSpace(), let shown = space.today.first(where: { sidebar.selectedRowID == $0.id }),
                  sidebar.rowCheckInfo(id: shown.id)?.unreadDot == false else { return }
            _ = capture("rows")
            trace("done")
            finish()
        default: break
        }
    }

    // MARK: folder-empty (F3)

    func folderEmptyTickPhase(screen: Bool, check: SidebarCheck, trace: (String) -> Void, step: (Int) -> Void,
                              finish: () -> Void, capture: (String) -> Bool, click: (NSView, NSPoint) -> Bool, row: (String) -> Row?) {
        guard let sidebar else { return }
        switch check.phase {
        case 0:
            guard let empty = row("empty"), let marker = sidebar.noTabsRowsForCheck.first(where: { $0.parent == empty.id }) else { return }
            let folderDepth = (sidebarCheckShownSpace()?.pinned ?? []).first { $0.id == empty.id }?.depth ?? 0
            let expected = 8 + 10 + 16 * CGFloat(folderDepth + 1)
            check.report("line_frame", abs(marker.line.minX - expected) < 0.5 && abs(marker.line.width - 24) < 0.5
                         && abs(marker.height - 24) < 0.5)
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
            trace("done")
            finish()
        default: break
        }
    }

    // MARK: today (T1–T4)

    func todayTickPhase(screen: Bool, check: SidebarCheck, trace: (String) -> Void, step: (Int) -> Void,
                        finish: () -> Void, capture: (String) -> Bool, click: (NSView, NSPoint) -> Bool, row: (String) -> Row?) {
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
            // Design q1: with no pins, a drop on the space name row pins at the top.
            // Archive the seed’s pins first, so the drop tests the no-pins case.
            guard let core = sidebarCheckCore(), core.spaces.flatMap(\.pinned).isEmpty else {
                for pin in sidebarCheckShownSpace()?.pinned ?? [] { adapter?.close(id: pin.id, archive: true) }
                return
            }
            guard let dragged = row("today-a"), let name = Optional(sidebar.spaceNameRow) else { return }
            let point = sidebar.convert(NSPoint(x: name.bounds.midX, y: name.bounds.midY), from: name)
            guard let drop = sidebar.resolveDropForCheck(position: point, draggedID: dragged.id),
                  drop.kind == "insert", drop.container == core.spaces.first?.pinnedId, drop.index == 0,
                  let space = sidebarCheckShownSpace() else {
                check.report("name_drop_pins", false); step(2); return
            }
            workspace?.move(id: dragged.id, container: space.pinnedId, index: 0, openFolder: false) { [weak self] result in
                if case .success(let snapshot) = result { self?.show(snapshot) }
            }
            step(2)
        case 2:
            guard let core = sidebarCheckCore(), let pinned = core.spaces.first?.pinned,
                  pinned.count == 1, pinned.first?.url?.hasSuffix("?sidebar-today-a") == true else { return }
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
            if let store = adapter?.session.store {
                _ = adapter?.session.queue.sync { try? store.setNewTabRowShown(windowId: windowID, shown: true) }
            }
            workspace?.newTabRowShown { [weak self] result in
                if case .success(let shown) = result { self?.sidebar?.newTabRowShown = shown }
            }
            step(4)
        case 4:
            guard sidebar.newTabRowForCheck != nil else { return }
            // D6: Clear runs live_clear_today and closes the pages; the divider and Clear go.
            guard let space = sidebarCheckShownSpace(), !space.today.isEmpty else { return }
            check.seen = Set(space.today.map(\.id))
            trace("press Clear")
            guard sidebar.pressClearToday() else { check.report("clear_archives", false); step(5); return }
            step(5)
        case 5:
            guard let core = sidebarCheckCore(), let space = core.spaces.first(where: { $0.id == core.shownSpaceId }) else { return }
            guard space.today.isEmpty else { return }
            let archived = check.seen.allSatisfy { id in core.archive.contains { $0.id == id } }
            check.report("clear_archives", archived)
            check.report("divider_hidden_without_today", sidebar.todayDividerForCheck == nil)
            _ = capture("cleared")
            trace("done")
            finish()
        default: break
        }
    }

    // MARK: space-name (S1–S4, D13)

    func spaceNameTickPhase(screen: Bool, check: SidebarCheck, trace: (String) -> Void, step: (Int) -> Void,
                            finish: () -> Void, capture: (String) -> Bool, click: (NSView, NSPoint) -> Bool, row: (String) -> Row?) {
        guard let sidebar, let space = sidebarCheckShownSpace() else { return }
        let name = sidebar.spaceNameRow
        func nameX() -> CGFloat {
            name.layoutSubtreeIfNeeded()
            return sidebar.convert(name.checkNameFrame, from: name.superview).minX
        }
        switch check.phase {
        case 0:
            guard space.id == "sidebar-work" else { return }
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
            guard sidebar.isSectionCollapsed(space.id) else { return }
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
            let titles = menu.items.map(\.title)
            check.report("menu_items", titles == ["Rename Space…", "Edit Look…", "Space Settings…", "New Folder", "Delete Space…"])
            check.report("menu_dock_same", titles == sidebar.dockMenuItems(for: space.id).map(\.title))
            // S4: the click above toggled rather than renaming, and the menu's item starts it.
            check.report("rename_menu_only", name.checkRenameFieldFrame == nil)
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
            let row = sidebar.convert(name.bounds, from: name)
            let rowOnScreen = sidebar.window?.convertToScreen(row) ?? .zero
            let near = abs(popover.frame.midX - rowOnScreen.midX) < rowOnScreen.width + 40
            check.report("look_anchor", near && popover.isVisible)
            _ = capture("look")
            sharedLookProbe = nil
            probe.closePopover()
            trace("done")
            finish()
        default: break
        }
    }
}
