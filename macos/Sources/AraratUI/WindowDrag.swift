import AppKit

/// What a double-click on a window's title bar does, from the system's setting
/// (`AppleActionOnDoubleClick`: "Maximize", "Minimize" or "None").
enum WindowDoubleClickAction: Equatable {
    case zoom
    case minimize
    case nothing

    /// The stored value; nil (or an unknown value, such as macOS 15's "Fill") is the system's
    /// default zoom. Split out so a test can pin every value without the host's setting.
    static func fromSetting(_ value: String?) -> WindowDoubleClickAction {
        switch value {
        case "Minimize": return .minimize
        case "None": return .nothing
        default: return .zoom
        }
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> WindowDoubleClickAction {
        fromSetting(defaults.string(forKey: "AppleActionOnDoubleClick"))
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

    /// The view AppKit resolves a window point to, the way `NSWindow` hit-tests its content:
    /// the content view's `hitTest` takes a point in its superview's coordinates.
    static func pressTarget(in window: NSWindow, at pointInWindow: NSPoint) -> NSView? {
        guard let content = window.contentView else { return nil }
        guard let superview = content.superview else { return content.hitTest(pointInWindow) }
        return content.hitTest(superview.convert(pointInWindow, from: nil))
    }

    /// Only a press that landed on the drag area's owner starts the drag. NSView forwards an
    /// unconsumed press to its superview, so without the check a press on an overlay inside the
    /// page (an error page, the "Shown in another window" placeholder) would reach the container
    /// and move or zoom the window (review M1).
    ///
    /// The title-bar action runs only for a second press that did not become a drag, which is
    /// what the real title bar does: it zooms, minimizes or does nothing on the release of a
    /// stationary second click, and a drag there moves the window instead. A single press
    /// (`clickCount` 1) therefore never runs it, however the system's setting reads.
    static func press(in view: NSView, with event: NSEvent, action: WindowDoubleClickAction = .fromDefaults()) {
        guard event.type == .leftMouseDown, let window = view.window, allowsDrag(styleMask: window.styleMask),
              pressTarget(in: window, at: event.locationInWindow) === view else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        window.performDrag(with: event)
        let end = NSEvent.mouseLocation
        guard runsDoubleClickAction(clickCount: event.clickCount,
                                    travelled: hypot(end.x - start.x, end.y - start.y)) else { return }
        switch action {
        case .zoom: window.zoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .nothing: break
        }
    }

    /// Our drag threshold, the same 3 pt a row drag uses: the title bar's double click tolerates a
    /// point or two of hand movement, and this is the same order.
    nonisolated static let dragThreshold: CGFloat = 3

    /// The rule above, as a pure function: a second press (`clickCount` 2 or more) runs the
    /// action only when the pointer did not travel past `dragThreshold`.
    nonisolated static func runsDoubleClickAction(clickCount: Int, travelled: CGFloat) -> Bool {
        clickCount >= 2 && travelled <= dragThreshold
    }
}
