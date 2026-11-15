import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// P4 item 1: the window moves from the sidebar's empty areas and from the frame around the page
/// card, and not from a row, a dock cell or a control (the owner, 2026-11-15). Each step posts a
/// press, two moves and a release at the window server and reads the window's frame: the first
/// move is just past 3 pt and is what hands the press over, and the second is the motion the
/// window follows after it. The events go to the HID tap because `NSWindow.performDrag(with:)`
/// does not start from an event injected into the app's own queue: measured on the host
/// (2026-11-16), a pre-pressed event returns at once and the frame stays, while an event the
/// window server delivers starts the drag and follows the later moves.
///
/// The drag views store the press on `mouseDown` and hand it to `performDrag(with:)` on the first
/// `mouseDragged` past 3 pt (design, 2026-11-16), so this check's posted sequence is the whole
/// model: without the move nothing moves, and a stationary second press is what runs the
/// title-bar action. `WindowDrag` traces each of those steps, and the check's own run turns that
/// trace on, so a VM run shows whether a posted `leftMouseDragged` reaches the drag view at all.
/// The check also captures the row list's scroller after a scroll (P4 item 5), which needs the
/// same drawn sidebar.
@MainActor
final class WindowDragCheckState {
    /// One posted gesture: where the press lands, how far the pointer travels, and whether the
    /// window is expected to follow it.
    struct Step {
        var name: String
        var point: String
        var delta: NSPoint
        var movesWindow: Bool
    }

    static let names = ["seed", "post_permission", "regions", "frame_stable", "points_inside_screen", "header_point",
                        "sidebar_drag", "header_drag", "above_card_drag", "cell_keeps_frame",
                        "row_keeps_frame", "scroller_overlay", "scroller_after_scroll",
                        "scroller_hidden_immediately"]
    static let screens = ["capture_sidebar", "capture_scroller", "capture_scroller_later",
                          "capture_scroller_horizontal"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var details: [String: Any] = [:]
    var waitName = ""
    var waitTicks = 0
    /// The frame phase 0 recorded; every step starts from it and the check asserts it.
    var baseFrame = NSRect.zero
    /// A point on the page, away from every drag area: each gesture parks the pointer there, so
    /// the window server cannot chain two presses into a double click.
    var neutralPoint = NSPoint.zero
    /// False when a step started from a frame other than `baseFrame` (a leftover zoom).
    var frameStable = true
    var frameBefore = NSRect.zero
    var dragDelta = NSPoint.zero
    /// The offset from the press to the dragged point that hands the drag over: the window server
    /// may catch the window up from it, or move it only with the motion after it (review M1 of
    /// review 8).
    var handover = NSPoint.zero
    var points: [String: NSPoint] = [:]
    var targets: [String: String] = [:]
    var steps: [Step] = []
    var stepIndex = 0
    var dragDeadline: TimeInterval = 0
    var laterDeadline: TimeInterval = 0
    /// Set once a positive step moved the window, so a "no frame change" step cannot pass when
    /// nothing was delivered at all.
    var movedPositive = false
    var capturing = false

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: window-drag \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: String) {
        if waitName != name || waitTicks % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: window-drag wait=\(name) current=\(value)\n".utf8))
        }
        if waitName != name { waitTicks = 0; waitName = name }
        waitTicks += 1
    }

    static func conditionNames(screen: Bool) -> [String] {
        names + (screen ? screens : [])
    }

    static func mouseEvent(_ type: CGEventType, at point: CGPoint, from previous: CGPoint? = nil) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return nil }
        let previous = previous ?? point
        // Do not rely on source state for deltas; each drag follows the previous posted point.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        return event
    }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                "failed_conditions": names.filter { conditions[$0] != true },
                "images": images, "details": details, "targets": targets, "steps": steps.map(\.name),
                "points": points.mapValues { ["x": $0.x, "y": $0.y] }, "wait": waitName,
                "unverified": ["A double-click on the title bar areas (the check posts one stationary press per drag; the rule is a pure test)",
                               "A full-screen window's refusal (pinned as a pure rule)",
                               "The knob's drawn shape and its fade (design reads the captures)"]]
    }
}

extension Runtime {
    func windowDragCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if windowDragCheck == nil { windowDragCheck = WindowDragCheckState() }
        guard let check = windowDragCheck, !check.capturing, let sidebar, let container else { return }
        let window = host.window()
        func wait(_ name: String) {
            check.wait(name, "phase=\(browserCheckPhase) step=\(check.stepIndex) frame=\(window.frame) key=\(window.isKeyWindow) visible=\(window.isVisible)")
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            // The screenshot spins the run loop; a tick arriving inside it must not start another
            // step (the other checks' `capturing` flag).
            check.capturing = true; defer { check.capturing = false }
            guard let path = promptScreenScreenshot(window, name: "window-drag-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        /// A real event at the HID tap, at a CG screen point (top-left origin) computed once
        /// before anything is posted: a point converted later would follow a window the first
        /// event has already moved (review M1).
        func post(_ type: CGEventType, at point: CGPoint, from previous: CGPoint? = nil) {
            guard let event = WindowDragCheckState.mouseEvent(type, at: point, from: previous) else { return }
            FileHandle.standardError.write(Data("ararat-trace: window-drag post type=\(type.rawValue) at=\(point) delta=\(event.getIntegerValueField(.mouseEventDeltaX)),\(event.getIntegerValueField(.mouseEventDeltaY)) frame=\(window.frame)\n".utf8))
            event.post(tap: .cghidEventTap)
        }
        /// The window point in AppKit screen coordinates and in CG's top-left screen coordinates.
        func appKitScreen(_ point: NSPoint) -> NSPoint { window.convertPoint(toScreen: point) }
        func cgScreen(_ point: NSPoint) -> CGPoint {
            let flipped = (NSScreen.screens.first?.frame.height ?? 0) - point.y
            return CGPoint(x: point.x, y: flipped)
        }
        /// Press, move and release over time: the drag session needs the press delivered before
        /// the move, and the frame is read after the release. Every point is fixed in screen
        /// coordinates first. A gesture starts with the pointer parked on the page, inside the
        /// screen's visible frame, and waits longer than the double-click interval, so the window
        /// server sees one lone click rather than the second of a pair. A drag that reached the
        /// menu bar, or left the visible frame, would fill the screen instead of moving the
        /// window by design's rerun (review H2).
        func start(_ step: WindowDragCheckState.Step) {
            let startPoint = check.points[step.point] ?? .zero
            let endPoint = NSPoint(x: startPoint.x + step.delta.x, y: startPoint.y + step.delta.y)
            check.frameBefore = window.frame
            check.dragDelta = step.delta
            // The check's precondition: a leftover zoom or a failed restore must not decide this
            // step, so the frame is asserted and named before anything is posted.
            let stable = check.frameBefore.origin == check.baseFrame.origin && check.frameBefore.size == check.baseFrame.size
            if !stable {
                check.frameStable = false
                check.details["frame_mismatch_\(step.name)"] = ["expected": ["x": check.baseFrame.origin.x, "y": check.baseFrame.origin.y,
                                                                          "width": check.baseFrame.width, "height": check.baseFrame.height],
                                                                 "before": ["x": check.frameBefore.origin.x, "y": check.frameBefore.origin.y,
                                                                            "width": check.frameBefore.width, "height": check.frameBefore.height]]
            }
            let startScreen = appKitScreen(startPoint)
            let endScreen = appKitScreen(endPoint)
            let neutralScreen = appKitScreen(check.neutralPoint)
            let visible = (window.screen ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            let inside = visible.contains(startScreen) && visible.contains(endScreen) && visible.contains(neutralScreen)
            if !inside {
                check.mark("points_inside_screen", false)
                check.details["outside_screen_\(step.name)"] = ["visible": ["x": visible.minX, "y": visible.minY,
                                                                           "width": visible.width, "height": visible.height],
                                                                 "start": ["x": startScreen.x, "y": startScreen.y],
                                                                 "end": ["x": endScreen.x, "y": endScreen.y]]
            }
            // Every posted point stays inside the screen's visible frame: a drag that reached the
            // menu bar or an edge would fill the screen instead of moving the window (review H2).
            // A point that had to be pulled in is recorded; `points_inside_screen` has already
            // named the step whose intended geometry was outside.
            let safe = visible.insetBy(dx: 1, dy: 1)
            func posted(_ point: NSPoint) -> NSPoint {
                let clamped = NSPoint(x: min(max(point.x, safe.minX), safe.maxX),
                                      y: min(max(point.y, safe.minY), safe.maxY))
                if clamped != point {
                    check.details["clamped_\(step.name)"] = ["intended": ["x": point.x, "y": point.y],
                                                             "posted": ["x": clamped.x, "y": clamped.y]]
                }
                return clamped
            }
            // The target this check expects the press to reach, computed before it is posted: a
            // prediction, not the view AppKit dispatches to (review L3 of review 6).
            let predictedHit = container.checkPressTarget(at: startPoint)
            FileHandle.standardError.write(Data("ararat-trace: window-drag drag step=\(step.name) from=\(startPoint) to=\(endPoint) frame=\(window.frame) base=\(check.baseFrame) stable=\(stable) inside=\(inside) predicted_hit=\(predictedHit) key=\(window.isKeyWindow)\n".utf8))
            let startCG = cgScreen(posted(startScreen)), endCG = cgScreen(posted(endScreen)), neutralCG = cgScreen(posted(neutralScreen))
            // A dragged point just past 3 pt comes first: that point is what hands the press to
            // the window server, and the end point is the motion that follows the hand-over, so
            // the drag is not left with only the release to come (review M1 of review 8).
            let length = hypot(step.delta.x, step.delta.y)
            let handover = length > 0 ? NSPoint(x: step.delta.x * min(5, length) / length,
                                                y: step.delta.y * min(5, length) / length) : .zero
            let midwayScreen = NSPoint(x: startScreen.x + handover.x, y: startScreen.y + handover.y)
            // The window server may catch the window up from the press at the hand-over, or move
            // it only with the motion after it: both are accepted, and which one happened is
            // recorded, so a shortfall of up to the hand-over offset is not read as a fault.
            check.handover = handover
            let midwayCG = cgScreen(posted(midwayScreen))
            let gap = max(0.9, NSEvent.doubleClickInterval + 0.3)
            post(.mouseMoved, at: neutralCG)
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { post(.leftMouseDown, at: startCG) }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.15) { post(.leftMouseDragged, at: midwayCG, from: startCG) }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.30) { post(.leftMouseDragged, at: endCG, from: midwayCG) }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.45) { post(.leftMouseUp, at: endCG) }
            check.dragDeadline = ProcessInfo.processInfo.systemUptime + gap + 0.9
        }
        /// Back to the frame phase 0 recorded, origin and size: a leftover zoom from one step must
        /// not make the next step fail or pass for the wrong reason.
        func restore() {
            window.setFrame(check.baseFrame, display: false)
        }
        func finish() {
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        switch browserCheckPhase {
        case 0:
            guard window.isVisible, window.isKeyWindow, !sidebar.checkCreateSpace.open,
                  let rowPoint = sidebar.checkRowPoint(), let cellPoint = sidebar.checkDockCellPoint() else {
                wait("key window, row and dock cell"); return
            }
            // Why first: without permission to post events at the window server every gesture
            // below is dropped silently, and the "no frame change" steps would pass for the wrong
            // reason (review M2).
            let canPost = CGPreflightPostEventAccess()
            check.mark("post_permission", canPost)
            guard canPost else { finish(); return }
            check.points = sidebar.checkDragAreaPoints()
            check.points["header_gap"] = container.checkHeaderGapPoint()
            check.points["above_card"] = container.checkAboveCardPoint()
            check.points["row"] = rowPoint
            check.points["dock_cell"] = cellPoint
            for (name, point) in check.points {
                check.targets[name] = container.checkPressTarget(at: point)
            }
            // The empty sidebar areas reach the sidebar (or its list), the header's gap its own
            // view and the card's margins the container: all of them are the title bar.
            let empty = ["below_rows", "dock_gap", "column_gap"].compactMap { check.targets[$0] }
            check.mark("regions", check.targets["above_card"] == "frame"
                       && check.targets["header_gap"] == "header"
                       && empty.allSatisfy { $0 == "sidebar" || $0 == "list" }
                       && check.targets["row"] != "frame" && check.targets["row"] != "sidebar"
                       && check.targets["dock_cell"] != "frame" && check.targets["dock_cell"] != "sidebar")
            check.mark("header_point", check.targets["header_gap"] == "header")
            check.mark("seed", !empty.isEmpty)
            check.mark("points_inside_screen", true)
            // The frame every step starts from, and the pointer's parking place on the page.
            check.baseFrame = window.frame
            check.neutralPoint = NSPoint(x: max(60, window.frame.width - 60), y: 60)
            if screen { check.mark("capture_sidebar", capture("sidebar")) }
            let sidebarPoint = check.points["below_rows"] != nil ? "below_rows"
                : (check.points["dock_gap"] != nil ? "dock_gap" : "column_gap")
            check.steps = [
                .init(name: "sidebar_drag", point: sidebarPoint,
                      delta: NSPoint(x: 60, y: -40), movesWindow: true),
                .init(name: "header_drag", point: "header_gap", delta: NSPoint(x: 40, y: -30), movesWindow: true),
                // Downward on purpose (review H2): a drag up into the menu bar fills the
                // screen on this macOS, which is not our window drag at all.
                .init(name: "above_card_drag", point: "above_card", delta: NSPoint(x: -40, y: -30), movesWindow: true),
                .init(name: "cell_keeps_frame", point: "dock_cell", delta: NSPoint(x: 0, y: -6), movesWindow: false),
                .init(name: "row_keeps_frame", point: "row", delta: NSPoint(x: 0, y: -20), movesWindow: false),
            ]
            start(check.steps[0])
            browserCheckPhase = 1
        case 1:
            guard ProcessInfo.processInfo.systemUptime >= check.dragDeadline else { wait("drag \(check.stepIndex)"); return }
            let step = check.steps[check.stepIndex]
            let after = window.frame
            // The window follows the motion after the hand-over; whether the window server also
            // catches it up from the press is not known, so the full delta and the delta less the
            // hand-over offset are both accepted, and the anchor is recorded (review M1 of
            // review 8). A real hand loses the same few points.
            let full = NSPoint(x: check.frameBefore.origin.x + check.dragDelta.x,
                               y: check.frameBefore.origin.y + check.dragDelta.y)
            let handOver = NSPoint(x: full.x - check.handover.x, y: full.y - check.handover.y)
            let movedFull = abs(after.origin.x - full.x) <= 2 && abs(after.origin.y - full.y) <= 2
            let movedFromHandOver = abs(after.origin.x - handOver.x) <= 3 && abs(after.origin.y - handOver.y) <= 3
            let moved = movedFull || movedFromHandOver
            if step.movesWindow {
                check.movedPositive = check.movedPositive || moved
                check.mark(step.name, moved)
            } else {
                // A "no frame change" step only means something once a posted gesture has moved
                // the window in this run; otherwise it passes because nothing was delivered.
                check.mark(step.name, check.movedPositive && after == check.frameBefore)
            }
            check.details[step.name] = ["from": step.point, "moves": step.movesWindow,
                                        "before": ["x": check.frameBefore.origin.x, "y": check.frameBefore.origin.y],
                                        "expected": ["x": full.x, "y": full.y],
                                        "expected_from_hand_over": ["x": handOver.x, "y": handOver.y],
                                        "anchor": movedFull ? "full" : (movedFromHandOver ? "hand_over" : "none"),
                                        "after": ["x": after.origin.x, "y": after.origin.y],
                                        "delta": ["x": check.dragDelta.x, "y": check.dragDelta.y]]
            restore()
            check.stepIndex += 1
            guard check.stepIndex < check.steps.count else {
                check.mark("frame_stable", check.frameStable)
                // P4 item 5: the row list is always the overlay knob, and a vertical scroll shows it.
                check.mark("scroller_overlay", sidebar.checkListScroller.style == .overlay)
                sidebar.checkScrollList(dx: 0, dy: -24)
                check.mark("scroller_after_scroll", sidebar.checkListScroller.hasVerticalScroller)
                if screen { check.mark("capture_scroller", capture("scroller-scroll")) }
                check.laterDeadline = ProcessInfo.processInfo.systemUptime + 2.0
                browserCheckPhase = 2
                return
            }
            start(check.steps[check.stepIndex])
        case 2:
            guard ProcessInfo.processInfo.systemUptime >= check.laterDeadline else { wait("the overlay's fade"); return }
            // Two seconds after the scroll the system's overlay scroller has faded: the capture
            // must show no knob (design reads it).
            if screen { check.mark("capture_scroller_later", capture("scroller-later")) }
            sidebar.checkScrollList(dx: 20, dy: 0)
            check.mark("scroller_hidden_immediately", !sidebar.checkListScroller.hasVerticalScroller)
            if screen { check.mark("capture_scroller_horizontal", capture("scroller-horizontal")) }
            finish()
        default:
            break
        }
    }
}
