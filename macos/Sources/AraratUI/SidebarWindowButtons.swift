import AppKit

// Native button grouping and actions adapted from Cra's FloatingSidebar.swift (MIT).
@MainActor
final class SidebarWindowButtons: NSView {
    weak var browserWindow: NSWindow?
    var sidebarHidden = false
    private var hovered = false {
        didSet { subviews.forEach { $0.needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    init(window: NSWindow) {
        browserWindow = window
        super.init(frame: NSRect(x: 12.5, y: 16.5, width: 60, height: 14))
        wantsLayer = true
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: window.styleMask.subtracting(.fullScreen)) else { continue }
            button.frame = NSRect(x: CGFloat(index) * 23, y: 0, width: 14, height: 14)
            button.target = self
            button.action = [#selector(closeWindow), #selector(minimizeWindow), #selector(zoomWindow)][index]
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @objc(_mouseInGroup:) func mouseInGroup(_ button: NSButton) -> Bool { hovered }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    @objc private func closeWindow() { browserWindow?.performClose(nil) }
    @objc private func minimizeWindow() { browserWindow?.performMiniaturize(nil) }
    @objc private func zoomWindow() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { browserWindow?.zoom(nil) }
        else { browserWindow?.toggleFullScreen(nil) }
    }
}
