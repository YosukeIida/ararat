import AppKit

@MainActor
public final class BrowserWindow: NSWindow {
    private let buttonHits = WindowButtonHitView()

    override public func update() {
        super.update()
        // Don't rely on layout invalidation: title changes can re-tile during update.
        layoutIfNeeded()
    }

    override public func layoutIfNeeded() {
        super.layoutIfNeeded()
        guard let theme = contentView?.superview else { return }
        if buttonHits.superview !== theme {
            theme.addSubview(buttonHits, positioned: .above, relativeTo: nil)
        }
        buttonHits.frame = theme.bounds
        let host = standardWindowButton(.closeButton)?.window ?? self
        for (type, target) in zip([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton],
                                 Self.buttonFrames(windowHeight: host.frame.height)) {
            guard let button = standardWindowButton(type), let parent = button.superview else { continue }
            button.frame = parent.convert(target, from: nil)
        }
    }

    static func buttonFrames(windowHeight: CGFloat) -> [NSRect] {
        [19.5, 42.5, 65.5].map { x in
            NSRect(x: x - 7, y: windowHeight - 23.5 - 7, width: 14, height: 14)
        }
    }
}

private final class WindowButtonHitView: NSView {
    // Don't enlarge the titlebar to make the buttons' lower 2.5 pt hittable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        let point = convert(point, from: superview)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), button.window === window,
                  !button.isHiddenOrHasHiddenAncestor else { continue }
            if convert(button.bounds, from: button).contains(point) { return button }
        }
        return nil
    }
}
