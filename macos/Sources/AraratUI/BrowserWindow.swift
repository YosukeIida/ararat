import AppKit
import AraratKit

@MainActor
public final class BrowserWindow: NSWindow {
    weak var sidebarLights: SidebarWindowButtons?
    private var hidNativeButtons = false
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
        let fullScreen = styleMask.contains(.fullScreen)
        sidebarLights?.isHidden = fullScreen || sidebarLights?.sidebarHidden == true
        if fullScreen && hidNativeButtons {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(type)?.isHidden = false
            }
            hidNativeButtons = false
        }
        guard !fullScreen else { return }
        hidNativeButtons = sidebarLights != nil
        let host = standardWindowButton(.closeButton)?.window ?? self
        for (type, target) in zip([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton],
                                 Self.buttonFrames(windowHeight: host.frame.height)) {
            guard let button = standardWindowButton(type), let parent = button.superview else { continue }
            // Cra's MainWindowController: alpha 0 prevents AppKit's keyboard miniaturize path.
            button.alphaValue = 1
            button.isHidden = sidebarLights != nil
            button.frame = parent.convert(target, from: nil)
        }
    }

    static func buttonFrames(windowHeight: CGFloat) -> [NSRect] {
        [19.5, 42.5, 65.5].map { x in
            NSRect(x: x - 7, y: windowHeight - 23.5 - 7, width: 14, height: 14)
        }
    }
}
