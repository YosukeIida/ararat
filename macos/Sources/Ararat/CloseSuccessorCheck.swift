import AppKit
import AraratEngineAPI
import AraratKit

// Closing the only loaded tab of an imported space. Arc's import writes the rows Unloaded,
// so the successor the core picks is an unloaded neighbour: it must be selected and loaded
// the way a click loads it, and nothing else of the import may load.
@MainActor
final class CloseSuccessorCheck {
    static let mode = "close-successor"
    static let conditionNames = ["seed", "opened", "successor_selected", "successor_loaded", "no_other_row_loaded", "closed_row_archived"]
    var conditions: [String: Bool] = [:]

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: close-successor \(name)=\(value)\n".utf8))
    }

    func diagnostics() -> [String: Any] {
        ["conditions": Dictionary(uniqueKeysWithValues: Self.conditionNames.map { ($0, conditions[$0] == true) }),
         "failed_conditions": Self.conditionNames.filter { conditions[$0] != true }]
    }

    static func seed(_ session: WorkspaceSession, path: String, window: String) throws {
        try session.queue.sync {
            let store = try session.store ?? WorkspaceStore.open(path: path)
            guard store.snapshot(windowId: window).spaces.isEmpty else { throw CoreError.Edit(message: "the close-successor check needs an empty workspace") }
            let json = #"{"sidebar":{"containers":[{},{"spaces":["space-successor",{"id":"space-successor","title":"Successor","profile":{"default":true},"containerIDs":["pinned","pin-successor","unpinned","today-successor"]}],"items":["pin-successor",{"id":"pin-successor","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-successor"}}}}},"today-successor",{"id":"today-successor","parentID":null,"childrenIds":["succ-a","succ-b","succ-c"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"space-successor"}}}}},"succ-a",{"id":"succ-a","parentID":"today-successor","childrenIds":[],"data":{"tab":{"savedURL":"about:blank?successor-a","savedTitle":"A"}}},"succ-b",{"id":"succ-b","parentID":"today-successor","childrenIds":[],"data":{"tab":{"savedURL":"about:blank?successor-b","savedTitle":"B"}}},"succ-c",{"id":"succ-c","parentID":"today-successor","childrenIds":[],"data":{"tab":{"savedURL":"about:blank?successor-c","savedTitle":"C"}}}]}]}}"#
            _ = try store.importArcSidebar(windowId: window, json: json, windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
            try store.showSpace(windowId: window, spaceId: "space-successor")
            session.store = store
        }
    }
}

extension Runtime {
    func closeSuccessorCheckTick(_ host: any ARWindowHostAPI) {
        if closeSuccessorCheck == nil { closeSuccessorCheck = CloseSuccessorCheck() }
        guard let check = closeSuccessorCheck, let adapter else { return }
        let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
        func mark(_ name: String, _ value: Bool = true) { check.mark(name, value) }
        func liveTab(_ id: String) -> String? { adapter.session.queue.sync { adapter.session.store?.liveTab(item: id) } }
        func row(_ id: String) -> Row? { snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.first { $0.id == id } }
        func finish() {
            let result = check.diagnostics()
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String])?.isEmpty == true, values: result)
        }
        switch browserCheckPhase {
        case 0:
            guard host.window().isVisible, let space = snapshot.spaces.first(where: { $0.id == "space-successor" }),
                  space.today.map(\.id) == ["succ-a", "succ-b", "succ-c"] else { return }
            mark("seed", space.today.allSatisfy(\.unloaded) && snapshot.selectedId == nil)
            adapter.select(id: "succ-a", url: "about:blank?successor-a")
            browserCheckPhase = 1
        case 1:
            guard liveTab("succ-a") != nil, host.activeItemId() == "succ-a",
                  tabs.contains(where: { $0.itemId == "succ-a" && !$0.isLoading }), tabs.count == 1 else { return }
            mark("opened")
            adapter.close(id: "succ-a")
            browserCheckPhase = 2
        case 2:
            guard snapshot.selectedId == "succ-b" else { return }
            mark("successor_selected")
            mark("successor_loaded", liveTab("succ-b") != nil && row("succ-b")?.unloaded == false
                 && tabs.contains { $0.itemId == "succ-b" && !$0.isLoading })
            mark("no_other_row_loaded", liveTab("succ-a") == nil && liveTab("succ-c") == nil && tabs.count == 1)
            mark("closed_row_archived", snapshot.archive.contains { $0.id == "succ-a" })
            finish()
        default: break
        }
    }
}
