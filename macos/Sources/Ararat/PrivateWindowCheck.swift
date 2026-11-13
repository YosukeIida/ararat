import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class PrivateWindowCheckState {
    static let names = [
        "private_window", "private_one_space_today_only", "private_sidebar", "private_mask",
        "private_dark", "private_close_label", "private_selected_active", "private_second_shares",
        "private_sibling_rows", "private_sibling_selection", "private_cross_move_refused",
        "private_close_removes", "private_clear_no_toast_no_undo", "private_downloads_library_row",
        "private_command_bar", "private_command_bar_no_history", "private_command_bar_no_disabled",
        "private_regular_bar_no_private_tab", "private_arc_import_disabled", "private_menu_disabled",
        "private_import_item_fabricated", "private_last_tab_closes_window", "private_last_close_releases",
        "private_new_starts_empty", "private_open_without_browser_refused", "private_routing_domain",
        "private_rows_unchanged", "private_history_unchanged", "private_disk_recorded",
    ]
    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var waitName = ""
    var waitCount = 0
    var siblingSelectionAttempts = 0
    var capturing = false
    var title = ""
    var closable = ""
    var db = ""
    var userDataDir = ""
    var diskBefore: [String: Any] = [:]
    var historyBefore: Int64 = -1

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: private-window \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: @autoclosure () -> String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: private-window wait=\(name) \(value())\n".utf8))
        }
        if waitName != name { waitName = name; waitCount = 0 }
        waitCount += 1
    }

    func diagnostics() -> [String: Any] {
        ["check": "private-window",
         "conditions": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, conditions[$0] == true) }),
         "failed_conditions": Self.names.filter { conditions[$0] != true },
         "wait": waitName, "images": images,
         "private_title": title, "private_db": db, "private_profile": userDataDir,
         "private_disk_before": diskBefore, "private_history_before": historyBefore,
         "private_disk_command": "AraratHarness --private-disk --db \(db) --profile-dir \(userDataDir) --title \(title)",
         "private_import_item": "fabricated by the check (no Arc import menu item in this build); only the title rule is tested"]
    }
}

/// U26f pass 3: the private window and its sidebar. One private window per OTR profile opens a
/// full window on the private workspace; two windows of one profile share it; a tab moved in one
/// appears in the other; Close and Clear remove rows without an archive entry, a toast or Undo; a
/// private window closes with its last tab; the command bar offers no history and no disabled
/// commands; the last close releases the workspace; nothing reaches the regular store.
@MainActor
extension Runtime {
    func privateWindowCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if privateWindowCheck == nil { privateWindowCheck = PrivateWindowCheckState() }
        guard let check = privateWindowCheck, !check.capturing else { return }
        let window = host.window()
        func wait(_ name: String) {
            check.wait(name, "phase=\(browserCheckPhase) key=\(window.isKeyWindow) first_key=\(children.first(where: { $0.windowID == privateFirstWindowID })?.host?.window().isKeyWindow ?? false) children=\(children.count) private=\(children.filter(\.isPrivateWindow).count) live=\(PrivateWorkspaces.liveCount) selected=\(snapshot.selectedId ?? "nil") host_active=\(host.activeItemId() ?? "nil")")
        }
        func privateChildren() -> [Runtime] { children.filter { $0.isPrivateWindow && $0.host != nil } }
        func privateSnapshot(_ child: Runtime) -> WorkspaceSnapshot? {
            child.adapter?.session.queue.sync { child.adapter?.session.store?.snapshot(windowId: child.windowID) }
        }
        func regularRowsUnchanged() -> Bool {
            guard let before = quitBefore, let rows = captureCheckRows() else { return false }
            // Why not the whole table: the regular window's device-local Window/LastSelected rows
            // commit on their own batch; the workspace rows are what a private run must not touch.
            func stable(_ rows: [[String]]) -> [[String]] {
                rows.filter { $0.count == 3 && $0[0] != "window" && $0[0] != "last_selected" }
            }
            return stable(before) == stable(rows)
        }
        func historySize() -> Int64 {
            guard !check.userDataDir.isEmpty else { return -1 }
            let path = (check.userDataDir as NSString).appendingPathComponent("Default/History")
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        func diskSnapshot() -> [String: Any] {
            let manager = FileManager.default
            var listing: [String] = []
            var bytes: Int64 = 0
            if !check.userDataDir.isEmpty, let enumerator = manager.enumerator(atPath: check.userDataDir) {
                while let entry = enumerator.nextObject() as? String {
                    guard listing.count < 400 else { break }
                    listing.append(entry)
                    if let attributes = try? manager.attributesOfItem(atPath: (check.userDataDir as NSString).appendingPathComponent(entry)),
                       let size = attributes[.size] as? NSNumber { bytes += size.int64Value }
                }
            }
            func size(_ path: String) -> Int64 {
                ((try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? -1
            }
            return ["db_bytes": size(check.db), "wal_bytes": size(check.db + "-wal"),
                    "files": listing.count, "total_bytes": bytes, "listing": listing]
        }

        switch browserCheckPhase {
        case 0:
            guard let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first, row.url != nil else {
                wait("regular seed row"); return
            }
            browserCheckSeedID = row.id
            selectCheckSeed(row)
            browserCheckPhase = 1
        case 1:
            guard let seed = browserCheckSeedID, sliceActive == seed,
                  snapshot.selectedId == seed, host.activeItemId() == seed,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == seed }),
                  !tab.isLoading else { wait("regular seed selected"); return }
            browserCheckBefore = snapshot
            quitBefore = captureCheckRows()
            check.title = "ararat-private-\(UUID().uuidString)"
            check.db = quitPath ?? ""
            check.userDataDir = (quitPath as NSString?)?.deletingLastPathComponent ?? ""
            check.userDataDir = (check.userDataDir as NSString).deletingLastPathComponent
            check.diskBefore = diskSnapshot()
            check.historyBefore = historySize()
            check.mark("private_disk_recorded", !check.title.isEmpty && !check.db.isEmpty && !check.userDataDir.isEmpty)
            host.checkCreateIncognito()
            browserCheckPhase = 2
        case 2:
            // Each claim is marked and named as soon as it is checked, so a timeout says which.
            guard let child = privateChildren().first, child.host?.isPrivateWindow() == true else { wait("private child"); return }
            check.mark("private_window")
            guard let snap = privateSnapshot(child),
                  snap.spaces.count == 1, snap.spaces[0].id == "private",
                  snap.spaces[0].pinned.isEmpty, snap.spaces[0].favorites.isEmpty,
                  snap.spaces[0].today.count == 1, let item = snap.spaces[0].today.first?.id else {
                wait("private one space with one today row"); return
            }
            check.mark("private_one_space_today_only")
            guard let live = child.adapter?.session.queue.sync(execute: { child.adapter?.session.store?.liveTab(item: item) }),
                  !live.isEmpty,
                  let tabs = child.host?.tabs() as? [any ARTabAPI], tabs.count == 1,
                  tabs[0].itemId == item, tabs[0].liveId == live else { wait("private adopted tab"); return }
            if screen, child.host?.window().isKeyWindow != true {
                child.host?.window().makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                wait("private window key"); return
            }
            check.mark("private_selected_active", child.snapshot.selectedId == item && child.host?.activeItemId() == item)
            guard child.snapshot.selectedId == item, child.host?.activeItemId() == item else { wait("private selection"); return }
            guard let sidebar = child.sidebar, let container = child.container else { wait("private views"); return }
            let side = sidebar.checkPrivateBadgeVisible && sidebar.checkPrivateDockHidden &&
                sidebar.checkPrivateFavoritesHidden && sidebar.checkPrivateSpaceRowHidden
            check.mark("private_sidebar", side)
            guard side else { wait("private sidebar shape"); return }
            check.mark("private_mask", container.privateMaskVisible)
            guard container.privateMaskVisible else { wait("private mask"); return }
            let dark = child.host?.window().appearance?.name == .darkAqua
            check.mark("private_dark", dark)
            guard dark else { wait("private dark appearance"); return }
            let label = sidebar.checkPrivateCloseLabel(item) == "Close Tab"
            check.mark("private_close_label", label)
            guard label else { wait("private close label"); return }
            check.mark("private_routing_domain", host.checkRoutingDomain() && (child.host?.checkRoutingDomain() == true))
            check.mark("private_downloads_library_row", sidebar.checkPrivateDownloadsLibraryRowHidden)
            guard regularRowsUnchanged() else { wait("regular rows unchanged"); return }
            privateFirstWindowID = child.windowID
            privateFirstItem = item
            privateFirstLive = live
            if screen {
                check.capturing = true
                defer { check.capturing = false }
                if let privateWindow = child.host?.window(),
                   let path = promptScreenScreenshot(privateWindow, name: "private-window", withoutShadow: true) {
                    check.images["private"] = path
                }
            }
            // The private command bar: the private session, no history request, no disabled commands.
            child.privateHistoryQueries = 0
            child.openCommandBar(.newTab)
            browserCheckPhase = 20
        case 20:
            guard let first = privateChildren().first, let presenter = first.commandPresenter else { wait("private command bar"); return }
            presenter.controller.update(query: "p")
            browserCheckPhase = 21
        case 21:
            guard let first = privateChildren().first, let presenter = first.commandPresenter else { wait("private command bar query"); return }
            let noHistory = !presenter.controller.result.rows.contains { row in
                if case .history = row.target { return true } else { return false }
            }
            let disabled: Set<String> = ["pin_tab", "duplicate", "new_folder", "delete_folder", "toggle_library", "show_space_2", "move_to_space_2"]
            let noDisabled = !presenter.controller.result.rows.contains { row in
                if case .command(let id) = row.target { return disabled.contains(id) } else { return false }
            }
            guard presenter.controller.privateWindow, presenter.controller.result.privateWindow,
                  noHistory, first.privateHistoryQueries == 0,
                  !presenter.controller.result.rows.isEmpty else { wait("private command bar content"); return }
            check.mark("private_command_bar")
            check.mark("private_command_bar_no_history")
            check.mark("private_command_bar_no_disabled", noDisabled)
            first.commandPresenter?.close(restoreFocus: false)
            // A uniquely titled row for the disk search and for the release-vs-reuse assertion.
            let space = first.snapshot.shownSpaceId ?? "private"
            let profile = first.privateProfile ?? "Default"
            first.adapter?.openCommandURL("data:text/html,<title>\(check.title)</title>", expectedSpace: space, profile: profile)
            // Two private windows of one OTR profile share the workspace.
            first.host?.checkCreateIncognito()
            browserCheckPhase = 3
        case 3:
            guard privateChildren().count == 2,
                  let first = privateChildren().first(where: { $0.windowID == privateFirstWindowID }),
                  let second = privateChildren().first(where: { $0 !== first }),
                  second.host?.isPrivateWindow() == true,
                  let s1 = privateSnapshot(first), let s2 = privateSnapshot(second),
                  s1.spaces == s2.spaces,
                  s1.spaces.first?.today.map(\.id).contains(privateFirstItem) == true,
                  PrivateWorkspaces.liveCount == 2,
                  let titleRow = s1.spaces.first?.today.first(where: { $0.title == check.title })?.id else {
                wait("second private window shares rows"); return
            }
            check.mark("private_second_shares")
            // A tab opened in window 2 must appear in window 1's rows (not the same store read twice).
            let space = second.snapshot.shownSpaceId ?? "private"
            second.adapter?.openCommandURL("about:blank?private-sibling", expectedSpace: space, profile: second.privateProfile ?? "Default")
            browserCheckPhase = 4
        case 4:
            guard privateChildren().count == 2,
                  let first = privateChildren().first(where: { $0.windowID == privateFirstWindowID }),
                  let second = privateChildren().first(where: { $0 !== first }),
                  let s1 = privateSnapshot(first), let s2 = privateSnapshot(second),
                  let sibling = s2.spaces.first?.today.first(where: { $0.url == "about:blank?private-sibling" })?.id,
                  s1.spaces.first?.today.map(\.id).contains(sibling) == true,
                  let titleRow = s1.spaces.first?.today.first(where: { $0.title == check.title })?.id else {
                wait("sibling tab in window 1"); return
            }
            check.mark("private_sibling_rows")
            if screen, first.host?.window().isKeyWindow != true {
                first.host?.window().makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                wait("window 1 key"); return
            }
            // Selecting in window 1 a row whose live tab is in window 2 moves it (same OTR domain).
            let selected = first.sidebar?.selectRow(id: sibling) == true
            if !selected {
                check.siblingSelectionAttempts += 1
                let rows = first.snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
                check.wait("sibling row in sidebar", "window=\(first.windowID) sibling=\(sibling) rows=\(rows) attempt=\(check.siblingSelectionAttempts)")
                if check.siblingSelectionAttempts >= 60 {
                    check.mark("private_sibling_selection", false)
                    var result = check.diagnostics()
                    result["error"] = "sibling row in sidebar timed out"
                    result["sibling"] = sibling
                    result["first_delivered_rows"] = rows
                    finishBrowserCheck(ok: false, values: result)
                }
                return
            }
            browserCheckPhase = 5
        case 5:
            guard let first = privateChildren().first(where: { $0.windowID == privateFirstWindowID }),
                  let second = privateChildren().first(where: { $0 !== first }),
                  let sibling = first.adapter?.session.queue.sync(execute: {
                      first.adapter?.session.store?.snapshot(windowId: first.windowID).spaces.first?.today.first(where: { $0.url == "about:blank?private-sibling" })?.id
                  }) else { wait("sibling row lookup"); return }
            let firstHasTab = (first.host?.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == sibling }) == true
            let secondHasTab = (second.host?.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == sibling }) == true
            if check.waitCount % 20 == 0 {
                FileHandle.standardError.write(Data("ararat-trace: private-window sibling=\(sibling) first_selected=\(first.snapshot.selectedId ?? "nil") first_active=\(first.host?.activeItemId() ?? "nil") first_has=\(firstHasTab) second_has=\(secondHasTab) first_key=\(first.host?.window().isKeyWindow ?? false)\n".utf8))
            }
            guard
                  first.host?.activeItemId() == sibling,
                  !secondHasTab,
                  let s1 = privateSnapshot(first),
                  let titleRow = s1.spaces.first?.today.first(where: { $0.title == check.title })?.id else {
                wait("sibling row selected in window 1"); return
            }
            check.mark("private_sibling_selection")
            // The root's command bar never shows a private tab.
            self.privateHistoryQueries = 0
            self.openCommandBar(.newTab)
            browserCheckPhase = 6
        case 6:
            guard let presenter = self.commandPresenter else { wait("regular command bar"); return }
            presenter.controller.update(query: check.title)
            browserCheckPhase = 7
        case 7:
            guard let presenter = self.commandPresenter else { wait("regular command bar query"); return }
            let leaks = presenter.controller.result.rows.contains { row in
                guard row.title == check.title else { return false }
                if case .tab = row.target { return true }
                return false
            }
            check.mark("private_regular_bar_no_private_tab", !leaks)
            presenter.close(restoreFocus: false)
            guard let first = privateChildren().first(where: { $0.windowID == privateFirstWindowID }),
                  let second = privateChildren().first(where: { $0 !== first }) else { wait("private windows for the move"); return }
            guard let regularTab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
                  let privateTab = (first.host?.tabs() as? [any ARTabAPI])?.first,
                  let privateHost = first.host, let secondHost = second.host else { wait("tabs for the refused move"); return }
            let refused = !privateHost.checkMoveTab(privateTab, toHost: host) && !host.checkMoveTab(regularTab, toHost: privateHost)
            check.mark("private_cross_move_refused", refused)
            second.host?.close()
            browserCheckPhase = 8
        case 8:
            guard privateChildren().count == 1, PrivateWorkspaces.liveCount == 1,
                  let first = privateChildren().first,
                  let s1 = privateSnapshot(first),
                  let titleRow = s1.spaces.first?.today.first(where: { $0.title == check.title })?.id,
                  let closable = s1.spaces.first?.today.first(where: { $0.id != titleRow })?.id else {
                wait("second private window closed, with a row to close"); return
            }
            // Close one row through the sidebar's own path: removal, no archive entry.
            check.closable = closable
            first.close(closable)
            browserCheckPhase = 24
        case 24:
            guard let first = privateChildren().first, let snap = privateSnapshot(first),
                  let titleRow = snap.spaces.first?.today.first(where: { $0.title == check.title })?.id else {
                wait("private window for the row close"); return
            }
            let remaining = snap.spaces.first?.today.filter { $0.id != titleRow } ?? []
            if remaining.contains(where: { $0.id == check.closable }) { wait("private row closed"); return }
            check.mark("private_close_removes")
            if let next = remaining.first?.id {
                check.closable = next
                first.close(next)
                return
            }
            guard snap.archive.isEmpty, regularRowsUnchanged() else { wait("private close leaves no archive"); return }
            // Only the uniquely titled row is left; closing the window closes with its last tab.
            browserCheckPhase = 9
        case 9:
            guard let first = privateChildren().first,
                  let s1 = privateSnapshot(first),
                  let titleRow = s1.spaces.first?.today.first(where: { $0.title == check.title })?.id,
                  s1.spaces.first?.today.count == 1 else { wait("only the titled row left"); return }
            first.host?.window().makeKeyAndOrderFront(nil)
            guard first.host?.window().isKeyWindow == true else { wait("private window key for the menu"); return }
            let importItem = NSMenuItem(title: "Import Bookmarks and Settings…", action: nil, keyEquivalent: "")
            let pinItem = NSMenuItem(title: "Pin Tab", action: #selector(Runtime.coreMenuCommand(_:)), keyEquivalent: "")
            pinItem.representedObject = "pin_tab"
            let spaceItem = NSMenuItem(title: "Show Space 2", action: #selector(Runtime.coreMenuCommand(_:)), keyEquivalent: "")
            spaceItem.representedObject = "show_space_2"
            check.mark("private_arc_import_disabled", !first.validateMenuItem(importItem))
            check.mark("private_menu_disabled", !first.validateMenuItem(pinItem) && !first.validateMenuItem(spaceItem))
            check.mark("private_import_item_fabricated")
            first.host?.close()
            browserCheckPhase = 10
        case 10:
            guard privateChildren().isEmpty, PrivateWorkspaces.liveCount == 0,
                  regularRowsUnchanged() else { wait("last private window released"); return }
            check.mark("private_last_close_releases")
            check.mark("private_rows_unchanged")
            check.mark("private_history_unchanged", historySize() == check.historyBefore)
            host.checkCreateIncognito()
            browserCheckPhase = 11
        case 11:
            guard let child = privateChildren().first, let snap = privateSnapshot(child),
                  snap.spaces.count == 1, snap.spaces[0].today.count == 1,
                  snap.spaces.first?.today.first?.title != check.title,
                  snap.archive.isEmpty else { wait("new private window starts empty"); return }
            check.mark("private_new_starts_empty")
            check.mark("private_open_without_browser_refused", child.host?.checkRefuseOpenWithoutBrowser() == true)
            // Two more rows, then Clear: removal with no toast or Undo, and the window closes
            // with its last tab (design M1).
            let space = child.snapshot.shownSpaceId ?? "private"
            let profile = child.privateProfile ?? "Default"
            child.adapter?.openCommandURL("about:blank?private-clear-a", expectedSpace: space, profile: profile)
            child.adapter?.openCommandURL("about:blank?private-clear-b", expectedSpace: space, profile: profile)
            browserCheckPhase = 25
        case 25:
            guard let child = privateChildren().first, let snap = privateSnapshot(child),
                  snap.spaces.first?.today.count == 3 else { wait("private tabs for Clear"); return }
            child.clearToday()
            // The private store returns no Clear batch, so the caller offers no toast/Undo;
            // record that at the press, before the empty strip closes the window.
            check.mark("private_clear_no_toast_no_undo",
                       child.container?.checkToastState.visible != true && child.clearUndo.available == false)
            browserCheckPhase = 26
        case 26:
            guard privateChildren().isEmpty, PrivateWorkspaces.liveCount == 0,
                  regularRowsUnchanged() else { wait("private window closed by Clear"); return }
            check.mark("private_last_tab_closes_window")
            check.mark("private_rows_unchanged")
            let result = check.diagnostics()
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty &&
                               host.checkStockBrowsers() == 0 && snapshot == browserCheckBefore, values: result)
        default:
            break
        }
    }
}
