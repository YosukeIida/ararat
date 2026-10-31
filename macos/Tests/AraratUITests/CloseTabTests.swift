import AppKit
import AraratKit
import Testing
@testable import AraratUI

private func closeSnapshot(_ ids: [String], selected: String? = nil, pinned: Bool = false) -> WorkspaceSnapshot {
    let row: (String) -> Row = { Row(id: $0, title: $0, url: "https://\($0).example", depth: 0, kind: .tab) }
    return WorkspaceSnapshot(selectedId: selected, spaces: [SpaceSnapshot(id: "work", title: "Work", icon: nil,
        favorites: [], pinned: pinned ? [row("pin")] : [], today: ids.map(row))])
}

@MainActor
private func closeViews(_ view: NSView) -> [SidebarRowView] {
    view.subviews.flatMap { ($0 as? SidebarRowView).map { [$0] } ?? closeViews($0) }
}

@MainActor
private func closeSidebar(_ snapshot: WorkspaceSnapshot) -> SidebarView {
    let view = SidebarView(snapshot: snapshot)
    view.frame = NSRect(x: 0, y: 0, width: 240, height: 720)
    view.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    return view
}

@Test @MainActor
func closeMiddleMovesOnlyRowsBelowAndRetainsInstances() throws {
    let sidebar = closeSidebar(closeSnapshot(["a", "b", "c", "d"], selected: "b"))
    let before = Dictionary(uniqueKeysWithValues: closeViews(sidebar).map { ($0.row.id, $0) })
    let next = closeSnapshot(["a", "c", "d"], selected: "c")
    sidebar.applyClose(id: "b", snapshot: next)
    #expect(sidebar.selectedRowID == "c")
    #expect(before["b"]?.superview == nil)
    for id in ["a", "c", "d"] {
        let view = try #require(closeViews(sidebar).first { $0.row.id == id })
        #expect(view === before[id])
        let animation = view.layer?.animation(forKey: "row.close.move") as? CABasicAnimation
        if id == "a" { #expect(animation == nil) }
        else {
            #expect(abs(try #require(animation?.fromValue as? Double)) == 41)
            #expect(animation?.toValue as? Double == 0)
            #expect(animation?.duration == 0.120)
            #expect(animation?.timingFunction == SidebarMetrics.easeOutCubic)
        }
        #expect(view.layer?.animation(forKey: "row.close.fade") == nil)
    }
    sidebar.update(snapshot: next)
    sidebar.layoutSubtreeIfNeeded()
    let fresh = closeSidebar(next)
    #expect(ReuseTree(sidebar, in: sidebar) == ReuseTree(fresh, in: fresh))
}

@Test @MainActor
func closeLastFadesThenRemovesThroughTheSameRemovalPoint() throws {
    for ids in [["a", "b"], ["b"]] {
        let sidebar = closeSidebar(closeSnapshot(ids, selected: "b", pinned: true))
        let row = try #require(closeViews(sidebar).first { $0.row.id == "b" })
        let oldFrame = sidebar.convert(row.bounds, from: row)
        let next = closeSnapshot(Array(ids.dropLast()), selected: ids.count == 1 ? nil : "a", pinned: true)
        sidebar.applyClose(id: "b", snapshot: next)
        #expect(row.superview === sidebar)
        #expect(row.frame == oldFrame)
        let fade = try #require(row.layer?.animation(forKey: "row.close.fade") as? CABasicAnimation)
        #expect(fade.fromValue as? Double == 1)
        #expect(fade.toValue as? Double == 0)
        #expect(fade.duration == 0.110)
        #expect(!row.acceptsKeyboardFocus)
        #expect(!row.accessibilityPerformPress())
        #expect(closeViews(sidebar).filter { $0 !== row }.allSatisfy { $0.layer?.animation(forKey: "row.close.move") == nil })
        sidebar.update(snapshot: next)
        sidebar.layoutSubtreeIfNeeded()
        #expect(row.superview == nil)
        let fresh = closeSidebar(next)
        #expect(ReuseTree(sidebar, in: sidebar) == ReuseTree(fresh, in: fresh))
    }
}

@Test @MainActor
func swiftStoreCloseSurvivesReopenAndDrivesSidebarSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ararat-close-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("workspace.sqlite").path
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work", {"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":[],"data":{"itemContainer":{}}},"today",{"id":"today","parentID":null,"childrenIds":["a","b"],"data":{"itemContainer":{}}},"a",{"id":"a","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://a.example"}}},"b",{"id":"b","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://b.example"}}}]}]}}"#
    let closed: WorkspaceSnapshot
    do {
        let store = try WorkspaceStore.open(path: path)
        _ = try store.importArcSidebar(json: json)
        let selected = try store.selectItem(id: "a")
        let sidebar = closeSidebar(selected)
        #expect(sidebar.selectedRowID == "a")
        closed = try store.closeTodayTab(id: "a")
        sidebar.applyClose(id: "a", snapshot: closed)
        #expect(sidebar.selectedRowID == "b")
        #expect(!closeViews(sidebar).contains { $0.row.id == "a" })
    }
    let reopened = try WorkspaceStore.open(path: path)
    #expect(reopened.snapshot() == closed)
    #expect(reopened.snapshot().spaces[0].today.map(\.id) == ["b"])
    #expect(throws: CoreError.self) { try reopened.closeTodayTab(id: "missing") }
    #expect(reopened.snapshot() == closed)
}

@MainActor
private func holdClosePresentation(_ offset: CGFloat, on view: NSView) async throws {
    let animation = CABasicAnimation(keyPath: "transform.translation.y")
    animation.fromValue = offset
    animation.toValue = offset
    animation.duration = 60
    view.layer?.add(animation, forKey: "row.close.move")
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(20))
    #expect(try #require(view.layer?.presentation()).transform.m42 == offset)
    #expect(view.layer?.transform.m42 == 0)
}

@Test @MainActor
func secondCloseContinuesFromThePresentedRowPosition() async throws {
    _ = NSApplication.shared
    let sidebar = closeSidebar(closeSnapshot(["a", "b", "c", "d"], selected: "b"))
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.orderOut(nil); window.contentView = nil }
    window.displayIfNeeded()
    sidebar.applyClose(id: "b", snapshot: closeSnapshot(["a", "c", "d"], selected: "c"))
    let row = try #require(closeViews(sidebar).first { $0.row.id == "d" })
    try await holdClosePresentation(-17, on: row)
    let parent = try #require(row.superview)
    let frame = try #require(row.layer?.presentation()).frame
    let presented = sidebar.convert(frame, from: parent)
    sidebar.applyClose(id: "c", snapshot: closeSnapshot(["a", "d"], selected: "d"))
    let motion = try #require(row.layer?.animation(forKey: "row.close.move") as? CABasicAnimation)
    let expected = parent.convert(presented, from: sidebar).minY - row.frame.minY
    #expect(motion.fromValue as? Double == Double(expected))
    #expect(abs(expected) == 58)
    #expect(closeViews(sidebar).first { $0.row.id == "d" } === row)
}

@Test @MainActor
func closingTheMovingLastRowFadesAtItsPresentedPosition() async throws {
    _ = NSApplication.shared
    let sidebar = closeSidebar(closeSnapshot(["a", "b", "c"]))
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.orderOut(nil); window.contentView = nil }
    window.displayIfNeeded()
    sidebar.applyClose(id: "b", snapshot: closeSnapshot(["a", "c"]))
    let row = try #require(closeViews(sidebar).first { $0.row.id == "c" })
    try await holdClosePresentation(-17, on: row)
    let presented = sidebar.convert(try #require(row.layer?.presentation()).frame, from: row.superview)
    sidebar.applyClose(id: "c", snapshot: closeSnapshot(["a"]))
    #expect(row.frame == presented)
    #expect(row.layer?.animation(forKey: "row.close.move") == nil)
    #expect(row.layer?.animation(forKey: "row.close.fade") != nil)
}

@Test @MainActor
func fadeCompletionRemovesTheRetiredRowAndLeavesTheFreshLayout() async throws {
    _ = NSApplication.shared
    let sidebar = closeSidebar(closeSnapshot(["a"], selected: "a", pinned: true))
    let window = NSWindow(contentRect: sidebar.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.orderOut(nil); window.contentView = nil }
    window.displayIfNeeded()
    let retired = try #require(closeViews(sidebar).first { $0.row.id == "a" })
    let next = closeSnapshot([], pinned: true)
    let fresh = closeSidebar(next)
    let freshWindow = NSWindow(contentRect: fresh.bounds, styleMask: [], backing: .buffered, defer: false)
    freshWindow.contentView = fresh
    defer { freshWindow.orderOut(nil); freshWindow.contentView = nil }
    freshWindow.displayIfNeeded()
    sidebar.applyClose(id: "a", snapshot: next)
    CATransaction.flush()
    for _ in 0..<250 {
        if retired.superview == nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(retired.superview == nil)
    sidebar.layoutSubtreeIfNeeded()
    fresh.layoutSubtreeIfNeeded()
    #expect(ReuseTree(sidebar, in: sidebar) == ReuseTree(fresh, in: fresh))
}

@Test @MainActor
func commandWClosesTheSelectedSplitAndContinuesToTheNextTab() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ararat-split-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("workspace.sqlite").path
    let json = #"{"sidebar":{"containers":[{}, {"spaces":["work", {"id":"work","title":"Work","profile":{"default":true},"containerIDs":["pinned","pin","unpinned","today"]}],"items":["pin",{"id":"pin","parentID":null,"childrenIds":[],"data":{"itemContainer":{}}},"today",{"id":"today","parentID":null,"childrenIds":["split","d"],"data":{"itemContainer":{}}},"split",{"id":"split","parentID":"today","childrenIds":["b","c"],"data":{"splitView":{"layoutOrientation":"horizontal"}}},"b",{"id":"b","parentID":"split","childrenIds":[],"data":{"tab":{"savedURL":"https://b.example"}}},"c",{"id":"c","parentID":"split","childrenIds":[],"data":{"tab":{"savedURL":"https://c.example"}}},"d",{"id":"d","parentID":"today","childrenIds":[],"data":{"tab":{"savedURL":"https://d.example"}}}]}]}}"#
    let store = try WorkspaceStore.open(path: path)
    _ = try store.importArcSidebar(json: json)
    let selected = try store.selectItem(id: "split")
    let sidebar = closeSidebar(selected)
    let survivor = try #require(closeViews(sidebar).first { $0.row.id == "d" })
    var failure: Error?
    sidebar.onClose = { [weak sidebar] id in
        do { sidebar?.applyClose(id: id, snapshot: try store.closeTodayTab(id: id)) }
        catch { failure = error }
    }
    let menu = NSMenu()
    let close = menu.addItem(withTitle: "Close Tab", action: #selector(SidebarView.closeSelectedTodayTab(_:)), keyEquivalent: "w")
    close.target = sidebar
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    #expect(menu.performKeyEquivalent(with: key))
    #expect(failure == nil)
    #expect(store.snapshot().spaces[0].today.map(\.id) == ["d"])
    #expect(sidebar.selectedRowID == "d")
    #expect(closeViews(sidebar).first === survivor)
    let motion = try #require(survivor.layer?.animation(forKey: "row.close.move") as? CABasicAnimation)
    #expect(abs(try #require(motion.fromValue as? Double)) == 123)
    #expect(menu.performKeyEquivalent(with: key))
    #expect(store.snapshot().spaces[0].today.isEmpty)
    #expect(store.snapshot().selectedId == nil)
    #expect(try WorkspaceStore.open(path: path).snapshot().spaces[0].today.isEmpty)
}

@Test @MainActor
func closingATerminalSplitFadesItsLastMember() throws {
    let split = Row(id: "split", title: "", url: nil, depth: 0, kind: .split)
    let members = ["b", "c"].map { Row(id: $0, title: $0, url: nil, depth: 1, kind: .tab) }
    let before = WorkspaceSnapshot(selectedId: "split", spaces: [SpaceSnapshot(id: "work", title: "Work", icon: nil,
        favorites: [], pinned: [], today: [split] + members)])
    let sidebar = closeSidebar(before)
    let last = try #require(closeViews(sidebar).first { $0.row.id == "c" })
    let next = closeSnapshot([])
    sidebar.applyClose(id: "split", snapshot: next)
    #expect(last.superview === sidebar)
    #expect(last.layer?.animation(forKey: "row.close.fade") != nil)
    #expect(!closeViews(sidebar).contains { $0.row.id == "split" || $0.row.id == "b" })
    sidebar.update(snapshot: next)
    sidebar.layoutSubtreeIfNeeded()
    let fresh = closeSidebar(next)
    #expect(ReuseTree(sidebar, in: sidebar) == ReuseTree(fresh, in: fresh))
}
