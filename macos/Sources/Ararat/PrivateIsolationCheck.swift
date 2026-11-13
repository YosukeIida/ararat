import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class PrivateIsolationCheckState {
    static let names = ["private_shared", "private_regular_hidden", "private_rows_disjoint",
                        "private_cross_refused", "private_close_clear", "private_archive_clean",
                        "private_bar_no_history", "private_bar_no_learning", "private_rows_unchanged"]
    var conditions: [String: Bool] = [:]
    var waitName = ""
    var waitCount = 0
    var learnTitle = ""
    var learnURL = ""
    var pendingClose = ""

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: private-isolation \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: @autoclosure () -> String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: private-isolation wait=\(name) \(value())\n".utf8))
        }
        if waitName != name { waitName = name; waitCount = 0 }
        waitCount += 1
    }

    func diagnostics() -> [String: Any] {
        ["check": "private-isolation",
         "conditions": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, conditions[$0] == true) }),
         "failed_conditions": Self.names.filter { conditions[$0] != true },
         "wait": waitName]
    }
}

/// U26f pass 4: two private windows of one OTR profile and one regular window. The private
/// windows share a workspace; the regular window never sees a private row and vice versa; a
/// cross-domain move is refused; Close and Clear remove without an archive entry; the private
/// command bar offers no history and learns nothing.
@MainActor
extension Runtime {
    func privateIsolationCheckTick(_ host: any ARWindowHostAPI) {
        if privateIsolationCheck == nil { privateIsolationCheck = PrivateIsolationCheckState() }
        guard let check = privateIsolationCheck else { return }
        func wait(_ name: String) {
            check.wait(name, "phase=\(browserCheckPhase) children=\(children.count) private=\(children.filter(\.isPrivateWindow).count) live=\(PrivateWorkspaces.liveCount)")
        }
        func privateChildren() -> [Runtime] { children.filter { $0.isPrivateWindow && $0.host != nil } }
        func regularChild() -> Runtime? { children.first { !$0.isPrivateWindow && $0.host != nil } }
        func privateRows(_ child: Runtime) -> [String] {
            child.adapter?.session.queue.sync {
                child.adapter?.session.store?.snapshot(windowId: child.windowID).spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
            } ?? []
        }
        func regularRowsUnchanged() -> Bool {
            guard let before = quitBefore, let rows = captureCheckRows() else { return false }
            func stable(_ rows: [[String]]) -> [[String]] {
                rows.filter { $0.count == 3 && $0[0] != "window" && $0[0] != "last_selected" }
            }
            return stable(before) == stable(rows)
        }

        switch browserCheckPhase {
        case 0:
            guard let row = snapshot.spaces.first(where: { $0.id == "default" })?.today.first, row.url != nil else { wait("seed row"); return }
            browserCheckSeedID = row.id
            selectCheckSeed(row)
            browserCheckPhase = 1
        case 1:
            guard let seed = browserCheckSeedID, snapshot.selectedId == seed, sliceActive == seed,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == seed }), !tab.isLoading,
                  let rows = captureCheckRows(), checkStoredTabMetadata(rows, item: seed, url: tab.url, title: tab.title) else {
                wait("regular seed selected"); return
            }
            browserCheckBefore = snapshot
            quitBefore = rows
            host.checkCreateIncognito()
            browserCheckPhase = 2
        case 2:
            guard let first = privateChildren().first, first.host?.isPrivateWindow() == true,
                  privateRows(first).count == 1 else { wait("first private window"); return }
            // A second private window of the same OTR profile shares the workspace.
            first.host?.checkCreateIncognito()
            browserCheckPhase = 3
        case 3:
            guard privateChildren().count == 2, PrivateWorkspaces.liveCount == 2,
                  let second = privateChildren().last, let snap = second.adapter?.session.queue.sync(execute: {
                      second.adapter?.session.store?.snapshot(windowId: second.windowID)
                  }), let space = snap.shownSpaceId else { wait("second private window"); return }
            second.adapter?.openCommandURL("about:blank?private-isolation", expectedSpace: space, profile: second.privateProfile ?? "Default")
            browserCheckPhase = 4
        case 4:
            guard privateChildren().count == 2,
                  let first = privateChildren().first, let second = privateChildren().last,
                  let snap = second.adapter?.session.queue.sync(execute: { second.adapter?.session.store?.snapshot(windowId: second.windowID) }),
                  let item = snap.spaces.first?.today.first(where: { $0.url == "about:blank?private-isolation" })?.id,
                  first.sidebar?.checkPrivateTodayRows.contains(item) == true else { wait("shared private row"); return }
            check.mark("private_shared")
            guard regularRowsUnchanged() else { wait("regular rows before child"); return }
            // A regular window opened from the root shares the regular store, never the private one.
            host.checkNewWindow()
            browserCheckPhase = 5
        case 5:
            guard let regular = regularChild(), regular.adapter?.session.queue.sync(execute: {
                      regular.adapter?.session.store?.snapshot(windowId: regular.windowID)
                  }) != nil,
                  let first = privateChildren().first, let second = privateChildren().last,
                  let privateItem = second.adapter?.session.queue.sync(execute: { second.adapter?.session.store?.snapshot(windowId: second.windowID) })
                      .flatMap({ $0.spaces.first?.today.first(where: { $0.url == "about:blank?private-isolation" })?.id }) else {
                wait("regular child window"); return
            }
            let regularIDs = Set(regularRows(regular))
            let privateIDs = Set(privateRows(first) + privateRows(second))
            check.mark("private_regular_hidden", !regularIDs.contains(privateItem))
            check.mark("private_rows_disjoint", regularIDs.isDisjoint(with: privateIDs) && !privateIDs.contains(browserCheckSeedID ?? ""))
            guard !regularIDs.contains(privateItem), regularIDs.isDisjoint(with: privateIDs) else {
                wait("regular and private rows disjoint"); return
            }
            guard let privateTab = (first.host?.tabs() as? [any ARTabAPI])?.first,
                  let privateHost = first.host, let regularHost = regular.host,
                  let regularTab = (regularHost.tabs() as? [any ARTabAPI])?.first,
                  !regularTab.isLoading, let regularItem = regularTab.itemId,
                  let rows = captureCheckRows(),
                  checkStoredTabMetadata(rows, item: regularItem, url: regularTab.url, title: regularTab.title) else { wait("tabs for the move"); return }
            quitBefore = rows
            let refused = !privateHost.checkMoveTab(privateTab, toHost: regularHost) && !regularHost.checkMoveTab(regularTab, toHost: privateHost)
            check.mark("private_cross_refused", refused)
            guard refused else { wait("refused cross move"); return }
            // Close the shared row, then Clear the remaining private tabs.
            check.pendingClose = privateItem
            first.close(privateItem)
            second.clearToday()
            browserCheckPhase = 6
        case 6:
            guard privateChildren().isEmpty, PrivateWorkspaces.liveCount == 0,
                  let regularSnapshot = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
                  regularSnapshot.today.contains(where: { $0.id == check.pendingClose }) == false,
                  !snapshot.archive.contains(where: { $0.id == check.pendingClose }),
                  regularRowsUnchanged() else { wait("private close and clear"); return }
            check.mark("private_close_clear")
            check.mark("private_archive_clean", snapshot.archive.isEmpty)
            check.mark("private_rows_unchanged", regularRowsUnchanged())
            host.checkCreateIncognito()
            browserCheckPhase = 60
        case 60:
            guard let first = privateChildren().first, PrivateWorkspaces.liveCount == 1,
                  let snap = first.adapter?.session.queue.sync(execute: { first.adapter?.session.store?.snapshot(windowId: first.windowID) }),
                  snap.spaces.first?.today.count == 1, snap.archive.isEmpty else { wait("new private window for the bar"); return }
            // The private command bar: open a URL, close it, reopen the bar; nothing was learned.
            check.learnTitle = "ararat-private-learn-\(UUID().uuidString)"
            check.learnURL = "data:text/html,<title>\(check.learnTitle)</title>"
            let space = first.snapshot.shownSpaceId ?? "private"
            first.adapter?.openCommandURL(check.learnURL, expectedSpace: space, profile: first.privateProfile ?? "Default")
            browserCheckPhase = 7
        case 7:
            guard let first = privateChildren().first,
                  let snap = first.adapter?.session.queue.sync(execute: { first.adapter?.session.store?.snapshot(windowId: first.windowID) }),
                  let row = snap.spaces.first?.today.first(where: { $0.title == check.learnTitle || $0.url == check.learnURL }) else {
                wait("learned private tab"); return
            }
            first.close(row.id)
            browserCheckPhase = 8
        case 8:
            guard let first = privateChildren().first,
                  let snap = first.adapter?.session.queue.sync(execute: { first.adapter?.session.store?.snapshot(windowId: first.windowID) }),
                  snap.spaces.first?.today.contains(where: { $0.id == check.pendingClose || $0.title == check.learnTitle }) == false else {
                wait("learned tab closed"); return
            }
            first.privateHistoryQueries = 0
            first.openCommandBar(.newTab)
            browserCheckPhase = 9
        case 9:
            guard let first = privateChildren().first, let presenter = first.commandPresenter else { wait("private bar"); return }
            presenter.controller.update(query: check.learnTitle)
            browserCheckPhase = 10
        case 10:
            guard let first = privateChildren().first, let presenter = first.commandPresenter else { wait("private bar query"); return }
            guard let typed = presenter.controller.result.rows.first, case .search = typed.target,
                  typed.title == check.learnTitle else { wait("private bar query session"); return }
            FileHandle.standardError.write(Data("ararat-trace: private-isolation query_rows=\(presenter.controller.result.rows.map { "\($0.title)|\($0.url ?? "nil")|\($0.target)" })\n".utf8))
            let noHistory = !presenter.controller.result.rows.contains { row in
                if case .history = row.target { return true } else { return false }
            }
            let noLearnedTab = !presenter.controller.result.rows.dropFirst().contains { row in
                row.title == check.learnTitle || row.url == check.learnURL
            }
            check.mark("private_bar_no_history", noHistory)
            check.mark("private_bar_no_learning", noLearnedTab && first.privateHistoryQueries == 0)
            presenter.close(restoreFocus: false)
            // The empty query lists recents from the private store; the closed tab must not be there.
            first.openCommandBar(.newTab)
            browserCheckPhase = 11
        case 11:
            guard let first = privateChildren().first, let presenter = first.commandPresenter else { wait("private bar recents"); return }
            presenter.controller.update(query: check.learnTitle)
            browserCheckPhase = 12
        case 12:
            guard let first = privateChildren().first, let presenter = first.commandPresenter,
                  let typed = presenter.controller.result.rows.first, case .search = typed.target,
                  typed.title == check.learnTitle else { wait("private bar recents session"); return }
            presenter.controller.update(query: "")
            FileHandle.standardError.write(Data("ararat-trace: private-isolation recent_rows=\(presenter.controller.result.rows.map { "\($0.title)|\($0.url ?? "nil")|\($0.target)" })\n".utf8))
            let recents = presenter.controller.result.rows.contains { row in
                row.title == check.learnTitle || row.url == check.learnURL
            }
            check.mark("private_bar_no_learning", check.conditions["private_bar_no_learning"] == true && !recents)
            presenter.close(restoreFocus: false)
            let result = check.diagnostics()
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty &&
                               host.checkStockBrowsers() == 0, values: result)
        default:
            break
        }
    }

    private func regularRows(_ child: Runtime) -> [String] {
        child.adapter?.session.queue.sync {
            child.adapter?.session.store?.snapshot(windowId: child.windowID).spaces.flatMap { $0.today + $0.pinned + $0.favorites }.map(\.id)
        } ?? []
    }
}
