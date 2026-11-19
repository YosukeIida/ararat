import AppKit
import AraratKit
import Testing
@testable import AraratUI

// The U20 board's `--selsh: 0 1px 2px rgba(0,0,0,.08)` in light and `none` in dark, drawn on the
// selected row's fill (`.row.is-sel .fill`) and on the focused segment of a split row
// (`.split span.on`). The row's drag copy is built selected, so it draws the same.

@MainActor
private func shadowRow(_ id: String, kind: RowKind = .tab, selected: Bool) -> SidebarRowView {
    let row = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: id, title: id, url: nil, depth: 0, kind: kind, unloaded: false, lastSelectedAt: nil)
    let view = SidebarRowView(row: row, selected: selected, action: { _ in })
    view.frame = NSRect(x: 0, y: 0, width: 224, height: 41)
    view.layoutSubtreeIfNeeded()
    return view
}

@MainActor
private func inAppearance(_ view: NSView, _ name: NSAppearance.Name) {
    view.appearance = NSAppearance(named: name)
    view.viewDidChangeEffectiveAppearance()
}

@Test @MainActor
func selectedRowShadowTokensAreTheBoards() {
    #expect(SidebarMetrics.rowSelectedShadowY == 1)
    #expect(SidebarMetrics.rowSelectedShadowBlur == 2)
    #expect(SidebarMetrics.rowSelectedShadowAlpha == 0.08)
    // The board draws no shadow in dark.
    #expect(SidebarMetrics.rowSelectedShadowAlphaDark == 0)
}

@Test @MainActor
func selectedRowFillCarriesTheShadowInLightAndNoneInDark() throws {
    let view = shadowRow("tab", selected: true)
    let fill = try #require(view.subviews[0].layer)
    inAppearance(view, .aqua)
    #expect(abs(fill.shadowOpacity - 0.08) < 0.0001)
    // The board draws 1 pt down; the row's layer is y-up, so the layer's offset is negative.
    #expect(fill.shadowOffset == CGSize(width: 0, height: -1))
    #expect(fill.shadowRadius == SidebarMetrics.rowSelectedShadowBlur / 2)
    // The shadow follows the fill's 11 pt rounded rect, not the alpha of its drawing.
    let path = try #require(fill.shadowPath)
    #expect(path.boundingBox.width == fill.bounds.width && path.boundingBox.height == fill.bounds.height)
    // The appearance change takes it away and brings it back.
    inAppearance(view, .darkAqua)
    #expect(fill.shadowOpacity == 0)
    inAppearance(view, .aqua)
    #expect(abs(fill.shadowOpacity - 0.08) < 0.0001)
}

@Test @MainActor
func aDragSourceKeepsTheFillWithoutTheShadow() throws {
    // The board's shadow is on the selected row alone: a drag source draws the selected fill's
    // alpha and carries no shadow (as hover and pressed do, `updateFill`).
    let view = shadowRow("tab", selected: false)
    let fill = try #require(view.subviews[0].layer)
    inAppearance(view, .aqua)
    #expect(fill.shadowOpacity == 0)
    view.dragSource = true
    #expect(abs(try #require(fill.backgroundColor?.alpha) - SidebarMetrics.rowSelectedFillAlpha) < 0.0001)
    #expect(fill.shadowOpacity == 0)
}

@Test @MainActor
func theDragCopyDrawsTheSameShadow() throws {
    let copy = shadowRow("tab", selected: true)
    copy.dragCopy = true
    let fill = try #require(copy.subviews[0].layer)
    inAppearance(copy, .aqua)
    #expect(abs(fill.shadowOpacity - 0.08) < 0.0001)
}

@Test @MainActor
func focusedSegmentCarriesTheShadowAndTheOthersDoNot() throws {
    let split = shadowRow("split", kind: .split, selected: true)
    let members = ["a", "b"].map { id in
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 0, collapsed: false, id: id, title: id, url: "https://\(id).example", depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    split.updateSegments(members, active: "b")
    split.layoutSubtreeIfNeeded()
    let segments = try #require(split.subviews.compactMap { $0 as? NSStackView }.first).arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
    #expect(segments.count == 2)
    inAppearance(split, .aqua)
    #expect(segments[0].fill.shadowOpacity == 0)
    #expect(abs(segments[1].fill.shadowOpacity - 0.08) < 0.0001)
    #expect(segments[1].fill.shadowOffset == CGSize(width: 0, height: -1))
    #expect(segments[1].fill.shadowRadius == SidebarMetrics.rowSelectedShadowBlur / 2)
    #expect(segments[1].fill.shadowPath?.boundingBox == segments[1].fill.path?.boundingBox)
    inAppearance(split, .darkAqua)
    #expect(segments[1].fill.shadowOpacity == 0)
    // The focus moving takes the shadow with it.
    inAppearance(split, .aqua)
    split.updateSegments(members, active: "a")
    split.layoutSubtreeIfNeeded()
    let again = try #require(split.subviews.compactMap { $0 as? NSStackView }.first).arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
    #expect(abs(again[0].fill.shadowOpacity - 0.08) < 0.0001)
    #expect(again[1].fill.shadowOpacity == 0)
}
