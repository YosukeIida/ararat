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

@Test(arguments: ["select", "createTab"]) @MainActor
func selectionRepliesKeepNewerSelectionAndCreatedTabIdentity(route: String) async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                          windowID: "organize", card: NSView(), seedOrganize: true, session: session)
    let store = try #require(session.store)
    let before = session.queue.sync { store.snapshot(windowId: "organize") }
    let space = try #require(before.spaces.first { $0.id == "organize-work" })
    let first = try #require(space.today.first?.id)
    let newer = try #require(space.pinned.first { $0.kind == .tab }?.id)
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: before)
    let adapter = WorkspaceAdapter(windowID: "organize", session: session)
    let replies = AsyncStream<WorkspaceAdapter.Change>.makeStream()
    defer { replies.continuation.finish() }
    let receive: WorkspaceAdapter.Completion<WorkspaceAdapter.Change> = { result in
        guard case .success(let change) = result else { Issue.record("selection unexpectedly failed"); replies.continuation.finish(); return }
        sidebar.applySelection(snapshot: change.snapshot)
        replies.continuation.yield(change)
    }
    if route == "select" {
        adapter.select(id: first) { result in receive(result.map { (first, $0) }) }
    } else {
        adapter.createTab(url: "https://created.example/", completion: receive)
    }
    let (operationID, selected) = try session.queue.sync {
        let operationID = try #require(store.snapshot(windowId: "organize").selectedId)
        return (operationID, try store.selectItem(windowId: "organize", id: newer))
    }
    sidebar.applySelection(snapshot: selected)
    var iterator = replies.stream.makeAsyncIterator()
    let delivered = try #require(await iterator.next())
    #expect(delivered.id == operationID)
    #expect(delivered.snapshot == selected)
    #expect(sidebar.selectedRowID == newer)
    if route == "createTab" {
        #expect(operationID != newer)
        #expect(delivered.snapshot.spaces.flatMap(\.today).contains { $0.id == operationID && $0.url == "https://created.example/" })
    }
}

@Test @MainActor
func refusedLiveMoveStaysNilAfterNewerSelection() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    _ = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                          windowID: "organize", card: NSView(), seedOrganize: true, session: session)
    let store = try #require(session.store)
    let before = session.queue.sync { store.snapshot(windowId: "organize") }
    let space = try #require(before.spaces.first { $0.id == "organize-work" })
    let id = try #require(space.today.first?.id)
    let adapter = WorkspaceAdapter(windowID: "organize", session: session)
    let replies = AsyncStream<Result<WorkspaceSnapshot?, Error>>.makeStream()
    defer { replies.continuation.finish() }
    adapter.moveIfLive(id: id, container: space.pinnedId, index: 0, openFolder: false, expectedLive: "stale") { replies.continuation.yield($0) }
    let selected = try session.queue.sync { try store.selectItem(windowId: "organize", id: id) }
    var iterator = replies.stream.makeAsyncIterator()
    let delivered = try #require(await iterator.next())
    #expect(try delivered.get() == nil)
    #expect(session.queue.sync { store.snapshot(windowId: "organize") } == selected)
    #expect(selected.spaces.first { $0.id == space.id }?.today.contains { $0.id == id } == true)
}

@Test @MainActor
func missingAndMalformedWindowsKeepTheSidebarImportAvailable() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    for malformed in [false, true] {
        let adapter = WorkspaceAdapter(windowID: "windows-import")
        let reports = AsyncStream<ImportReport>.makeStream()
        let missing = directory.appendingPathComponent("absent-windows.json")
        let snapshot = try await adapterValue {
            adapter.open(path: directory.appendingPathComponent("\(malformed).sqlite").path, json: { json }, windowsJSON: {
                let data = malformed ? Data([0xff]) : (try? Data(contentsOf: missing))
                return data.map { String(decoding: $0, as: UTF8.self) }
            }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, onImport: { reports.continuation.yield($0) }, completion: $0)
        }
        #expect(snapshot.spaces.count == 2)
        var iterator = reports.stream.makeAsyncIterator()
        let report = try #require(await iterator.next())
        #expect(report.missingWindows == !malformed)
        #expect((report.windowsError != nil) == malformed)
        reports.continuation.finish()
        _ = try await adapterValue { adapter.shutdown(completion: $0) }
    }
}

@Test @MainActor
func twoQueuedCommandWRequestsArchiveTodayInSuccessorOrder() async throws {
    let directory = try testTemporaryDirectory()
    let expectedRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try #require(directory.deletingLastPathComponent().standardizedFileURL == expectedRoot.standardizedFileURL)
    let path = directory.appendingPathComponent("workspace.sqlite").path
    let adapter = WorkspaceAdapter(windowID: "test-window")
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work", {"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":[],"data":{"itemContainer":{}}},"today",{"id":"today","parentID":null,"childrenIds":["a","b","c"],"data":{"itemContainer":{}}},"a",{"id":"a","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://a.example"}}},"b",{"id":"b","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://b.example"}}},"c",{"id":"c","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://c.example"}}}]}]}}"#
    _ = try await adapterValue { adapter.open(path: path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    for id in ["c", "b"] { _ = try await adapterValue { adapter.select(id: id, completion: $0) } }
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
        // R1: a Today tab’s ⌘W archives it; the adapter applies the rule to the core’s
        // current selection, so both presses act in order.
        sidebar.onCloseSelected = { adapter.closeSelected(completion: apply) }
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
    let restored = try await adapterValue { reopened.open(path: path, json: { "invalid" }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    #expect(restored == results[1].snapshot)
    _ = try await adapterValue { reopened.shutdown(completion: $0) }
}

@MainActor
private func adapterDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + adapterDescendants($0) }
}

@Test @MainActor
func unloadedRowsAndTilesDimWithoutLeavingTheirLayout() throws {
    var pinned = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "p", title: "Pinned", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    var favorite = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "f", title: "Favorite", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let today = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "t", title: "Today", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil)
    let snapshot: ([Row], [Row]) -> WorkspaceSnapshot = { pins, favorites in
        WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: "t", spaces: [SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: "work", title: "Work", icon: nil, look: nil, favorites: favorites, pinned: pins, today: [today])])
    }
    let sidebar = SidebarView(snapshot: snapshot([pinned], [favorite]))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    sidebar.layoutSubtreeIfNeeded()
    let row = try #require(adapterDescendants(sidebar).compactMap { $0 as? SidebarRowView }.first { $0.row.id == "p" })
    let tile = try #require(adapterDescendants(sidebar).compactMap { $0 as? FavoriteTile }.first)
    let frame = row.frame
    pinned.unloaded = true; favorite.unloaded = true
    sidebar.applyClose(id: "p", snapshot: snapshot([pinned], [favorite]))
    #expect(row.row.unloaded && tile.row.unloaded)
    #expect(row.frame == frame)
    #expect(row.layer?.animation(forKey: "row.close.fade") == nil)
    #expect(row.layer?.animation(forKey: "row.close.move") == nil)
    #expect(try #require(row.subviews.compactMap { $0 as? NSImageView }.first).alphaValue == SidebarMetrics.unloadedOpacity)
    #expect(try #require(row.subviews.compactMap { $0 as? NSTextField }.first).alphaValue == SidebarMetrics.unloadedOpacity)
    let unloadedGlyph = try #require(tile.glyphLabel.textColor)
    #expect(tile.alphaValue == 1)
    pinned.unloaded = false; favorite.unloaded = false
    sidebar.applySelection(snapshot: snapshot([pinned], [favorite]))
    #expect(!row.row.unloaded && !tile.row.unloaded)
    let loadedGlyph = try #require(tile.glyphLabel.textColor)
    #expect(loadedGlyph == .labelColor)
    #expect(abs(unloadedGlyph.alphaComponent - loadedGlyph.alphaComponent * SidebarMetrics.unloadedOpacity) < 0.001)
}

@Test @MainActor
func adapterDuplicateEditPublishesTheCopyAndPersistsIt() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("duplicate.sqlite").path
    let adapter = WorkspaceAdapter(windowID: "duplicate")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let before = try await adapterValue { adapter.open(path: path, json: { json }, windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0) }
    let after = try await adapterValue { adapter.edit(.duplicate(id: "tab-mail"), completion: $0) }
    let favorites = try #require(after.spaces.first?.favorites)
    #expect(favorites.count == 2)
    #expect(favorites[0].id == "tab-mail")
    #expect(favorites[1].id != "tab-mail" && favorites[1].unloaded)
    #expect(after.selectedId == before.selectedId)
    _ = try await adapterValue { adapter.shutdown(completion: $0) }
    let reopened = try WorkspaceStore.open(path: path).snapshot(windowId: "duplicate")
    #expect(reopened.spaces.first?.favorites.map(\.id) == favorites.map(\.id))
}

@Test @MainActor
func keyBindingImportReportsSkippedAndMalformedDataWithoutBlockingSidebar() async throws {
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sidebar = try String(contentsOf: root.appendingPathComponent("core/ararat-core/tests/fixtures/arc-sidebar-synthetic.json"), encoding: .utf8)
    let inputs: [Data?] = [nil, Data(#"{"version":1,"userOverrides":[]}"#.utf8), Data(#"{"version":1,"userOverrides":[{"opaque":true}]}"#.utf8), Data([0xff])]
    for (index, data) in inputs.enumerated() {
        let adapter = WorkspaceAdapter(windowID: "key-bindings-import")
        let reports = AsyncStream<ImportReport>.makeStream()
        let snapshot = try await adapterValue {
            adapter.open(path: directory.appendingPathComponent("keys-\(index).sqlite").path, json: { sidebar }, windowsJSON: { nil }, keyBindingsJSON: {
                data.map { String(decoding: $0, as: UTF8.self) }
            }, linkRoutingJSON: { nil }, onImport: { reports.continuation.yield($0) }, completion: $0)
        }
        #expect(snapshot.spaces.count == 2)
        var iterator = reports.stream.makeAsyncIterator()
        let report = try #require(await iterator.next())
        #expect(report.missingKeyBindings == (index == 0))
        #expect(report.skippedKeyBindings == (index == 2 ? 1 : 0))
        #expect((report.keyBindingsError != nil) == (index == 3))
        reports.continuation.finish()
        _ = try await adapterValue { adapter.shutdown(completion: $0) }
    }
}
