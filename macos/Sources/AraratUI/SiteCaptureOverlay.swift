import AppKit

/// The page-card overlay that selects a rectangle for a region screenshot (U26e pass 4). It
/// covers only the focused pane's card, returns view points with the origin at the top left,
/// and cancels on Escape. Clicks never reach the page while it is up.
@MainActor
public final class SiteCaptureOverlay: NSView {
    /// Called with the selected rectangle in the overlay's (flipped, top-left origin) points,
    /// or nil when the user cancelled.
    public var onFinish: ((NSRect?) -> Void)?
    public private(set) var selected: NSRect = .zero
    public private(set) var isDragging = false
    private var origin: NSPoint?
    private var tracking = false
    private var escapeMonitor: Any?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Why not depend on the first responder: Chromium's page view re-grabs focus on layout
        // and refuses to resign it, so makeFirstResponder(self) is best effort only. A local
        // monitor cancels on Escape while the overlay is up, wherever the key goes.
        if window != nil {
            window?.makeFirstResponder(self)
            installEscapeMonitor()
        } else {
            removeEscapeMonitor()
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, let overlayWindow = self.window,
                  event.window == overlayWindow || overlayWindow.isKeyWindow else { return event }
            self.cancel()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        origin = point
        selected = NSRect(origin: point, size: .zero)
        isDragging = true
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging, let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selected = NSRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                          width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let point = convert(event.locationInWindow, from: nil)
        if let origin {
            selected = NSRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                              width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        }
        self.origin = nil
        finish(selected.width >= 2 && selected.height >= 2 ? selected : nil)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancel()
            return
        }
        super.keyDown(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    public func cancel() {
        guard !tracking else { return }
        finish(nil)
    }

    private func finish(_ rect: NSRect?) {
        guard !tracking else { return }
        tracking = true
        removeEscapeMonitor()
        // Posting keeps the overlay alive through the mouse-up that finished the drag, so the
        // capture request never tears down the view it came from.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFinish?(rect)
        }
    }

    /// A deterministic drag for the checks: the same path the mouse handlers take, without a
    /// real cursor (the VM has none).
    public func performCheckDrag(from start: NSPoint, to end: NSPoint) {
        origin = start
        selected = NSRect(origin: start, size: .zero)
        isDragging = true
        selected = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        needsDisplay = true
        isDragging = false
        origin = nil
        finish(selected.width >= 2 && selected.height >= 2 ? selected : nil)
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
        guard !selected.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        selected.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: selected.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}
