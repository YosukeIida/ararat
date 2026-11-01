import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private func adapterValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@Test @MainActor
func adapterRunsOffMainInOrderAndDeliversErrorsOnMain() async {
    let adapter = WorkspaceAdapter(windowID: "test")
    let gate = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        var order: [Int] = []
        let record: @MainActor @Sendable (Int) -> Void = { value in
            #expect(Thread.isMainThread)
            order.append(value)
            if order.count == 3 { #expect(order == [1, 2, 3]); done.resume() }
        }
        adapter.enqueue({ gate.wait(); return Thread.isMainThread ? -1 : 1 }) { result in
            record((try? result.get()) ?? -1)
        }
        adapter.enqueue({ Thread.isMainThread ? -2 : 2 }) { result in
            record((try? result.get()) ?? -2)
        }
        adapter.enqueue({ () throws -> Int in throw CoreError.Edit(message: "probe") }) { result in
            #expect(throws: CoreError.self) { try result.get() }
            record(3)
        }
    }
}

@Test @MainActor
func twoQueuedCommandWRequestsCloseTheCoreSuccessorsInOrder() async throws {
    let directory = try testTemporaryDirectory()
    let expectedRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try #require(directory.deletingLastPathComponent().standardizedFileURL == expectedRoot.standardizedFileURL)
    let path = directory.appendingPathComponent("workspace.sqlite").path
    let adapter = WorkspaceAdapter(windowID: "test-window")
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work", {"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":[],"data":{"itemContainer":{}}},"today",{"id":"today","parentID":null,"childrenIds":["a","b","c"],"data":{"itemContainer":{}}},"a",{"id":"a","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://a.example"}}},"b",{"id":"b","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://b.example"}}},"c",{"id":"c","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://c.example"}}}]}]}}"#
    _ = try await adapterValue { adapter.open(path: path, json: { json }, completion: $0) }
    let selected = try await adapterValue { adapter.select(id: "a", completion: $0) }
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: selected)
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    let results = await withCheckedContinuation { (done: CheckedContinuation<[WorkspaceAdapter.Change], Never>) in
        var changes: [WorkspaceAdapter.Change] = []
        var replies = 0
        let apply: WorkspaceAdapter.Completion<WorkspaceAdapter.Change> = { [weak sidebar] result in
            switch result {
            case .success(let change):
                changes.append(change)
                if let id = change.id { sidebar?.applyClose(id: id, snapshot: change.snapshot) }
            case .failure(let error): Issue.record("unexpected close failure: \(error)")
            }
            replies += 1
            if replies == 2 { done.resume(returning: changes) }
        }
        sidebar.onClose = { _ in adapter.closeSelected(completion: apply) }
        let menu = NSMenu()
        let close = menu.addItem(withTitle: "Close Tab", action: #selector(SidebarView.closeSelectedTab(_:)), keyEquivalent: "w")
        close.target = sidebar
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        #expect(menu.performKeyEquivalent(with: key))
        #expect(sidebar.selectedRowID == "a")
        #expect(menu.performKeyEquivalent(with: key))
    }
    try #require(results.count == 2)
    #expect(results.map(\.id) == ["a", "b"])
    #expect(results.map { $0.snapshot.selectedId } == ["b", "c"])
    #expect(results[1].snapshot.spaces[0].today.map(\.id) == ["c"])
    #expect(sidebar.selectedRowID == "c")
    _ = try await adapterValue { adapter.flush(completion: $0) }
    _ = try await adapterValue { adapter.shutdown(completion: $0) }
    let reopened = WorkspaceAdapter(windowID: "test-window")
    let restored = try await adapterValue { reopened.open(path: path, json: { "invalid" }, completion: $0) }
    #expect(restored == results[1].snapshot)
    _ = try await adapterValue { reopened.shutdown(completion: $0) }
}

@MainActor
private func adapterDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + adapterDescendants($0) }
}

@Test @MainActor
func unloadedRowsAndTilesDimWithoutLeavingTheirLayout() throws {
    var pinned = Row(id: "p", title: "Pinned", url: nil, depth: 0, kind: .tab, unloaded: false)
    var favorite = Row(id: "f", title: "Favorite", url: nil, depth: 0, kind: .tab, unloaded: false)
    let today = Row(id: "t", title: "Today", url: nil, depth: 0, kind: .tab, unloaded: false)
    let snapshot: ([Row], [Row]) -> WorkspaceSnapshot = { pins, favorites in
        WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: "t", spaces: [SpaceSnapshot(id: "work", title: "Work", icon: nil, favorites: favorites, pinned: pins, today: [today])])
    }
    let sidebar = SidebarView(snapshot: snapshot([pinned], [favorite]))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    let row = try #require(adapterDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "p" })
    let tile = try #require(adapterDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first)
    let icon = try #require(tile.subviews.compactMap { $0 as? NSImageView }.first)
    let frame = row.frame
    pinned.unloaded = true; favorite.unloaded = true
    sidebar.applyClose(id: "p", snapshot: snapshot([pinned], [favorite]))
    #expect(row.row.unloaded && tile.row.unloaded)
    #expect(row.frame == frame)
    #expect(row.layer?.animation(forKey: "row.close.fade") == nil)
    #expect(row.layer?.animation(forKey: "row.close.move") == nil)
    #expect(try #require(row.subviews.compactMap { $0 as? NSImageView }.first).alphaValue == SidebarMetrics.unloadedOpacity)
    #expect(try #require(row.subviews.compactMap { $0 as? NSTextField }.first).alphaValue == SidebarMetrics.unloadedOpacity)
    let favicon = NSImage(size: NSSize(width: 16, height: 16))
    favicon.isTemplate = false
    icon.image = favicon
    #expect(icon.alphaValue == SidebarMetrics.unloadedOpacity)
    #expect(icon.image?.isTemplate == false)
    #expect(tile.alphaValue == 1)
    pinned.unloaded = false; favorite.unloaded = false
    sidebar.applySelection(snapshot: snapshot([pinned], [favorite]))
    #expect(!row.row.unloaded && !tile.row.unloaded)
    #expect(icon.alphaValue == 1)
}
