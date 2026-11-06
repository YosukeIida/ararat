import AppKit
import AraratKit

@MainActor
public final class BrowserWindow: NSWindow {
    weak var sidebarLights: SidebarWindowButtons?
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A table command rebound without Command yields to one of our text fields: the key is
        // claimed here (AppKit's menu pass would sink or fire it) and typed into the field.
        if let host = delegate as? MenuCommandHost, WorkspaceCommands.yieldsToOwnField(host.menuCommandBindings, event: event, in: self) {
            firstResponder?.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override public func update() {
        super.update()
        // Don't rely on layout invalidation: title changes can re-tile during update.
        layoutIfNeeded()
    }

    override public func layoutIfNeeded() {
        super.layoutIfNeeded()
        WindowChrome.layout(window: self, lights: sidebarLights)
    }

    static func buttonFrames(windowHeight: CGFloat) -> [NSRect] {
        [19.5, 42.5, 65.5].map { x in
            NSRect(x: x - 7, y: windowHeight - 23.5 - 7, width: 14, height: 14)
        }
    }
}

@MainActor
enum WindowChrome {
    static func layout(window: NSWindow, lights: SidebarWindowButtons?) {
        let fullScreen = window.styleMask.contains(.fullScreen)
        lights?.isHidden = fullScreen || lights?.sidebarHidden == true
        let host = window.standardWindowButton(.closeButton)?.window ?? window
        for (type, target) in zip([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton],
                                 BrowserWindow.buttonFrames(windowHeight: host.frame.height)) {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            // Cra's MainWindowController: alpha 0 prevents AppKit's keyboard miniaturize path.
            button.alphaValue = 1
            button.isHidden = !fullScreen && lights != nil
            if !fullScreen { button.frame = parent.convert(target, from: nil) }
        }
    }
}
