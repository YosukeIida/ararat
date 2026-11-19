import AppKit
import AraratKit
import Testing
@testable import AraratUI

// The U20 board's `--selsh: 0 1px 2px rgba(0,0,0,.08)` in light and `none` in dark, drawn on the
// selected row's fill (`.row.is-sel .fill`) and on the focused segment of a split row
// (`.split span.on`), outside the fill as CSS draws `box-shadow`. The row's drag copy is built
// selected, so it draws the same.

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

// On screen y grows down. A y-up view's layer takes the negative offset for the board's 1 pt down
// and a flipped one's the positive, so this is what a reader sees.
@MainActor
private func screenHeight(_ shadow: SelectedRowShadow, in view: NSView) -> CGFloat {
    view.isFlipped ? shadow.layer.shadowOffset.height : -shadow.layer.shadowOffset.height
}

@MainActor
private func splitSegments(_ split: SidebarRowView, active: String) throws -> [SplitSegmentButton] {
    let members = ["a", "b"].map { id in
        Row(folderHasTabs: false, parentId: "split", siblingIndex: 0, collapsed: false, id: id, title: id, url: "https://\(id).example", depth: 1, kind: .tab, unloaded: false, lastSelectedAt: nil)
    }
    split.updateSegments(members, active: active)
    split.layoutSubtreeIfNeeded()
    return try #require(split.subviews.compactMap { $0 as? NSStackView }.first).arrangedSubviews.compactMap { $0 as? SplitSegmentButton }
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
    #expect(abs(view.fillShadow.layer.shadowOpacity - 0.08) < 0.0001)
    // The shadow follows the fill's 11 pt rounded rect, not the alpha of its drawing.
    let path = try #require(view.fillShadow.layer.shadowPath)
    #expect(path.boundingBox.width == fill.bounds.width && path.boundingBox.height == fill.bounds.height)
    // The appearance change takes it away and brings it back.
    inAppearance(view, .darkAqua)
    #expect(view.fillShadow.layer.shadowOpacity == 0)
    inAppearance(view, .aqua)
    #expect(abs(view.fillShadow.layer.shadowOpacity - 0.08) < 0.0001)
}

@Test @MainActor
func theShadowFallsOnePointDownOnScreenForTheRowAndTheFocusedSegment() throws {
    let view = shadowRow("tab", selected: true)
    inAppearance(view, .aqua)
    #expect(screenHeight(view.fillShadow, in: try #require(view.subviews[0])) == SidebarMetrics.rowSelectedShadowY)

    let split = shadowRow("split", kind: .split, selected: true)
    inAppearance(split, .aqua)
    let segments = try splitSegments(split, active: "b")
    // The row's fill is a plain view (y up); a segment is an NSButton (flipped), so its layer's
    // offset takes the other sign. Both put the shadow below the fill on screen.
    #expect(segments[1].isFlipped)
    #expect(screenHeight(segments[1].fillShadow, in: segments[1]) == SidebarMetrics.rowSelectedShadowY)
    #expect(segments[1].fillShadow.layer.shadowOffset == CGSize(width: 0, height: 1))
}

@Test @MainActor
func theShadowIsDrawnOutsideTheFillOnALayerOfItsOwn() throws {
    let view = shadowRow("tab", selected: true)
    let fill = try #require(view.subviews[0].layer)
    inAppearance(view, .aqua)
    // The fill itself carries no shadow, so the 0.22 fill is not darkened from underneath.
    #expect(fill.shadowOpacity == 0)
    #expect(fill.shadowPath == nil)
    // The shadow draws on a layer of its own, not on the fill's: a fill's own shadow lands under
    // its contents and shows through the 0.22 fill. Where the two sit in the row's layer does not
    // matter, because the mask hides the shadow everywhere the fill could cover it.
    #expect(view.fillShadow.layer !== fill)
    #expect(view.fillShadow.layer.superlayer === view.layer)
    // Its mask keeps only what lies outside the fill's rounded path.
    let mask = try #require(view.fillShadow.layer.mask as? CAShapeLayer)
    #expect(mask.fillRule == .evenOdd)
    let path = try #require(mask.path)
    let bounds = mask.bounds
    #expect(!path.contains(CGPoint(x: bounds.midX, y: bounds.midY), using: .evenOdd))
    #expect(path.contains(CGPoint(x: 1, y: 1), using: .evenOdd))
    #expect(path.contains(CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1), using: .evenOdd))
}

@Test @MainActor
func theSegmentsShadowIsDrawnOutsideItsFillToo() throws {
    let split = shadowRow("split", kind: .split, selected: true)
    inAppearance(split, .aqua)
    let segments = try splitSegments(split, active: "b")
    let segment = segments[1]
    #expect(segment.fill.shadowOpacity == 0)
    #expect(segment.fill.shadowPath == nil)
    let sublayers = try #require(segment.layer?.sublayers)
    let shadowIndex = try #require(sublayers.firstIndex(of: segment.fillShadow.layer))
    let fillIndex = try #require(sublayers.firstIndex(of: segment.fill))
    #expect(shadowIndex < fillIndex)
    let mask = try #require(segment.fillShadow.layer.mask as? CAShapeLayer)
    #expect(mask.fillRule == .evenOdd)
    let path = try #require(mask.path)
    #expect(!path.contains(CGPoint(x: mask.bounds.midX, y: mask.bounds.midY), using: .evenOdd))
    #expect(path.contains(CGPoint(x: 1, y: 1), using: .evenOdd))
}

@Test @MainActor
func aDragSourceKeepsTheFillWithoutTheShadow() throws {
    // The board's shadow is on the selected row alone: a drag source draws the selected fill's
    // alpha and carries no shadow (as hover and pressed do, `updateFill`).
    let view = shadowRow("tab", selected: false)
    let fill = try #require(view.subviews[0].layer)
    inAppearance(view, .aqua)
    #expect(view.fillShadow.layer.shadowOpacity == 0)
    view.dragSource = true
    #expect(abs(try #require(fill.backgroundColor?.alpha) - SidebarMetrics.rowSelectedFillAlpha) < 0.0001)
    #expect(view.fillShadow.layer.shadowOpacity == 0)
}

@Test @MainActor
func theDragCopyDrawsTheSameShadow() throws {
    let copy = shadowRow("tab", selected: true)
    copy.dragCopy = true
    inAppearance(copy, .aqua)
    #expect(abs(copy.fillShadow.layer.shadowOpacity - 0.08) < 0.0001)
}

@Test @MainActor
func focusedSegmentCarriesTheShadowAndTheOthersDoNot() throws {
    let split = shadowRow("split", kind: .split, selected: true)
    inAppearance(split, .aqua)
    var segments = try splitSegments(split, active: "b")
    // A split row draws its segments and nothing of its own, so its row-level shadow is hidden.
    #expect(split.fillShadow.layer.isHidden)
    #expect(segments[0].fillShadow.layer.shadowOpacity == 0)
    #expect(abs(segments[1].fillShadow.layer.shadowOpacity - 0.08) < 0.0001)
    #expect(segments[1].fillShadow.layer.shadowRadius == SidebarMetrics.rowSelectedShadowBlur / 2)
    #expect(segments[1].fillShadow.layer.shadowPath?.boundingBox.size == segments[1].fill.path?.boundingBox.size)
    inAppearance(split, .darkAqua)
    #expect(segments[1].fillShadow.layer.shadowOpacity == 0)
    // The focus moving takes the shadow with it.
    inAppearance(split, .aqua)
    segments = try splitSegments(split, active: "a")
    #expect(abs(segments[0].fillShadow.layer.shadowOpacity - 0.08) < 0.0001)
    #expect(segments[1].fillShadow.layer.shadowOpacity == 0)
}
