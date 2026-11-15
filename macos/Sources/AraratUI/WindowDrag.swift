import AppKit

/// What a double-click on a window's title bar does, from the system's setting
/// (`AppleActionOnDoubleClick`: "Maximize", "Minimize" or "None").
enum WindowDoubleClickAction: Equatable {
    case zoom
    case minimize
    case nothing

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> WindowDoubleClickAction {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .nothing
        // "Maximize" is the modern value; anything unset behaves as the system's default zoom.
        default: return .zoom
        }
    }
}

/// The window drag the owner asked for after the first hands-on session (2026-11-15): the
/// sidebar's empty areas and the frame around the page card move the window as a title bar does,
/// and a double-click there does what the system's title-bar setting says. The views that own
/// those areas call `press` from `mouseDown`, so controls, rows, dock cells and the page keep
/// their own clicks. Full screen never moves.
@MainActor
enum WindowDrag {
    /// Only a window that can move: full screen's window has no title bar to drag.
    nonisolated static func allowsDrag(styleMask: NSWindow.StyleMask) -> Bool {
        !styleMask.contains(.fullScreen)
    }

    static func press(in view: NSView, with event: NSEvent, action: WindowDoubleClickAction = .fromDefaults()) {
        guard event.type == .leftMouseDown, let window = view.window, allowsDrag(styleMask: window.styleMask) else { return }
        if event.clickCount >= 2 {
            switch action {
            case .zoom: window.zoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .nothing: break
            }
            return
        }
        window.performDrag(with: event)
    }
}
