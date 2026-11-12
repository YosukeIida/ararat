import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class PrivateWindowCheckState {
    static let names = [
        "private_window", "private_one_space_today_only", "private_sidebar", "private_mask",
        "private_close_label", "private_selected_active", "private_second_shares",
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
    var capturing = false
    var title = ""
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
            check.wait(name, "phase=\(browserCheckPhase) key=\(window.isKeyWindow) children=\(children.count) private=\(children.filter(\.isPrivateWindow).count) live=\(PrivateWorkspaces.liveCount) selected=\(snapshot.selectedId ?? "nil") host_active=\(host.activeItemId() ?? "nil")")
        }
        func privateChildren() -> [Runtime] { children.filter { $0.isPrivateWindow && $0.host != nil } }
        func privateSnapshot(_ child: Runtime) -> WorkspaceSnapshot? {
            child.adapter?.session.queue.sync { child.adapter?.session.store?.snapshot(windowId: child.windowID) }
        }
        func regularRowsUnchanged() -> Bool {
            guard let before = quitBefore, let rows = captureCheckRows() else { return false }
            return rows == before
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
            guard let child = privateChildren().first,
                  child.host?.isPrivateWindow() == true,
                  let sidebar = child.sidebar, let container = child.container,
                  let snap = privateSnapshot(child),
                  snap.spaces.count == 1, snap.spaces[0].id == "private",
                  snap.spaces[0].pinned.isEmpty, snap.spaces[0].favorites.isEmpty,
                  snap.spaces[0].today.count == 1, let item = snap.spaces[0].today.first?.id,
                  let live = child.adapter?.session.queue.sync(execute: { child.adapter?.session.store?.liveTab(item: item) }),
                  !live.isEmpty,
                  let tabs = child.host?.tabs() as? [any ARTabAPI], tabs.count == 1,
                  tabs[0].itemId == item, tabs[0].liveId == live,
                  child.snapshot.selectedId == item, child.host?.activeItemId() == item,
                  sidebar.checkPrivateBadgeVisible, sidebar.checkPrivateDockHidden,
                  sidebar.checkPrivateFavoritesHidden, sidebar.checkPrivateSpaceRowHidden,
                  container.privateMaskVisible, child.host?.window().appearance?.name == .darkAqua,
                  sidebar.checkPrivateCloseLabel(item) == "Close Tab",
                  regularRowsUnchanged() else { wait("private window with one tab"); return }
            check.mark("private_window")
            check.mark("private_one_space_today_only")
            check.mark("private_sidebar")
            check.mark("private_mask", container.privateMaskVisible)
            check.mark("private_close_label")
            check.mark("private_selected_active")
            check.mark("private_routing_domain", host.checkRoutingDomain() && (child.host?.checkRoutingDomain() == true))
            check.mark("private_downloads_library_row", sidebar.checkPrivateDownloadsLibraryRowHidden)
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
            // Selecting in window 1 a row whose live tab is in window 2 moves it (same OTR domain).
            first.sidebar?.selectRow(id: sibling)
            browserCheckPhase = 5
        case 5:
            guard let first = privateChildren().first(where: { $0.windowID == privateFirstWindowID }),
                  let second = privateChildren().first(where: { $0 !== first }),
                  let sibling = first.adapter?.session.queue.sync(execute: {
                      first.adapter?.session.store?.snapshot(windowId: first.windowID).spaces.first?.today.first(where: { $0.url == "about:blank?private-sibling" })?.id
                  }),
                  first.host?.activeItemId() == sibling,
                  (second.host?.tabs() as? [any ARTabAPI])?.contains(where: { $0.itemId == sibling }) != true,
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
                  let sidebar = first.sidebar else { wait("second private window closed"); return }
            // Leave only the uniquely titled row, then close the window: it closes with its last tab.
            for row in s1.spaces.first?.today ?? [] where row.id != titleRow {
                first.close(row.id)
            }
            browserCheckPhase = 9
        case 9:
            guard let first = privateChildren().first,
                  let s1 = privateSnapshot(first),
                  let titleRow = s1.spaces.first?.today.first(where: { $0.title == check.title })?.id,
                  s1.spaces.first?.today.count == 1 else { wait("only the titled row left"); return }
            check.mark("private_close_removes")
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
            if let only = snap.spaces.first?.today.first?.id { child.close(only) }
            browserCheckPhase = 12
        case 12:
            guard privateChildren().isEmpty, PrivateWorkspaces.liveCount == 0,
                  regularRowsUnchanged() else { wait("private window closed with its last tab"); return }
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
