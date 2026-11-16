import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

@MainActor
final class LiveBatchCheck {
    static func names(_ mode: String) -> [String] {
        mode == "auto-archive"
            ? ["seed", "loaded", "threshold_12h", "backdated_last_selected", "boundary_keeps_row", "row_removed", "engine_tab_closed", "pinned_stays", "selected_stays"]
            : ["seed", "loaded", "shown_space_deleted", "row_archived", "engine_tab_closed", "neighbour_shown", "neighbour_profile"]
    }
    var conditions: [String: Bool] = [:]
    var expiredAt: UInt64 = 0
    var started = false
    var profileBeforeDelete: String?

    func mark(_ mode: String, _ name: String, _ value: Bool) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: \(mode) \(name)=\(value)\n".utf8))
    }
    func diagnostics(_ mode: String) -> [String: Any] {
        ["conditions": Dictionary(uniqueKeysWithValues: Self.names(mode).map { ($0, conditions[$0] == true) }),
         "failed_conditions": Self.names(mode).filter { conditions[$0] != true }]
    }

    static func seed(_ session: WorkspaceSession, path: String, window: String) throws {
        try session.queue.sync {
            let store = try session.store ?? WorkspaceStore.open(path: path)
            guard store.snapshot(windowId: window).spaces.isEmpty else { throw CoreError.Edit(message: "Live batch checks require an empty workspace") }
            let json = #"{"sidebar":{"containers":[{}, {"spaces":["default",{"id":"default","title":"Default","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]},"named",{"id":"named","title":"Other","profile":{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"containerIDs":["pinned","other-pin","unpinned","other-today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":["pinned"],"data":{"itemContainer":{}}},"today",{"id":"today","parentID":null,"childrenIds":["expired","selected"],"data":{"itemContainer":{}}},"other-pin",{"id":"other-pin","parentID":null,"childrenIds":[],"data":{"itemContainer":{}}},"other-today",{"id":"other-today","parentID":null,"childrenIds":[],"data":{"itemContainer":{}}},"pinned",{"id":"pinned","parentID":"pin","childrenIds":[],"data":{"tab":{"savedURL":"about:blank?pinned"}}},"expired",{"id":"expired","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"about:blank?expired"}}},"selected",{"id":"selected","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"about:blank?selected"}}}]}]}}"#
            let old = Date().timeIntervalSince1970 - 978_307_200 - 13 * 3600
            let windows = "{\"windows\":[{\"expandedItems\":[],\"itemLastActiveDates\":[\"expired\",\(old),\"pinned\",\(old),\"selected\",\(old)]}]}"
            _ = try store.importArcSidebar(windowId: window, json: json, windowsJson: windows, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
            try store.showSpace(windowId: window, spaceId: "default")
            _ = try store.selectItem(windowId: window, id: "selected")
            session.store = store
        }
    }
}

extension Runtime {
    func liveBatchCheckTick(_ host: any ARWindowHostAPI, mode: String) {
        if liveBatchCheck == nil { liveBatchCheck = LiveBatchCheck() }
        guard let check = liveBatchCheck, let adapter, let workspace, let sidebar else { return }
        func mark(_ name: String, _ value: Bool = true) { check.mark(mode, name, value) }
        func tabs() -> [any ARTabAPI] { (host.tabs() as? [any ARTabAPI]) ?? [] }
        func finish() {
            let result = check.diagnostics(mode)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String])?.isEmpty == true, values: result)
        }
        switch browserCheckPhase {
        case 0:
            guard host.window().isVisible, let space = snapshot.spaces.first(where: { $0.id == "default" }),
                  let expired = space.today.first(where: { $0.id == "expired" }), let at = expired.lastSelectedAt else { return }
            check.expiredAt = at
            mark("seed", snapshot.spaces.count == 2 && space.pinned.contains { $0.id == "pinned" })
            adapter.select(id: "selected", url: "about:blank?selected")
            browserCheckPhase = 1
        case 1:
            guard host.activeItemId() == "selected", tabs().contains(where: { $0.itemId == "selected" && !$0.isLoading }) else { return }
            if mode == "delete-space-live" {
                mark("loaded")
                check.profileBeforeDelete = host.profileDirectory()
                browserCheckPhase = 4
                sidebar.onDeleteSpace?("default")
                return
            }
            do {
                for id in ["expired", "pinned"] {
                    let command = try adapter.session.queue.sync { try adapter.session.store!.liveOpen(item: id, url: "about:blank?\(id)") }
                    guard host.openBackgroundURL("about:blank?\(id)", commandId: command.id, itemId: id, profile: "Default", historyStamp: check.expiredAt) else {
                        mark("loaded", false); finish(); return
                    }
                }
                browserCheckPhase = 2
            } catch { report(error); finish() }
        case 2:
            guard ["expired", "pinned", "selected"].allSatisfy({ id in tabs().contains { $0.itemId == id && !$0.isLoading } }),
                  let current = adapter.session.queue.sync(execute: { adapter.session.store?.snapshot(windowId: windowID) }),
                  let space = current.spaces.first(where: { $0.id == "default" }),
                  let expired = space.today.first(where: { $0.id == "expired" }), !expired.unloaded else { return }
            mark("loaded")
            mark("threshold_12h", space.archiveAfter == .hours12)
            mark("backdated_last_selected", expired.lastSelectedAt == check.expiredAt && UInt64(Date().timeIntervalSince1970 * 1000) > check.expiredAt + 12 * 3_600_000)
            browserCheckPhase = 3
            workspace.autoArchive(now: check.expiredAt + 12 * 3_600_000) { [weak self] result in
                switch result {
                case .success(let next):
                    mark("boundary_keeps_row", next == nil)
                    check.started = true
                    self?.autoArchive?.start()
                case .failure(let error): self?.report(error); finish()
                }
            }
        case 3:
            guard check.started, snapshot.archive.contains(where: { $0.id == "expired" }),
                  !tabs().contains(where: { $0.itemId == "expired" }) else { return }
            mark("row_removed", sidebar.rowCheckInfo(id: "expired") == nil && !snapshot.spaces.flatMap(\.today).contains { $0.id == "expired" })
            mark("engine_tab_closed", !tabs().contains { $0.itemId == "expired" })
            mark("pinned_stays", snapshot.spaces.flatMap(\.pinned).contains { $0.id == "pinned" } && tabs().contains { $0.itemId == "pinned" })
            let selectedStays = snapshot.selectedId == "selected" && host.activeItemId() == "selected" && tabs().contains { $0.itemId == "selected" }
            browserCheckPhase = 5
            workspace.autoArchive(now: UInt64(Date().timeIntervalSince1970 * 1000) + 13 * 3_600_000) { [weak self] result in
                switch result {
                case .success(let next): mark("selected_stays", selectedStays && next == nil); finish()
                case .failure(let error): self?.report(error); finish()
                }
            }
        case 4:
            guard !snapshot.spaces.contains(where: { $0.id == "default" }), !tabs().contains(where: { $0.itemId == "selected" }) else { return }
            mark("shown_space_deleted")
            mark("row_archived", snapshot.archive.contains { $0.id == "selected" })
            mark("engine_tab_closed", !tabs().contains { ["selected", "expired", "pinned"].contains($0.itemId ?? "") })
            mark("neighbour_shown", snapshot.shownSpaceId == "named")
            mark("neighbour_profile", check.profileBeforeDelete != nil && check.profileBeforeDelete != "Profile 1" && host.profileDirectory() == "Profile 1")
            finish()
        default: break
        }
    }
}
