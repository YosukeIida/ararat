import AppKit

@MainActor
public final class BrowserWindow: NSWindow {
    override public func update() {
        super.update()
        // Don't rely on layout invalidation: title changes can re-tile during update.
        layoutIfNeeded()
    }

    override public func layoutIfNeeded() {
        super.layoutIfNeeded()
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
