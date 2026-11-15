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

/// One follow-up event of a press that is being tracked to its release.
struct PressFollowUp: Equatable {
    var type: NSEvent.EventType
    /// In screen coordinates: a window we move ourselves would otherwise shift the frame the
    /// next point is measured against.
    var location: NSPoint
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
    /// A single press (`clickCount` 1) hands the drag to the window server and never runs the
    /// title-bar action. A second press (a double click's second click) is tracked to its
    /// release: the pointer travelling past `dragThreshold` makes it a drag of ours, and only a
    /// release that stayed within the threshold runs the action — so a double click whose second
    /// press drags moves the window and never zooms it (review H1).
    static func press(in view: NSView, with event: NSEvent, action: WindowDoubleClickAction = .fromDefaults()) {
        guard event.type == .leftMouseDown, let window = view.window, allowsDrag(styleMask: window.styleMask),
              pressTarget(in: window, at: event.locationInWindow) === view else { return }
        guard event.clickCount >= 2 else {
            window.performDrag(with: event)
            return
        }
        // Why we move the window ourselves instead of handing the second press to the window
        // server: `performDrag(with:)` needs the press, and the press is already spent once the
        // tracking below has begun. The window still follows the pointer, gesture for gesture.
        var tracker = SecondPressTracker(press: window.convertPoint(toScreen: event.locationInWindow))
        var origin = window.frame.origin
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: 5, mode: .eventTracking) { followUp, stop in
            guard let followUp else { return }
            // Each point is converted before the window moves for it, so the tracker sees the
            // pointer's own travel in screen coordinates.
            let location = window.convertPoint(toScreen: followUp.locationInWindow)
            switch tracker.handle(PressFollowUp(type: followUp.type, location: location)) {
            case .ignore:
                break
            case .move(let delta):
                origin.x += delta.x
                origin.y += delta.y
                window.setFrameOrigin(origin)
            case .action:
                perform(action, in: window)
                stop.pointee = true
            case .end:
                stop.pointee = true
            }
        }
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

    /// The rule for a second press, as a state machine so a test can feed it the follow-up events
    /// without dispatching anything: up to the threshold the press stays a stationary click (the
    /// action runs on the release); past it the press is a drag, each step moving the window by
    /// the pointer's own screen step, and the release runs nothing.
    struct SecondPressTracker {
        enum Step: Equatable {
            /// Not decided yet: the pointer is still within the threshold, or the event is not one
            /// this tracker reads.
            case ignore
            /// A drag step: move the window by this window-coordinate delta.
            case move(NSPoint)
            /// The release of a stationary second click: run the title-bar action.
            case action
            /// The press is over and nothing more is owed.
            case end
        }

        private(set) var press: NSPoint
        private var last: NSPoint
        private(set) var dragging = false

        init(press: NSPoint) {
            self.press = press
            self.last = press
        }

        var travelled: CGFloat {
            hypot(last.x - press.x, last.y - press.y)
        }

        mutating func handle(_ followUp: PressFollowUp) -> Step {
            switch followUp.type {
            case .leftMouseDragged:
                if !dragging && hypot(followUp.location.x - press.x, followUp.location.y - press.y) <= WindowDrag.dragThreshold {
                    return .ignore
                }
                dragging = true
                let delta = NSPoint(x: followUp.location.x - last.x, y: followUp.location.y - last.y)
                last = followUp.location
                return .move(delta)
            case .leftMouseUp:
                guard !dragging else { return .end }
                return hypot(followUp.location.x - press.x, followUp.location.y - press.y) <= WindowDrag.dragThreshold
                    ? .action : .end
            default:
                return .ignore
            }
        }
    }
}
