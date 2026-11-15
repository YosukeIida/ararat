import AppKit

/// What a double-click on a window's title bar does, from the system's setting
/// (`AppleActionOnDoubleClick`: "Maximize", "Minimize" or "None"). macOS 15's "Fill" is an unknown
/// value here and reads as zoom: filling the screen needs AppKit's private `_zoomFill:`, and no
/// private API is used; Arc fills, so this is a known difference (design, 2026-11-16).
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
/// those areas pass their `mouseDown` to `Held`, which stores the press; the first `mouseDragged`
/// past `dragThreshold` hands that stored press to the window server, and a `mouseUp` that stayed
/// within the threshold on a second click runs the title-bar action. Controls, rows, dock cells
/// and the page keep their own clicks. Full screen never moves (design, 2026-11-16, from Yab's
/// stored-press model; reimplemented, no code copied).
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

    /// The press point in screen coordinates. The window is not moved by us any more, so the
    /// event's own window point is accurate for the whole press.
    static func screenPoint(of event: NSEvent, in view: NSView) -> NSPoint {
        guard let window = view.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    static func perform(_ action: WindowDoubleClickAction, in window: NSWindow) {
        switch action {
        case .zoom: window.zoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .nothing: break
        }
    }

    /// Our drag threshold, the same 3 pt a row drag uses: the title bar's double click tolerates a
    /// point or two of hand movement, and this is the same order.
    nonisolated static let dragThreshold: CGFloat = 3

    /// The rule for a stored press, with no window and no event in it, so a test can feed it
    /// points: within the threshold the press is still a click (a second click's release runs the
    /// title-bar action); past it the press is a drag, owed to the window server once, and its
    /// release runs nothing.
    struct Press: Equatable {
        enum Step: Equatable {
            /// Nothing is owed for this point.
            case none
            /// The press has just passed the threshold: hand it to the window server.
            case drag
            /// A stationary second release: run the title-bar action once.
            case act
        }

        let origin: NSPoint
        let clickCount: Int
        /// The press was handed to the window server: the release after it is the system's.
        private(set) var handedOver = false
        /// The title-bar action ran, so nothing may run it again for this press.
        private(set) var acted = false

        /// Only the second press of a click pair runs the title-bar action; a third press (a
        /// triple click) is a fresh press again and does nothing on its own.
        var isSecondClick: Bool { clickCount == 2 }

        init(origin: NSPoint, clickCount: Int) {
            self.origin = origin
            self.clickCount = clickCount
        }

        private func movedBeyondThreshold(_ point: NSPoint) -> Bool {
            hypot(point.x - origin.x, point.y - origin.y) > WindowDrag.dragThreshold
        }

        mutating func moved(to point: NSPoint) -> Step {
            guard !handedOver, movedBeyondThreshold(point) else { return .none }
            handedOver = true
            return .drag
        }

        mutating func released(at point: NSPoint) -> Step {
            guard !handedOver, !acted, isSecondClick, !movedBeyondThreshold(point) else { return .none }
            acted = true
            return .act
        }
    }

    /// One drag area's press, from its `mouseDown` to its release. The view keeps this between
    /// events; `hand` and `run` are the two things a step can do, injectable so a test can see
    /// what was asked for without posting anything.
    @MainActor
    final class Held {
        /// The stored press, handed to the window server unchanged: `performDrag(with:)` needs the
        /// mouse-down event itself.
        let press: NSEvent
        let action: WindowDoubleClickAction
        private let hand: (NSEvent) -> Void
        private let run: (WindowDoubleClickAction) -> Void
        private(set) var state: Press

        /// The press point in screen coordinates, which a test drives the follow-ups from.
        var origin: NSPoint { state.origin }
        var handedOver: Bool { state.handedOver }

        /// Nil when this press is not the area's to take: a press on an overlay inside the page
        /// keeps its own click, and the views forward an unconsumed one to their superview (review
        /// M1 of review 5).
        init?(in view: NSView, with event: NSEvent,
              action: WindowDoubleClickAction = .fromDefaults(),
              hand: ((NSEvent) -> Void)? = nil,
              run: ((WindowDoubleClickAction) -> Void)? = nil) {
            guard event.type == .leftMouseDown, let window = view.window,
                  allowsDrag(styleMask: window.styleMask),
                  pressTarget(in: window, at: event.locationInWindow) === view else {
                return nil
            }
            self.press = event
            self.action = action
            self.state = Press(origin: window.convertPoint(toScreen: event.locationInWindow),
                               clickCount: event.clickCount)
            self.hand = hand ?? { [weak window] event in window?.performDrag(with: event) }
            self.run = run ?? { [weak window] action in
                guard let window else { return }
                WindowDrag.perform(action, in: window)
            }
        }

        /// The pointer while the button is down. The first point past the threshold hands the
        /// stored press over exactly once; later points, and points within the threshold, ask for
        /// nothing.
        func dragged(to point: NSPoint) {
            guard state.moved(to: point) == .drag else { return }
            hand(press)
        }

        /// The button came up. A second click that stayed within the threshold runs the action
        /// once; anything else, including a press that moved, asks for nothing.
        func released(at point: NSPoint) {
            guard state.released(at: point) == .act else { return }
            run(action)
        }
    }
}
