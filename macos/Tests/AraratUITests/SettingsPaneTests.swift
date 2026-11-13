import AppKit
import AraratKit
import SwiftUI
import Testing
@testable import AraratUI

// U27a: the pane registry drives the rail, its order and the search index (D1), and the search
// has its own keyboard model (D7: first result selected, arrows move, Return opens).
@MainActor
private func settingsTestModel(spaces: [SpaceSnapshot] = []) -> SettingsModel {
    SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: spaces.first?.id, selectedId: nil, spaces: spaces),
                  adapter: WorkspaceAdapter(windowID: "u27a-registry"), publish: { _ in }, resetWidth: {},
                  keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "u27a-keys")),
                  airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "u27a-atc")))
}

@MainActor
private func settingsTestSpace(_ id: String, title: String, today: [Row] = []) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil,
                  archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: id, title: title, icon: nil,
                  look: nil, favorites: [], pinned: [], today: today)
}

@Test @MainActor
func theProbeSeesTheFrameTheRailAndTheHitTheScreenCheckReads() async throws {
    _ = NSApplication.shared
    let spaces = [settingsTestSpace("a", title: "Alpha"), settingsTestSpace("b", title: "Beta")]
    let model = settingsTestModel(spaces: spaces)
    model.shortcuts = (0..<30).map {
        SettingsModel.Row(id: "key-\($0)", pane: .shortcuts, title: "Utility \($0)", subtitle: "Perform action \($0)")
    }
    model.navigate(.tabs)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    window.contentView?.layoutSubtreeIfNeeded()
    let probe = try #require(controller.checkProbe())

    try await waitUntil { probe.layout(); return probe.railRows.count == probe.railPanes.count }
    #expect(probe.railRows.map(\.id) == ["rail-appearance", "rail-tabs", "rail-shortcuts", "rail-air-traffic", "rail-spaces"])
    #expect(abs((probe.railWidth ?? 0) - 180) <= 1)
    #expect(probe.railRows.allSatisfy { abs($0.frame.height - 26) <= 2 })
    let pitches = zip(probe.railRows, probe.railRows.dropFirst()).map { $1.frame.minY - $0.frame.minY }
    #expect(pitches.allSatisfy { abs($0 - 28) <= 2 })
    #expect(probe.marker(SettingsModel.headerIconMarker) != nil
        && probe.marker(SettingsModel.headerTitleMarker) != nil
        && probe.marker(SettingsModel.headerSubtitleMarker) != nil)
    #expect(probe.title == "Tabs" && probe.subtitle == "Make room for your tabs.")
    // The Tabs pane's two cards share the width and sit on the boards' 10 pt gap.
    let widthCard = try #require(probe.marker(SettingsModel.rowMarker("width")))
    let archiveCard = try #require(probe.marker(SettingsModel.rowMarker("archive-after")))
    #expect(abs(widthCard.width - archiveCard.width) <= 1)
    #expect(abs((archiveCard.minY - widthCard.maxY) - SettingsMetrics.cardGap) <= 1)
    // The header fades into the toolbar title as the pane scrolls, and comes back at the top.
    probe.scrollDetail(to: 50)
    try await waitUntil { probe.layout(); return abs(probe.headerProgress - 0.5) < 0.05 }
    probe.scrollDetail(to: 0)
    try await waitUntil { probe.layout(); return probe.headerProgress < 0.05 }

    // The search's first result is selected, an arrow moves the selection, and a query with no
    // hit gives no selection to open.
    probe.setQuery("Utility 2")
    try await waitUntil { probe.layout(); return probe.resultTitles.count > 1 }
    #expect(probe.selectedIndex == 0 && probe.selectedResultTitle == probe.resultTitles.first)
    let first = try #require(probe.marker(SettingsModel.selectedResultMarker))
    #expect(first.height >= 24)
    // The selection is drawn (M1): the first result is the selection grey inside its 6 pt rect and
    // its neighbour is not, read 6 pt in from each row's left edge where no title text sits.
    let selectedID = try #require(probe.selectedResultMarker)
    let other = try #require(probe.markers(prefix: "result-").first {
        $0.id != SettingsModel.selectedResultMarker && $0.id != selectedID
    }?.frame)
    let fill = probe.greys(at: [NSPoint(x: first.minX + 6, y: first.midY), NSPoint(x: other.minX + 6, y: other.midY)])
    try #require(fill.allSatisfy { $0 != nil })
    #expect(abs((fill[0] ?? 0) - (fill[1] ?? 0)) > 10, "the selected result is drawn, not only marked")
    _ = probe.searchKey(.down)
    try await waitUntil { probe.layout(); return probe.selectedIndex == 1 }
    #expect(probe.selectedResultMarker != nil)
    probe.setQuery("nothing matches this")
    try await waitUntil { probe.layout(); return probe.noResults }
    #expect(probe.selectedResultTitle == nil && probe.marker(SettingsModel.noResultsMarker) != nil)
    probe.setQuery("")
    try await waitUntil {
        probe.layout()
        return probe.query.isEmpty && probe.marker(SettingsModel.noResultsMarker) == nil
            && probe.railRows.count == probe.railPanes.count
    }

    // Return opens the hit row, the pane scrolls to it, and the fill sits inside the card at the
    // boards' inset: 1.5 pt in from the card's edge is card grey, 6 pt in is the selection grey.
    probe.setQuery("Utility 29")
    try await waitUntil { probe.layout(); return probe.resultTitles.count == 1 }
    #expect(probe.searchKey(.return))
    try await waitUntil {
        probe.layout()
        return probe.highlightedRowID == "key-29" && (probe.detailScrollOffset ?? 0) > 100
    }
    #expect(probe.pageID == "shortcuts")
    let row = try #require(probe.marker(SettingsModel.rowMarker("key-29")))
    #expect(row.height >= SettingsMetrics.hitRowHeight)
    let greys = probe.greys(at: [NSPoint(x: row.minX + 1.5, y: row.midY), NSPoint(x: row.minX + 6, y: row.midY)])
    #expect(greys.allSatisfy { $0 != nil })
    #expect(abs((greys[0] ?? 0) - (greys[1] ?? 0)) > 10, "the hit fill is inset from the card's edge")
}

@Test @MainActor
func thePaneRegistryDrawsTheBoardsOrderAndShowsOnlyBuiltPanes() {
    // The boards' order, General to About (D1): the rail draws this list, filtered by `built`.
    #expect(SettingsRegistry.panes.map(\.id.rawValue) == ["general", "appearance", "websites", "tabs", "shortcuts",
        "air-traffic", "spaces", "little-window", "passwords", "privacy", "extensions", "sync", "about"])
    // What exists today reads Appearance, Tabs, Shortcuts, Air Traffic Control, Spaces, the
    // order §7 names.
    #expect(SettingsRegistry.built.map(\.id.rawValue) == ["appearance", "tabs", "shortcuts", "air-traffic", "spaces"])
    for pane in SettingsRegistry.panes {
        // A pane exists exactly when it has a page: no empty pane can reach the rail.
        #expect(pane.built == (pane.page != nil))
        #expect(pane.built == !pane.subtitle.isEmpty, "a built pane needs the header's line: \(pane.id)")
    }
    let model = settingsTestModel()
    #expect(model.panes.map(\.id.rawValue) == ["appearance", "tabs", "shortcuts", "air-traffic", "spaces"])
}

@Test @MainActor
func theSearchIndexFollowsTheRailOrderAndOnlyCoversBuiltPanes() {
    let model = settingsTestModel(spaces: [settingsTestSpace("a", title: "Alpha"), settingsTestSpace("b", title: "Beta")])
    model.shortcuts = [
        SettingsModel.Row(id: "shortcut-one", pane: .shortcuts, title: "One", subtitle: "First."),
        SettingsModel.Row(id: "shortcut-two", pane: .shortcuts, title: "Two", subtitle: "Second."),
    ]
    let rows = model.rows
    // Every row is a built pane's and the panes come in the rail's order.
    let order = rows.map { $0.pane.paneID.rawValue }
    let firstOfPane = order.enumerated().filter { index, pane in index == 0 || order[index - 1] != pane }
    #expect(firstOfPane.map(\.element) == ["appearance", "tabs", "shortcuts", "air-traffic", "spaces"])
    #expect(rows.allSatisfy { SettingsRegistry.pane(page: $0.pane).built })
    // The builders are the registry's own: a pane's rows are exactly what its closure returns.
    #expect(rows.filter { $0.pane == .appearance }.map(\.id) == [SettingsModel.lookRowId, SettingsModel.newTabRowId,
                                                                SettingsModel.tooltipsRowId])
    #expect(rows.filter { $0.pane == .tabs }.map(\.id) == ["width", "archive-after"])
    #expect(rows.filter { $0.pane == .shortcuts }.map(\.id) == ["shortcut-one", "shortcut-two"])
    #expect(rows.filter { $0.pane == .airTraffic }.map(\.id) == [SettingsModel.airTrafficCardId])
    // A space page's rows join the Spaces group in the results (the rail has no row of its own).
    model.query = "Name"
    #expect(model.results.map(model.resultTitle) == ["Name — Alpha", "Name — Beta"])
    #expect(model.resultGroups.map { $0.pane.id.rawValue } == ["spaces"])
    #expect(model.resultGroups.flatMap { $0.rows } == model.results)
}

@Test @MainActor
func theSearchSelectsTheFirstResultMovesWithTheArrowsAndOpensOnReturn() {
    let model = settingsTestModel(spaces: [settingsTestSpace("a", title: "Alpha")])
    model.shortcuts = (0..<3).map {
        SettingsModel.Row(id: "shortcut-\($0)", pane: .shortcuts, title: "Utility \($0)", subtitle: "Do utility \($0).")
    }
    model.navigate(.tabs)
    model.query = "Utility"
    #expect(model.searchIndex == 0)
    #expect(model.selectedResult?.id == "shortcut-0")
    // ↑ at the first result stays there (the ends clamp, they do not wrap).
    #expect(model.handleSearchKey(.up) && model.searchIndex == 0)
    #expect(model.handleSearchKey(.down) && model.searchIndex == 1)
    #expect(model.handleSearchKey(.down) && model.searchIndex == 2)
    // The ends clamp instead of wrapping, so Return never opens a different result than the filled one.
    #expect(model.handleSearchKey(.down) && model.searchIndex == 2)
    #expect(model.selectedResult?.id == "shortcut-2")
    #expect(model.handleSearchKey(.up) && model.searchIndex == 1)
    #expect(model.handleSearchKey(.return))
    #expect(model.page == .shortcuts && model.highlighted == "shortcut-1")
    // A new query starts the selection over at the first result.
    model.query = "Utility 2"
    #expect(model.searchIndex == 0 && model.selectedResult?.id == "shortcut-2")
    // No results: no key to move or open.
    model.query = "nothing matches this"
    #expect(model.results.isEmpty && model.selectedResult == nil)
    #expect(!model.handleSearchKey(.down) && !model.handleSearchKey(.up) && !model.handleSearchKey(.return))
    #expect(model.page == .shortcuts)
}

@Test @MainActor
func theHitFillSitsInsideTheCardAtTheBoardsInsetAndRadius() throws {
    _ = NSApplication.shared
    // The board's `.rw.hit`: the selection grey inset 3 pt with radius 9 inside a card of grey.
    #expect(SettingsMetrics.hitInset == 3 && SettingsMetrics.hitRadius == 9 && SettingsMetrics.hitRowHeight == 48)
    let aqua = try #require(NSAppearance(named: .aqua))
    let view = NSHostingView(rootView: ZStack {
        Rectangle().fill(SettingsColor.card)
        SettingsHitFill()
    }.frame(width: 40, height: 40))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = aqua
    window.contentView = view
    defer { window.contentView = nil }
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    func grey(_ x: Int, _ y: Int) -> Int? {
        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray).map { Int(($0.whiteComponent * 255).rounded()) }
    }
    let middle = try #require(grey(20, 20))
    let corner = try #require(grey(4, 4))
    let edge = try #require(grey(1, 20))
    #expect(abs(middle - corner) > 10, "the fill covers the middle but not the corner")
    #expect(abs(middle - edge) > 10, "the fill is inset from the card's edge")
    #expect(abs(corner - edge) <= 3, "the corner and the edge are both the card grey")
}

@Test @MainActor
func theGroupedCardHoldsItsRowsWithTheBoardsMetrics() throws {
    _ = NSApplication.shared
    #expect(SettingsMetrics.cardRadius == 12 && SettingsMetrics.separatorInset == 10 && SettingsMetrics.groupHeadingInset == 12)
    let view = NSHostingView(rootView: SettingsGroupCard(heading: "General", marker: "card-general") {
        SettingsCardRow(first: true, marker: "row-one") { Text("One") }
        SettingsCardRow(marker: "row-two") { Text("Two") }
        SettingsCardRow(height: 60, marker: "row-three") { Text("Three") }
    }.frame(width: 400))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.contentView = nil }
    view.layoutSubtreeIfNeeded()
    func frame(_ id: String) -> NSRect? {
        func find(_ node: NSView) -> NSView? {
            if node.identifier?.rawValue == id { return node }
            for child in node.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let window = view.window, let found = find(view) else { return nil }
        return found.convert(found.bounds, to: window.contentView)
    }
    let card = try #require(frame("card-general"))
    let heading = try #require(frame("card-general-heading"))
    let one = try #require(frame("row-one"))
    let two = try #require(frame("row-two"))
    let three = try #require(frame("row-three"))
    // One card holds all three rows, back to back, each at least 54 pt tall (60 wide), all on
    // the card's column: the rows fill the card's width and share edges, and the heading sits
    // above the card (the hosting view's coordinates are flipped, so the first row's top is its
    // smaller y).
    #expect(one.height >= 54 && two.height >= 54 && three.height >= 60)
    #expect(abs(one.width - two.width) <= 1 && abs(two.width - three.width) <= 1)
    #expect(abs(one.maxY - two.minY) <= 1 && abs(two.maxY - three.minY) <= 1)
    #expect(abs(card.minY - one.minY) <= 1 && abs(card.maxY - three.maxY) <= 1)
    #expect(heading.maxY < one.minY && one.minY - heading.maxY <= 8)
    // The hairline between rows is drawn (inset 10 pt, absent above the first row): at the
    // boundary the card grey sits at x = 5 and x = 15 holds a pixel that differs from the row's
    // own card grey. Values are compared with each other, not with fixed greys, because the
    // bitmap's colour profile shifts them.
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / max(1, view.bounds.width)
    func grey(_ x: CGFloat, _ y: CGFloat) -> Int? {
        let px = Int(x * scale)
        let py = Int(y * scale)
        guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceGray).map { Int(($0.whiteComponent * 255).rounded()) }
    }
    let body = try #require(grey(card.minX + 15, two.minY + 4), "the row's own card grey")
    let boundary = (0...2).compactMap { grey(card.minX + 15, two.minY + CGFloat($0) * 0.5) }
    let outside = (0...2).compactMap { grey(card.minX + 5, two.minY + CGFloat($0) * 0.5) }
    let firstRow = (0...2).compactMap { grey(card.minX + 15, one.minY + CGFloat($0) * 0.5) }
    #expect(boundary.contains { abs($0 - body) > 5 }, "a hairline is drawn between the rows: \(boundary) vs \(body)")
    #expect(outside.allSatisfy { abs($0 - body) <= 3 }, "the hairline is inset 10 pt, so x = 5 is card grey: \(outside)")
    #expect(firstRow.allSatisfy { abs($0 - body) <= 3 }, "no hairline sits above the first row: \(firstRow)")
}


// U27c: the Spaces pane's "Scroll sideways to switch spaces" card writes the workspace's one
// direction setting back through the same record the sidebars read, and reads it back on reopen.
@MainActor
private func settingsValue<T: Sendable>(_ start: (@escaping WorkspaceAdapter.Completion<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
}

@Test @MainActor
func theSpacesPaneWritesTheScrollDirectionAndReadsItBack() async throws {
    _ = NSApplication.shared
    let directory = try testTemporaryDirectory()
    let adapter = WorkspaceAdapter(windowID: "u27c-space-scroll")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AraratHarness/Fixtures/arc-sidebar-synthetic.json")
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let snapshot = try await settingsValue {
        adapter.open(path: directory.appendingPathComponent("space-scroll.sqlite").path, json: { json },
                     windowsJSON: { nil }, keyBindingsJSON: { nil }, linkRoutingJSON: { nil }, completion: $0)
    }
    let model = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    var handed: [SpaceScrollDirection] = []
    model.spaceScroll = { handed.append($0) }
    // The card is one of the Spaces pane's rows, so the search finds it like the others.
    let row = try #require(model.rows.first { $0.id == SettingsModel.spaceScrollDirectionCardId })
    #expect(row.pane == .spaces && row.title == "Scroll sideways to switch spaces")
    #expect(row.subtitle == "Natural or Reversed · Natural")
    model.query = "scroll sideways"
    #expect(model.results.contains { $0.id == SettingsModel.spaceScrollDirectionCardId })
    model.query = ""

    model.setSpaceScrollDirection(.reversed)
    try await waitUntil { model.spaceScrollDirection == .reversed }
    #expect(handed == [.reversed])
    // The write reached the core, not only the model.
    let stored = try await settingsValue { adapter.spaceScrollDirection(completion: $0) }
    #expect(stored == .reversed)
    // A second window's settings model on the same workspace reads the stored value back.
    let reopened = SettingsModel(snapshot: snapshot, adapter: adapter, publish: { _ in }, resetWidth: {},
                                 keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    reopened.readSpaceScrollDirection()
    try await waitUntil { reopened.spaceScrollDirection == .reversed }
    #expect(reopened.spaceScrollDirectionLabel == "Reversed")
    // The control is on the pane: the card and its segmented control are in the window's tree.
    reopened.navigate(.spaces)
    let controller = SettingsWindowController(model: reopened)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil {
        probe.layout()
        return probe.marker(SettingsModel.rowMarker(SettingsModel.spaceScrollDirectionCardId)) != nil
            && probe.marker(SettingsModel.spaceScrollControlMarker) != nil
    }
    #expect(probe.spaceScrollDirection == .reversed)
    _ = try await settingsValue { adapter.shutdown(completion: $0) }
    try FileManager.default.removeItem(at: directory)
}
