import AppKit

// Width rule: Cra (MIT), SpaceDockView.cellWidths; analysis/peers/2026-11-02-recent-updates.md §2.3.
@MainActor
public final class SpaceDockView: NSView {
    public enum CellState: Equatable { case letter(String), dot }
    var selectedIndex = 0 { didSet { needsLayout = true } }
    var selectionPosition: CGFloat = 0 { didSet { updateStates() } }
    public var cellStates: [(state: CellState, openFraction: CGFloat, refused: Bool)] {
        subviews.compactMap { ($0 as? SpaceDockButton).map { ($0.glyph, $0.openFraction, $0.refused) } }
    }

    static func cellWidths(count: Int, selected: Int, width: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let share = min(34, floor(max(0, width) / CGFloat(count) * 2) / 2)
        guard share < 22, count > 1, (0..<count).contains(selected) else {
            return Array(repeating: share, count: count)
        }
        let other = floor(max(0, width - 22) / CGFloat(count - 1) * 2) / 2
        return (0..<count).map { $0 == selected ? 22 : other }
    }

    func updateStates() {
        let dense = subviews.count > 1 && floor(max(0, bounds.width) / CGFloat(subviews.count) * 2) / 2 < 22
        for (index, view) in subviews.enumerated() {
            guard let cell = view as? SpaceDockButton else { continue }
            cell.glyph = dense && index != selectedIndex ? .dot : .letter(cell.title)
            cell.openFraction = max(0, 1 - abs(selectionPosition - CGFloat(index)))
        }
    }

    override public func layout() {
        super.layout()
        let widths = Self.cellWidths(count: subviews.count, selected: selectedIndex, width: bounds.width)
        var x = (bounds.width - widths.reduce(0, +)) / 2
        for (cell, width) in zip(subviews, widths) {
            cell.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
        updateStates()
    }
}

@MainActor
final class SpaceDockButton: NSButton {
    var spaceID = ""
    var glyph: SpaceDockView.CellState = .letter("") { didSet { if glyph != oldValue { needsDisplay = true } } }
    var openFraction: CGFloat = 0 { didSet { if openFraction != oldValue { needsDisplay = true } } }
    static func fillAlpha(fraction: CGFloat, appearance: NSAppearance) -> CGFloat {
        fraction * (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.13 : 0.6)
    }
    /// The open cell's fill: the mock's white overlay on the tinted sidebar (55 % in light, 10 % in
    /// dark; `mock-decisions.md` 2026-11-11, the F and A-BottomDock boards), scaled by the slide's
    /// open fraction so the fill cross-fades between cells. The Library keeps the accent fill.
    static func openFillAlpha(fraction: CGFloat, appearance: NSAppearance) -> CGFloat {
        fraction * (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.10 : 0.55)
    }
    var refused = false { didSet { alphaValue = refused ? 0.35 : 1 } }
    var menuProvider: (() -> NSMenu?)?
    private var trackingPress = false
    private var hovered = false
    private var pressInside = false
    var backgroundAlpha: CGFloat { openFraction > 0 ? Self.openFillAlpha(fraction: openFraction, appearance: effectiveAppearance) : pressInside ? 0.078 : hovered ? 0.045 : 0 }
    /// The fill `draw` puts under the glyph, nil when the cell draws none: white for the open cell,
    /// the label colour for hover and press. The checks read this to pin the drawn colours.
    var checkFill: NSColor? {
        if openFraction > 0 { return NSColor.white.withAlphaComponent(backgroundAlpha) }
        if backgroundAlpha > 0 { return NSColor.labelColor.withAlphaComponent(backgroundAlpha) }
        return nil
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: (bounds.height - 24) / 2, width: bounds.width, height: 24)
        if let fill = checkFill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        if glyph == .dot {
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
        } else { super.draw(dirtyRect) }
    }
    override func mouseDown(with event: NSEvent) { trackingPress = true; pressInside = true; highlight(true); needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        pressInside = bounds.contains(convert(event.locationInWindow, from: nil))
        highlight(pressInside)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let activate = trackingPress && bounds.contains(convert(event.locationInWindow, from: nil))
        trackingPress = false
        pressInside = false
        highlight(false)
        needsDisplay = true
        if activate { _ = sendAction(action, to: target) }
    }
}
