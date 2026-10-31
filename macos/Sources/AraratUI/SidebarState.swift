import AppKit

@MainActor
enum SidebarMetrics {
    static let defaultWidth: CGFloat = 240
    static let minimumWidth: CGFloat = 164
    static let maximumWidth: CGFloat = 500
    static let collapseX: CGFloat = 81
    static let edgeZone: CGFloat = 5
    static let leftStayDistance: CGFloat = 250
    static let rightStayDistance: CGFloat = 72
    static let revealDwell: TimeInterval = 0.150
    static let floatingResponse: TimeInterval = 0.150
    static let floatingDamping: CGFloat = 0.84
    static let floatingHideDuration: TimeInterval = 0.090
    static let dockHideDuration: TimeInterval = 0.090
    static let dockShowDuration: TimeInterval = 0.100
    static let floatingInset: CGFloat = 5
    static let cornerRadius: CGFloat = 11
    static let borderWidth: CGFloat = 1
    static let borderAlpha: CGFloat = 0.35
    static let grabInset: CGFloat = 4
    static let grabWidth: CGFloat = 5
    static let cardInset: CGFloat = 10
    static let easeOutCubic = CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
}

@MainActor
struct SidebarState {
    enum Mode: String { case docked, hidden, floating }
    private(set) var mode: Mode = .docked
    var hasSelection = false
    private(set) var dwellStartedAt: TimeInterval?

    mutating func toggle() {
        mode = mode == .docked ? (hasSelection ? .hidden : .floating) : .docked
        dwellStartedAt = nil
    }

    mutating func collapseDrag(pointerX: CGFloat) -> Bool {
        guard pointerX < SidebarMetrics.collapseX else { return false }
        mode = hasSelection ? .hidden : .floating
        dwellStartedAt = nil
        return true
    }

    mutating func update(pointer: NSPoint, now: TimeInterval, window: NSRect, width: CGFloat, active: Bool, key: Bool) {
        guard mode != .docked else { dwellStartedAt = nil; return }
        guard hasSelection else { mode = .floating; dwellStartedAt = nil; return }
        guard active && key else { mode = .hidden; dwellStartedAt = nil; return }
        let x = pointer.x - window.minX
        let above = pointer.y > window.maxY
        let tooFarLeft = x < -SidebarMetrics.leftStayDistance
        if mode == .floating {
            if above || tooFarLeft || x > SidebarMetrics.floatingInset + width + SidebarMetrics.rightStayDistance {
                mode = .hidden
            }
            return
        }
        let inZone = !above && pointer.y >= window.minY && !tooFarLeft && x <= SidebarMetrics.edgeZone
        guard inZone else { dwellStartedAt = nil; return }
        if let start = dwellStartedAt {
            if now >= start + SidebarMetrics.revealDwell { mode = .floating; dwellStartedAt = nil }
        } else {
            dwellStartedAt = now
        }
    }
}
