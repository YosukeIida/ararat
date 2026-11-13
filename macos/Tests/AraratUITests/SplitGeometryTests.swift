import Foundation
import Testing
@testable import AraratKit

private func pane(_ id: String, _ factor: Double = 1, _ kind: SplitPaneKind = .tab, _ children: [SplitPane] = []) -> SplitPane {
    SplitPane(id: id, factor: factor, kind: kind, unloaded: false, url: nil, children: children)
}

@Test
func focusWalksNestedPanesAndWraps() {
    let split = pane("root", 1, .splitHorizontal, [pane("a"), pane("nested", 1, .splitVertical, [pane("b"), pane("c")])])
    for (from, to) in [("a", "b"), ("b", "c"), ("c", "a")] {
        #expect(EngineAdapter.nextPane(split, active: from, backwards: false)?.id == to)
    }
    #expect(EngineAdapter.nextPane(split, active: "a", backwards: true)?.id == "c")
    #expect(EngineAdapter.nextPane(split, active: "missing", backwards: false)?.id == nil)
    #expect(EngineAdapter.nextPane(pane("a"), active: "a", backwards: false)?.id == nil)
}

@Test
func nestedSplitKeepsEveryPaneAndRespectsAxisMinimums() {
    let nested = pane("nested", 1, .splitHorizontal, [pane("a"), pane("b")])
    let root = pane("root", 1, .splitHorizontal, [nested, pane("c", 3)])
    let geometry = SplitGeometry(root: root, bounds: CGRect(x: 0, y: 0, width: 1000, height: 400))
    #expect(geometry.panes.count == 3 && geometry.dividers.count == 2)
    #expect(geometry.dividers.allSatisfy { $0.frame.width == 10 })
    #expect(geometry.panes["a"]!.width >= 240 && geometry.panes["b"]!.width >= 240)
    #expect(geometry.panes["c"]!.width >= 240)
    #expect(abs(geometry.panes["c"]!.maxX - 1000) < 0.001)
}

@Test
func smallNestedSplitShrinksPanesWithoutHidingThem() {
    let nested = pane("nested", 1, .splitVertical, [pane("a"), pane("b")])
    let root = pane("root", 1, .splitHorizontal, [nested, pane("c")])
    let geometry = SplitGeometry(root: root, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
    #expect(geometry.panes.count == 3 && geometry.dividers.count == 2)
    for frame in geometry.panes.values { #expect(frame.width > 0 && frame.height > 0) }
    #expect(abs(geometry.panes["c"]!.maxX - 300) < 0.001)
}

@Test
func draggingKeepsOtherPanesAndClampsAdjacentMinimums() throws {
    let root = pane("root", 1, .splitHorizontal, [pane("a"), pane("b"), pane("c")])
    let geometry = SplitGeometry(root: root, bounds: CGRect(x: 0, y: 0, width: 1220, height: 400))
    let factors = try #require(geometry.factorsAfterDragging(root: root, split: "root", index: 0, delta: 1000))
    #expect(abs(factors[0].factor - 560.0 / 1200) < 0.0001)
    #expect(abs(factors[1].factor - 240.0 / 1200) < 0.0001)
    #expect(abs(factors[2].factor - 400.0 / 1200) < 0.0001)
}

@Test
func aVerticalSplitsFirstPaneIsDrawnAtTheTopAndHorizontalOrderIsUnchanged() throws {
    // The card is unflipped: y grows upward, so "on top" is a greater y. The row order and the
    // screen order agree — Move Up moves a pane up and the top drop half inserts before the target.
    let vertical = pane("root", 1, .splitVertical, [pane("first"), pane("second")])
    let geometry = SplitGeometry(root: vertical, bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
    let first = try #require(geometry.panes["first"])
    let second = try #require(geometry.panes["second"])
    #expect(first.minY > second.maxY)
    #expect(abs(first.width - 400) < 0.001 && abs(first.minX - second.minX) < 0.001)
    #expect(abs(first.maxY - 600) < 0.001)
    #expect(geometry.dividers.count == 1 && geometry.dividers[0].frame.midY < first.minY)
    // Side by side keeps the first pane on the left.
    let horizontal = pane("root", 1, .splitHorizontal, [pane("first"), pane("second")])
    let flat = SplitGeometry(root: horizontal, bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
    #expect(try #require(flat.panes["first"]).maxX <= (try #require(flat.panes["second"]).minX))
}

@Test
func aLoneMemberIsNotRetakenAsTheWholeSplitAndADrawingWindowKeepsItsSplit() {
    // Review 2 MF1: window B holds M alone; B becoming key again must not pull the split out of A.
    #expect(EngineAdapter.remoteTake(owner: "B", window: "B", remoteSibling: true, loneMember: "M", item: "M") == (false, true))
    // M's tab moved back to A: B takes M alone, never the split.
    #expect(EngineAdapter.remoteTake(owner: "A", window: "B", remoteSibling: true, loneMember: "M", item: "M") == (true, false))
    // A window that draws the split reclaims the page another window borrowed (§4.6).
    #expect(EngineAdapter.remoteTake(owner: "A", window: "A", remoteSibling: true, loneMember: nil, item: "M") == (true, true))
    // Nothing remote and nothing lone: nothing to take.
    #expect(EngineAdapter.remoteTake(owner: "B", window: "B", remoteSibling: false, loneMember: nil, item: "M") == (false, true))
    // Review 2 SF1: a pane of the split this window draws keeps it whole; another window's split
    // comes alone; the split row's own selection is whole.
    #expect(!EngineAdapter.takesLoneMember(wholeSplit: false, drawingSplit: "S", split: "S", remoteSibling: true))
    #expect(EngineAdapter.takesLoneMember(wholeSplit: false, drawingSplit: "X", split: "S", remoteSibling: true))
    #expect(!EngineAdapter.takesLoneMember(wholeSplit: true, drawingSplit: nil, split: "S", remoteSibling: true))
    #expect(!EngineAdapter.takesLoneMember(wholeSplit: false, drawingSplit: nil, split: "S", remoteSibling: false))
    #expect(!EngineAdapter.takesLoneMember(wholeSplit: false, drawingSplit: nil, split: nil, remoteSibling: true))
}

@Test
func theDrawingWindowTakesTheWholeSplitBackWhenOneMemberIsHeldElsewhere() {
    // §4.6: the window that drew the split becomes key with a member selected; the sibling window
    // holds one member alone. The drawing window reclaims every page (whole split), and it never
    // drops to a lone pane of its own split.
    #expect(EngineAdapter.remoteTake(owner: "B", window: "A", remoteSibling: true, loneMember: nil, item: "left") == (true, true))
    #expect(!EngineAdapter.takesLoneMember(wholeSplit: true, drawingSplit: "S", split: "S", remoteSibling: true))
    // The sibling window, holding the member alone, still takes only that member back if it moved.
    #expect(EngineAdapter.remoteTake(owner: "A", window: "B", remoteSibling: true, loneMember: "M", item: "M") == (true, false))
}
