import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
enum PrivateWindowCheckImages {
    static var images: [String: String] = [:]
}

/// U26f pass 3: the private window and its sidebar. One private window per OTR profile opens a
/// full window on the private workspace; two windows of one profile share it; Close and Clear
/// remove rows without an archive entry, a toast or Undo; the command bar offers no history; a
/// new private window starts empty; the last close releases the workspace; nothing reaches the
/// regular store.
@MainActor
extension Runtime {
    func privateWindowCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        let window = host.window()
        func wait(_ name: String) {
            FileHandle.standardError.write(Data("ararat-trace: private-window wait=\(name) phase=\(browserCheckPhase) key=\(window.isKeyWindow) children=\(children.count) private=\(children.filter(\.isPrivateWindow).count) live=\(PrivateWorkspaces.liveCount) selected=\(snapshot.selectedId ?? "nil") host_active=\(host.activeItemId() ?? "nil")\n".utf8))
        }
        func privateChildren() -> [Runtime] { children.filter { $0.isPrivateWindow && $0.host != nil } }
        func privateSnapshot(_ child: Runtime) -> WorkspaceSnapshot? {
            child.adapter?.session.queue.sync {
                child.adapter?.session.store?.snapshot(windowId: child.windowID)
            }
        }
        func regularRowsUnchanged() -> Bool {
            guard let before = quitBefore, let rows = captureCheckRows() else { return false }
            return rows == before
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
            privateRowsBefore = quitBefore
            host.checkCreateIncognito()
            browserCheckPhase = 2
        case 2:
            // The private window is a full window on the private workspace: one space with
            // Today only, one adopted new tab, the private sidebar, dark with its mask.
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
                  sidebar.checkPrivateBadgeVisible, sidebar.checkPrivateDockHidden,
                  sidebar.checkPrivateFavoritesHidden, sidebar.checkPrivateSpaceRowHidden,
                  container.privateMaskVisible,
                  sidebar.checkPrivateCloseLabel(item) == "Close Tab",
                  regularRowsUnchanged() else { wait("private window with one tab"); return }
            privateFirstWindowID = child.windowID
            privateFirstItem = item
            privateFirstLive = live
            if screen {
                if let path = promptScreenScreenshot(window, name: "private-window", withoutShadow: true) {
                    PrivateWindowCheckImages.images["private"] = path
                }
            }
            // Two private windows of one OTR profile share the workspace.
            child.host?.checkCreateIncognito()
            browserCheckPhase = 3
        case 3:
            guard privateChildren().count == 2,
                  let first = privateChildren().first(where: { $0.windowID == privateFirstWindowID }),
                  let second = privateChildren().first(where: { $0 !== first }),
                  second.host?.isPrivateWindow() == true,
                  let s1 = privateSnapshot(first), let s2 = privateSnapshot(second),
                  s1.spaces == s2.spaces,
                  s1.spaces.first?.today.map(\.id).contains(privateFirstItem) == true,
                  PrivateWorkspaces.liveCount == 2 else { wait("second private window shares rows"); return }
            second.host?.close()
            browserCheckPhase = 4
        case 4:
            guard privateChildren().count == 1, PrivateWorkspaces.liveCount == 1,
                  let first = privateChildren().first else { wait("second private window closed"); return }
            guard let regularTab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == browserCheckSeedID }),
                  let privateTab = (first.host?.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == privateFirstItem }),
                  let privateHost = first.host else { wait("tabs for the refused move"); return }
            // A private tab cannot move to the regular window, nor a regular tab into a private
            // one: both are another domain, like another profile's dock cell.
            guard !privateHost.checkMoveTab(privateTab, toHost: host),
                  !host.checkMoveTab(regularTab, toHost: privateHost) else {
                finishBrowserCheck(ok: false, values: ["private_cross_move_refused": false]); return
            }
            // Close removes the row: no archive entry, no Undo, no toast.
            first.close(privateFirstItem)
            browserCheckPhase = 5
        case 5:
            guard let first = privateChildren().first, let snap = privateSnapshot(first),
                  snap.spaces.first?.today.isEmpty == true, snap.archive.isEmpty,
                  regularRowsUnchanged() else { wait("private close removes"); return }
            let space = first.snapshot.shownSpaceId ?? "private"
            let profile = first.privateProfile ?? "Default"
            first.adapter?.openCommandURL("about:blank?private-a", expectedSpace: space, profile: profile)
            first.adapter?.openCommandURL("about:blank?private-b", expectedSpace: space, profile: profile)
            browserCheckPhase = 6
        case 6:
            guard let first = privateChildren().first, let snap = privateSnapshot(first),
                  snap.spaces.first?.today.count == 2 else { wait("private tabs opened"); return }
            first.clearToday()
            browserCheckPhase = 7
        case 7:
            guard let first = privateChildren().first, let snap = privateSnapshot(first),
                  snap.spaces.first?.today.isEmpty == true, snap.archive.isEmpty,
                  first.container?.checkToastState.visible == false,
                  first.clearUndo.available == false,
                  regularRowsUnchanged() else { wait("private clear removes without toast"); return }
            guard first.sidebar?.checkPrivateDownloadsLibraryRowHidden == true else {
                finishBrowserCheck(ok: false, values: ["private_downloads_library_row": false]); return
            }
            first.privateHistoryQueries = 0
            first.openCommandBar(.newTab)
            browserCheckPhase = 8
        case 8:
            guard let first = privateChildren().first, let presenter = first.commandPresenter else { wait("private command bar"); return }
            presenter.controller.update(query: "cl")
            browserCheckPhase = 9
        case 9:
            guard let first = privateChildren().first, let presenter = first.commandPresenter else { wait("private command bar query"); return }
            let noHistory = !presenter.controller.result.rows.contains { row in
                if case .history = row.target { return true } else { return false }
            }
            guard presenter.controller.privateWindow, presenter.controller.result.privateWindow,
                  noHistory, first.privateHistoryQueries == 0,
                  !presenter.controller.result.rows.isEmpty else { wait("private command bar content"); return }
            first.commandPresenter?.close(restoreFocus: false)
            first.host?.window().makeKeyAndOrderFront(nil)
            // Arc import and the workspace commands a private space does not have are disabled.
            let importItem = NSMenuItem(title: "Import Bookmarks and Settings…", action: nil, keyEquivalent: "")
            let pinItem = NSMenuItem(title: "Pin Tab", action: #selector(Runtime.coreMenuCommand(_:)), keyEquivalent: "")
            pinItem.representedObject = "pin_tab"
            let spaceItem = NSMenuItem(title: "Show Space 2", action: #selector(Runtime.coreMenuCommand(_:)), keyEquivalent: "")
            spaceItem.representedObject = "show_space_2"
            guard !first.validateMenuItem(importItem), !first.validateMenuItem(pinItem),
                  !first.validateMenuItem(spaceItem) else {
                finishBrowserCheck(ok: false, values: ["private_menu_disabled": false]); return
            }
            first.host?.close()
            browserCheckPhase = 10
        case 10:
            guard privateChildren().isEmpty, PrivateWorkspaces.liveCount == 0,
                  regularRowsUnchanged() else { wait("last private window released"); return }
            host.checkCreateIncognito()
            browserCheckPhase = 11
        case 11:
            guard let child = privateChildren().first, let snap = privateSnapshot(child),
                  snap.spaces.count == 1, snap.spaces[0].today.count == 1, snap.archive.isEmpty else {
                wait("new private window starts empty"); return
            }
            child.host?.close()
            browserCheckPhase = 12
        case 12:
            guard privateChildren().isEmpty, PrivateWorkspaces.liveCount == 0,
                  regularRowsUnchanged() else { wait("private state released"); return }
            let rows = captureCheckRows() ?? []
            finishBrowserCheck(ok: host.checkStockBrowsers() == 0 && snapshot == browserCheckBefore,
                               values: ["case": "private-window",
                                        "private_window_rows": ["private": true, "window": privateFirstWindowID,
                                                                 "item": privateFirstItem, "live": privateFirstLive],
                                        "private_one_space_today_only": true, "private_sidebar": true,
                                        "private_close_removes": true, "private_clear_no_toast_no_undo": true,
                                        "private_command_bar_no_history": true, "private_arc_import_disabled": true,
                                        "private_cross_move_refused": true, "private_windows_share": true,
                                        "private_last_close_releases": true, "private_new_starts_empty": true,
                                        "private_rows_unchanged": regularRowsUnchanged(),
                                        "regular_rows": rows.count, "stock_browsers": host.checkStockBrowsers(),
                                        "images": PrivateWindowCheckImages.images])
        default:
            break
        }
    }
}
