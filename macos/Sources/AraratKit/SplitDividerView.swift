import AppKit

final class SplitFocusRingView: NSView {
    static let lineWidth: CGFloat = 2
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = Self.lineWidth
        path.stroke()
    }
}

final class SplitDividerView: NSView {
    var horizontal = true
    var onMove: ((CGFloat, Bool) -> Void)?
    private var lastPoint = NSPoint.zero
    private var cancelled = false
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize split panes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        if mouseInside || dragging {
            NSColor.secondaryLabelColor.setFill()
            let grip = horizontal ? NSRect(x: bounds.midX - 1, y: bounds.midY - 16, width: 2, height: 32) : NSRect(x: bounds.midX - 16, y: bounds.midY - 1, width: 32, height: 2)
            NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
        }
    }

    private var mouseInside = false
    private var dragging = false
    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { mouseInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        dragging = true; needsDisplay = true
        cancelled = false
        lastPoint = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !cancelled else { return }
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        onMove?(horizontal ? point.x - lastPoint.x : point.y - lastPoint.y, false)
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        if !cancelled { onMove?(0, true) }
        cancelled = false
        dragging = false; needsDisplay = true
    }

    func cancelDrag() { cancelled = true; dragging = false; needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        let delta: CGFloat
        switch (horizontal, event.keyCode) {
        case (true, 123), (false, 125): delta = -10
        case (true, 124), (false, 126): delta = 10
        default: super.keyDown(with: event); return
        }
        onMove?(delta, true)
    }
}
