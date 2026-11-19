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

// On screen y grows down. This maps the shadow's offset through the layer tree into an unflipped
// root, where y grows up, so a shadow below its fill reads as a negative dy. It never looks at the
// sign the code chose.
@MainActor
private func offsetInUnflippedRoot(_ shadow: SelectedRowShadow, in root: NSView) throws -> CGPoint {
    let layer = shadow.layer
    let rootLayer = try #require(root.layer)
    let origin = layer.convert(CGPoint(x: 0, y: 0), to: rootLayer)
    let tip = layer.convert(CGPoint(x: 0, y: layer.shadowOffset.height), to: rootLayer)
    return CGPoint(x: tip.x - origin.x, y: tip.y - origin.y)
}

// A plain NSView is unflipped, so its layer is the y-up root the mapping above reads.
@MainActor
private func inUnflippedRoot(_ view: NSView) -> NSView {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 60))
    root.wantsLayer = true
    root.addSubview(view)
    view.frame = NSRect(x: 8, y: 8, width: 224, height: 41)
    root.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    return root
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
    let light = try #require(fill.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
    #expect(light == NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    #expect(abs(view.fillShadow.layer.shadowOpacity - 0.08) < 0.0001)
    // The shadow follows the fill's 11 pt rounded rect, not the alpha of its drawing.
    let path = try #require(view.fillShadow.layer.shadowPath)
    #expect(path.boundingBox.width == fill.bounds.width && path.boundingBox.height == fill.bounds.height)
    // The appearance change takes it away and brings it back.
    inAppearance(view, .darkAqua)
    let dark = try #require(fill.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
    #expect(dark == NSColor(srgbRed: 67.0 / 255, green: 63.0 / 255, blue: 75.0 / 255, alpha: 1))
    #expect(view.fillShadow.layer.shadowOpacity == 0)
    inAppearance(view, .aqua)
    #expect(abs(view.fillShadow.layer.shadowOpacity - 0.08) < 0.0001)
}

@Test @MainActor
func theShadowFallsOnePointDownOnScreenForTheRowAndTheFocusedSegment() throws {
    let view = shadowRow("tab", selected: true)
    inAppearance(view, .aqua)
    let root = inUnflippedRoot(view)
    #expect(!root.isFlipped)
    let row = try offsetInUnflippedRoot(view.fillShadow, in: root)
    #expect(row.x == 0)
    #expect(abs(row.y + SidebarMetrics.rowSelectedShadowY) < 0.0001)

    let split = shadowRow("split", kind: .split, selected: true)
    inAppearance(split, .aqua)
    let splitRoot = inUnflippedRoot(split)
    let segments = try splitSegments(split, active: "b")
    // A segment is an NSButton, whose layer is flipped, so the raw offset carries the other sign;
    // both still put the shadow below the fill on screen.
    let segment = try offsetInUnflippedRoot(segments[1].fillShadow, in: splitRoot)
    #expect(segment.x == 0)
    #expect(abs(segment.y + SidebarMetrics.rowSelectedShadowY) < 0.0001)
}

@Test @MainActor
func theShadowLayerDrawsNothingButItsShadow() throws {
    // The layer is clear and has no path, so nothing opaque can meet the mask's antialiased edge;
    // its only drawing is the shadow the window server casts from `shadowPath`.
    let view = shadowRow("tab", selected: true)
    inAppearance(view, .aqua)
    let rowFill = try #require(view.fillShadow.layer.fillColor)
    #expect(rowFill.alpha == 0)
    #expect(view.fillShadow.layer.path == nil)
    #expect(view.fillShadow.layer.shadowPath != nil)

    let split = shadowRow("split", kind: .split, selected: true)
    inAppearance(split, .aqua)
    let segment = try splitSegments(split, active: "b")[1]
    let segmentFill = try #require(segment.fillShadow.layer.fillColor)
    #expect(segmentFill.alpha == 0)
    #expect(segment.fillShadow.layer.shadowPath != nil)
}

@Test @MainActor
func theShadowLayerIsHiddenWheneverTheShadowIsOff() throws {
    // An off shadow hides its layer: left visible, a clear shape would still draw at the mask's
    // edge, and before this change an opaque one did.
    let unselected = shadowRow("tab", selected: false)
    inAppearance(unselected, .aqua)
    #expect(unselected.fillShadow.layer.isHidden)

    let selected = shadowRow("tab", selected: true)
    inAppearance(selected, .aqua)
    #expect(!selected.fillShadow.layer.isHidden)
    // The board draws no shadow in dark.
    inAppearance(selected, .darkAqua)
    #expect(selected.fillShadow.layer.isHidden)
    inAppearance(selected, .aqua)
    #expect(!selected.fillShadow.layer.isHidden)

    // Hover, press and drag do not add a shadow to an unselected row.
    let hovered = shadowRow("tab", selected: false)
    inAppearance(hovered, .aqua)
    hovered.pointerLocation = { NSPoint(x: 10, y: 10) }
    hovered.refreshHover()
    #expect(hovered.hovered)
    #expect(hovered.fillShadow.layer.isHidden)

    let pressed = shadowRow("tab", selected: false)
    inAppearance(pressed, .aqua)
    pressed.pointerLocation = { NSPoint(x: 10, y: 10) }
    pressed.refreshHover()
    pressed.mouseDown(with: try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
    #expect(pressed.pressed)
    #expect(pressed.fillShadow.layer.isHidden)

    let dragging = shadowRow("tab", selected: false)
    inAppearance(dragging, .aqua)
    dragging.dragSource = true
    #expect(dragging.fillShadow.layer.isHidden)

    // A split row draws its segments and nothing of its own: no row-level fill, no row-level
    // shadow. Its focused segment keeps both.
    let split = shadowRow("split", kind: .split, selected: true)
    inAppearance(split, .aqua)
    let segments = try splitSegments(split, active: "b")
    #expect(split.fillShadow.layer.isHidden)
    #expect(!segments[1].fillShadow.layer.isHidden)
    #expect(segments[0].fillShadow.layer.isHidden)
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
    let view = shadowRow("tab", selected: false)
    let fill = try #require(view.subviews[0].layer)
    inAppearance(view, .aqua)
    #expect(view.fillShadow.layer.shadowOpacity == 0)
    view.dragSource = true
    #expect(fill.backgroundColor == SidebarMetrics.rowSelectedFillLight.cgColor)
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
