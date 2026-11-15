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

/// One follow-up event of a press that is being tracked to its release. Positions are in screen
/// coordinates on purpose: a window we move ourselves would otherwise shift the frame a
/// window-relative point is measured against, and an event queued before a move would then be off
/// by that move (review M2).
struct PressFollowUp: Equatable {
    var type: NSEvent.EventType
    var screenLocation: NSPoint
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
    /// and move or zoom the window (review M1 of review 5).
    ///
    /// A first press (`clickCount` 1, and every press from the third on) hands the drag to the
    /// window server and never runs the title-bar action. Only a double click's second press is
    /// tracked to its release: the pointer travelling past `dragThreshold` makes it a drag of
    /// ours, and only a release that stayed within the threshold runs the action — so a double
    /// click whose second press drags moves the window and never zooms it.
    static func press(in view: NSView, with event: NSEvent, action: WindowDoubleClickAction = .fromDefaults()) {
        guard event.type == .leftMouseDown, let window = view.window, allowsDrag(styleMask: window.styleMask),
              pressTarget(in: window, at: event.locationInWindow) === view else { return }
        // Only the second press of a click pair runs the title-bar action; a third press (a
        // triple click) is a fresh first press again (review L2 of review 6).
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        // Why we move the window ourselves instead of handing the second press to the window
        // server: `performDrag(with:)` needs the press, and the press is already spent once the
        // tracking below has begun. The window still follows the pointer, gesture for gesture.
        var tracker = SecondPressTracker(pressScreen: NSEvent.mouseLocation)
        let size = window.frame.size
        var target = window.frame.origin
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: 5, mode: .eventTracking) { followUp, stop in
            // A nil event is the timeout: the release we were waiting for is lost, so the press
            // ends here with no action and no move (review M1 of review 6). `mouseLocation` is
            // the pointer's screen position at handling time, which our own window moves cannot
            // skew (review M2 of review 6).
            let step = followUp.map { PressFollowUp(type: $0.type, screenLocation: NSEvent.mouseLocation) }
            let done = handleSecondPress(step, tracker: &tracker, move: { delta in
                target.x += delta.x
                target.y += delta.y
                window.setFrameOrigin(constrainedFrame(from: target, size: size, in: window).origin)
            }, act: {
                perform(action, in: window)
            })
            if done { stop.pointee = true }
        }
    }

    /// One step of the second press, extracted so a test can drive the same loop with fake
    /// events (a nil timeout, a queued point, a release). `move` applies one screen-coordinate
    /// delta to the window and `act` runs the title-bar action. Answers whether the press is
    /// over.
    @discardableResult
    static func handleSecondPress(_ followUp: PressFollowUp?, tracker: inout SecondPressTracker,
                                  move: (NSPoint) -> Void, act: () -> Void) -> Bool {
        guard let followUp else { return true }
        switch tracker.handle(followUp) {
        case .ignore: return false
        case .move(let delta):
            move(delta)
            return false
        case .action:
            act()
            return true
        case .end:
            return true
        }
    }

    /// The frame a manual drag step moves to, constrained the way the system keeps a window's
    /// title bar reachable (review L1 of review 6). The caller keeps its unconstrained target: an
    /// overshoot pins the window at the clamp until the pointer has come back by the overshoot,
    /// which is what a title-bar drag does (measured on the host, 2026-11-16: a 40 pt overshoot
    /// kept the window pinned through the next 40 pt of the pointer's return, then it followed).
    static func constrainedFrame(from target: NSPoint, size: NSSize, in window: NSWindow) -> NSRect {
        window.constrainFrameRect(NSRect(origin: target, size: size), to: window.screen)
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
            /// A drag step: move the window by this screen-coordinate delta.
            case move(NSPoint)
            /// The release of a stationary second click: run the title-bar action.
            case action
            /// The press is over and nothing more is owed.
            case end
        }

        private(set) var pressScreen: NSPoint
        private var lastScreen: NSPoint
        private(set) var dragging = false

        init(pressScreen: NSPoint) {
            self.pressScreen = pressScreen
            self.lastScreen = pressScreen
        }

        mutating func handle(_ followUp: PressFollowUp) -> Step {
            let point = followUp.screenLocation
            switch followUp.type {
            case .leftMouseDragged:
                if !dragging && hypot(point.x - pressScreen.x, point.y - pressScreen.y) <= WindowDrag.dragThreshold {
                    return .ignore
                }
                dragging = true
                let delta = NSPoint(x: point.x - lastScreen.x, y: point.y - lastScreen.y)
                lastScreen = point
                return .move(delta)
            case .leftMouseUp:
                guard !dragging else { return .end }
                return hypot(point.x - pressScreen.x, point.y - pressScreen.y) <= WindowDrag.dragThreshold
                    ? .action : .end
            default:
                return .ignore
            }
        }
    }
}
