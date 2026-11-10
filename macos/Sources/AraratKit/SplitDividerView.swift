import AppKit

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
        NSColor.separatorColor.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
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
    }

    func cancelDrag() { cancelled = true }

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
