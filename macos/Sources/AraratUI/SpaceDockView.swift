import AppKit

// Width rule: Cra (MIT), SpaceDockView.cellWidths; analysis/peers/2026-11-02-recent-updates.md §2.3.
@MainActor
final class SpaceDockView: NSView {
    var selectedIndex = 0 { didSet { needsLayout = true } }

    static func cellWidths(count: Int, selected: Int, width: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let share = min(34, floor(max(0, width) / CGFloat(count) * 2) / 2)
        guard share < 22, count > 1, (0..<count).contains(selected) else {
            return Array(repeating: share, count: count)
        }
        let other = floor(max(0, width - 22) / CGFloat(count - 1) * 2) / 2
        return (0..<count).map { $0 == selected ? 22 : other }
    }

    override func layout() {
        super.layout()
        let widths = Self.cellWidths(count: subviews.count, selected: selectedIndex, width: bounds.width)
        var x = (bounds.width - widths.reduce(0, +)) / 2
        for (cell, width) in zip(subviews, widths) {
            cell.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }
}

@MainActor
final class SpaceDockButton: NSButton {
    private var trackingPress = false
    override var mouseDownCanMoveWindow: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func mouseDown(with event: NSEvent) {
        trackingPress = true
        highlight(true)
    }
    override func mouseDragged(with event: NSEvent) {
        highlight(bounds.contains(convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
        let activate = trackingPress && bounds.contains(convert(event.locationInWindow, from: nil))
        trackingPress = false
        highlight(false)
        if activate { _ = sendAction(action, to: target) }
    }
}
