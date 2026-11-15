import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// P4 item 1: the window moves from the sidebar's empty areas and from the frame around the page
/// card, and not from a row, a dock cell or a control (the owner, 2026-11-15). The check posts a
/// pressed drag and reads the window's frame; it also captures the row list's scroller after a
/// scroll (P4 item 5), which needs the same drawn sidebar.
@MainActor
final class WindowDragCheckState {
    static let names = ["seed", "regions", "row_keeps_frame", "cell_keeps_frame", "sidebar_drag",
                        "above_card_drag", "header_point", "scroller_overlay", "scroller_after_scroll",
                        "scroller_hidden_immediately"]
    static let screens = ["capture_sidebar", "capture_scroller", "capture_scroller_later", "capture_scroller_horizontal"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var details: [String: Any] = [:]
    var waitName = ""
    var waitTicks = 0
    var frameBefore = NSRect.zero
    var dragPoint = NSPoint.zero
    var dragDelta = NSPoint.zero
    var points: [String: NSPoint] = [:]
    var targets: [String: String] = [:]
    var laterDeadline: TimeInterval = 0
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
                "images": images, "details": details, "targets": targets,
                "points": points.mapValues { ["x": $0.x, "y": $0.y] }, "wait": waitName,
                "unverified": ["A double-click on the title bar areas (the check posts one press per drag)",
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
            check.wait(name, "phase=\(browserCheckPhase) frame=\(window.frame) key=\(window.isKeyWindow) visible=\(window.isVisible)")
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
        func post(_ type: NSEvent.EventType, at point: NSPoint) {
            // The posted location is read back as `locationInWindow` (NSEvent.mouseEvent stores
            // it unchanged; the window number only picks the window), so these are window points,
            // as the split-divider check's are.
            guard let event = NSEvent.mouseEvent(with: type, location: point,
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 1, clickCount: 1, pressure: 1) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        /// A press, one move and a release at window points. The end point is computed before
        /// the window moves, so the pointer's travel is the delta the window follows.
        func drag(from start: NSPoint, by delta: NSPoint) {
            let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
            post(.leftMouseDown, at: start)
            post(.leftMouseDragged, at: end)
            post(.leftMouseUp, at: end)
            check.frameBefore = window.frame
            check.dragPoint = start
            check.dragDelta = delta
        }
        func moved() -> Bool {
            abs(window.frame.origin.x - (check.frameBefore.origin.x + check.dragDelta.x)) <= 2
                && abs(window.frame.origin.y - (check.frameBefore.origin.y + check.dragDelta.y)) <= 2
        }
        func restore() {
            window.setFrameOrigin(check.frameBefore.origin)
        }
        func finish() {
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        switch browserCheckPhase {
        case 0:
            guard window.isVisible, window.isKeyWindow, !sidebar.checkCreateSpace.open,
                  let rowPoint = sidebar.checkRowPoint(), let cellPoint = sidebar.checkDockCellPoint() else { wait("key window, row and dock cell"); return }
            check.points = sidebar.checkDragAreaPoints()
            check.points["header_gap"] = container.checkHeaderGapPoint()
            check.points["above_card"] = container.checkAboveCardPoint()
            check.points["row"] = rowPoint
            check.points["dock_cell"] = cellPoint
            for (name, point) in check.points {
                check.targets[name] = container.checkPressTarget(at: point)
            }
            // The empty sidebar areas reach the sidebar (or its list) and the card's margins the
            // container; both are the window's title bar.
            let empty = ["below_rows", "dock_gap", "column_gap"].compactMap { check.targets[$0] }
            check.mark("regions", check.targets["above_card"] == "frame"
                       && check.targets["header_gap"] == "header"
                       && empty.allSatisfy { $0 == "sidebar" || $0 == "list" }
                       && check.targets["row"] != "frame" && check.targets["row"] != "sidebar"
                       && check.targets["dock_cell"] != "frame" && check.targets["dock_cell"] != "sidebar")
            check.mark("header_point", check.targets["header_gap"] == "header")
            check.mark("seed", !empty.isEmpty)
            if screen { check.mark("capture_sidebar", capture("sidebar")) }
            drag(from: rowPoint, by: NSPoint(x: 0, y: -20))
            browserCheckPhase = 1
        case 1:
            check.mark("row_keeps_frame", window.frame == check.frameBefore)
            restore()
            drag(from: check.points["dock_cell"] ?? .zero, by: NSPoint(x: 0, y: -6))
            browserCheckPhase = 2
        case 2:
            check.mark("cell_keeps_frame", window.frame == check.frameBefore)
            restore()
            drag(from: check.points["below_rows"] ?? check.points["dock_gap"] ?? .zero, by: NSPoint(x: 60, y: -40))
            browserCheckPhase = 3
        case 3:
            check.mark("sidebar_drag", moved())
            restore()
            drag(from: check.points["above_card"] ?? .zero, by: NSPoint(x: -40, y: 30))
            browserCheckPhase = 4
        case 4:
            check.mark("above_card_drag", moved())
            restore()
            // P4 item 5: the row list is always the overlay knob, and a vertical scroll shows it.
            let scroller = sidebar.checkListScroller
            check.mark("scroller_overlay", scroller.style == .overlay)
            sidebar.checkScrollList(dx: 0, dy: -24)
            check.mark("scroller_after_scroll", sidebar.checkListScroller.hasVerticalScroller)
            if screen { check.mark("capture_scroller", capture("scroller-scroll")) }
            check.laterDeadline = ProcessInfo.processInfo.systemUptime + 2.0
            browserCheckPhase = 5
        case 5:
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
