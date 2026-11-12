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
