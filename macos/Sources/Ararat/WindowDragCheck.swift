import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// P4 item 1: the window moves from the sidebar's empty areas and from the frame around the page
/// card, and not from a row, a dock cell or a control (the owner, 2026-11-15). Each step posts a
/// pressed drag at the window server and reads the window's frame. The events go to the HID tap
/// because `NSWindow.performDrag(with:)` does not start from an event injected into the app's own
/// queue: measured on the host (2026-11-16), a pre-pressed event returns at once and the frame
/// stays, while an event the window server delivers starts the drag and follows the later moves.
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

    static let names = ["seed", "post_permission", "regions", "frame_stable", "header_point",
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
        /// A real event at the HID tap. CG's screen origin is the main display's top-left corner,
        /// so AppKit's bottom-left point is flipped before posting. Every press and release is
        /// posted with click state 1: successive gestures are separate presses, and the guest's
        /// window server must not chain them into a double click.
        func post(_ type: CGEventType, at point: NSPoint) {
            let appKitScreen = window.convertPoint(toScreen: point)
            guard let main = NSScreen.screens.first,
                  let source = CGEventSource(stateID: .hidSystemState),
                  let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: CGPoint(x: appKitScreen.x, y: main.frame.height - appKitScreen.y),
                                      mouseButton: .left) else { return }
            if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
            event.post(tap: .cghidEventTap)
        }
        /// Press, move and release over time: the drag session needs the press delivered before
        /// the move, and the frame is read after the release. A gesture starts with the pointer
        /// parked on the page and waits longer than the double-click interval, so the window
        /// server sees one lone click rather than the second of a pair.
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
            FileHandle.standardError.write(Data("ararat-trace: window-drag drag step=\(step.name) from=\(startPoint) to=\(endPoint) frame=\(window.frame) base=\(check.baseFrame) stable=\(stable)\n".utf8))
            let gap = max(0.9, NSEvent.doubleClickInterval + 0.3)
            post(.mouseMoved, at: check.neutralPoint)
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { post(.leftMouseDown, at: startPoint) }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.20) { post(.leftMouseDragged, at: endPoint) }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.45) { post(.leftMouseUp, at: endPoint) }
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
                .init(name: "above_card_drag", point: "above_card", delta: NSPoint(x: -40, y: 30), movesWindow: true),
                .init(name: "cell_keeps_frame", point: "dock_cell", delta: NSPoint(x: 0, y: -6), movesWindow: false),
                .init(name: "row_keeps_frame", point: "row", delta: NSPoint(x: 0, y: -20), movesWindow: false),
            ]
            start(check.steps[0])
            browserCheckPhase = 1
        case 1:
            guard ProcessInfo.processInfo.systemUptime >= check.dragDeadline else { wait("drag \(check.stepIndex)"); return }
            let step = check.steps[check.stepIndex]
            let after = window.frame
            let moved = abs(after.origin.x - (check.frameBefore.origin.x + check.dragDelta.x)) <= 2
                && abs(after.origin.y - (check.frameBefore.origin.y + check.dragDelta.y)) <= 2
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
                                        "expected": ["x": check.frameBefore.origin.x + (step.movesWindow ? check.dragDelta.x : 0),
                                                     "y": check.frameBefore.origin.y + (step.movesWindow ? check.dragDelta.y : 0)],
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
