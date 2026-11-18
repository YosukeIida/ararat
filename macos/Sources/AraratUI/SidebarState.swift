import AppKit

@MainActor
enum SidebarMetrics {
    static let createSpaceInset: CGFloat = 14
    static let createSpaceGap: CGFloat = 6
    static let createSpaceFieldHeight: CGFloat = 36
    static let createSpaceProfileHeight: CGFloat = 59
    static let createSpaceButtonHeight: CGFloat = 36
    static let createSpaceTopInset: CGFloat = 70
    static let createSpaceHeaderGap: CGFloat = 18
    static let createSpaceHeadingSize: CGFloat = 20
    static let createSpaceBodySize: CGFloat = 14
    static let createSpaceCaptionSize: CGFloat = 12
    static let createSpaceCardInset: CGFloat = 10
    static let createSpaceCardRadius: CGFloat = 11
    static let createSpaceCancelHeight: CGFloat = 24
    static let createSpacePlusTrailing: CGFloat = 10
    static let libraryWidthIncrease: CGFloat = 70
    static let libraryButtonSize: CGFloat = 32
    static let libraryIconSize: CGFloat = 16
    static let libraryButtonLeading: CGFloat = 9
    static let libraryButtonBottom: CGFloat = 9
    static let libraryContentTop: CGFloat = 46
    static let libraryContentInset: CGFloat = 12
    static let archiveSearchHeight: CGFloat = 36
    static let archiveRowPitch: CGFloat = 56
    static let archiveListWidth: CGFloat = 304
    static let archiveRailContentWidth: CGFloat = 112
    static let archiveRailDividerWidth: CGFloat = 1
    static let archiveRowInset: CGFloat = 8
    static let archiveRowGap: CGFloat = 4
    static let archiveIconSize: CGFloat = 16
    static let archiveActionSize: CGFloat = 24
    static let archiveURLSize: CGFloat = 12
    static let archiveHeadingHeight: CGFloat = 32
    static let archiveHeadingLabelHeight: CGFloat = 18
    static let archiveBackHeight: CGFloat = 32
    static let archiveRowRadius: CGFloat = 8
    static let archiveHoverAlpha: CGFloat = 0.08
    static let libraryFontSize: CGFloat = 14
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
    static let spaceFollowFactor = 0.5
    static let spaceCreateThreshold = 165.0
    static let spaceCreateExitDuration = 0.070
    static let spaceVelocityWindow = 0.100
    static let spaceSwitchResponse = 0.250
    static let spaceSwitchDamping: CGFloat = 0.88
    static let spaceReturnResponse = 0.190
    static let spaceReturnDamping: CGFloat = 0.98
    static let spaceRubberDistance = 255.0
    static let spaceRubberCoefficient = 0.15
    static let spaceWheelWindow = 0.049
    static let spaceWheelThreshold = 1.0
    static let spaceWheelPause = 0.250
    static let momentumQuiet: TimeInterval = 0.150
    static let unloadedOpacity: CGFloat = 0.45
    // The row fill's two looks, both of the label colour: hovered 0.12, pressed or selected 0.22.
    // A split's segments are drawn in the first and the focused pane's segment in the second (the
    // U20 board's `.split span` and `.split span.on`).
    static let rowHoverFillAlpha: CGFloat = 0.12
    static let rowSelectedFillAlpha: CGFloat = 0.22
    // The U20 board's split row (`.split`): 36 pt segments 2 pt apart, the row's 11 pt radius on
    // the first and last segment's outer end and 4 pt inside (middle segments 4 pt all round);
    // each pane's glyph 16 pt at 10 pt from the segment's left and its title 13 pt at 32 pt.
    static let rowFillHeight: CGFloat = 36
    static let rowIconInset: CGFloat = 10
    static let splitSegmentGap: CGFloat = 2
    static let splitSegmentRadius: CGFloat = 4
    static let splitSegmentTitleLeading: CGFloat = 32
    static let splitSegmentTitleTrailing: CGFloat = 6
    static let splitSegmentTitleSize: CGFloat = 13
    static let rowCloseMoveDuration = 0.120
    static let rowCloseFadeDuration = 0.110
    static let easeOutCubic = CAMediaTimingFunction(controlPoints: 1 / 3, 1, 2 / 3, 1)
    // U25b: an open, empty folder's line, the Today divider block with its Clear button, the
    // New Tab row, and the space name row (D10).
    static let noTabsRowHeight: CGFloat = 24
    // The sidebar's secondary text size (the No tabs line, the Clear button's label, tooltips).
    static let secondaryFontSize: CGFloat = 12
    static let todayDividerHeight: CGFloat = 16
    // Sidebar x 18 to 80 from the edge; the rows column insets this block by 8.
    static let todayDividerLeading: CGFloat = 10
    static let todayDividerLineDrop: CGFloat = 8
    static let todayDividerTrailing: CGFloat = 72
    static let todayClearSize: CGFloat = 24
    static let todayClearTrailing: CGFloat = 8
    static let newTabRowHeight: CGFloat = 41
    static let spaceRowHeight: CGFloat = 31
    // D10: x 16 and x 40 in the sidebar; the column insets this row by 8.
    static let spaceNameLeading: CGFloat = 8
    static let spaceNameIndented: CGFloat = 32
    static let spaceChevronLeading: CGFloat = 8
    static let spaceChevronSize: CGFloat = 16
    static let spaceMoreTrailing: CGFloat = 16
    static let spaceMoreSize: CGFloat = 24
    static let unreadDotSize: CGFloat = 6
    // 16 is the multiples-of-8 rule (12 is not a value we may choose); the 6 pt dot is visual.
    static let unreadDotTrailing: CGFloat = 16
}

@MainActor
struct SidebarState {
    enum Mode: String { case docked, hidden, floating }
    private(set) var mode: Mode = .docked
    var hasSelection = false
    private(set) var dwellStartedAt: TimeInterval?

    mutating func restore(hidden: Bool) {
        mode = hidden ? .hidden : .docked
        dwellStartedAt = nil
    }

    mutating func hideForFullscreen() {
        mode = .hidden
        dwellStartedAt = nil
    }

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

    mutating func update(pointer: NSPoint, now: TimeInterval, window: NSRect, width: CGFloat, active: Bool, key: Bool, interacting: Bool = false) {
        guard mode != .docked else { dwellStartedAt = nil; return }
        guard hasSelection else { mode = .floating; dwellStartedAt = nil; return }
        guard active && key else { mode = .hidden; dwellStartedAt = nil; return }
        let x = pointer.x - window.minX
        let above = pointer.y > window.maxY
        let tooFarLeft = x < -SidebarMetrics.leftStayDistance
        if mode == .floating {
            guard !interacting else { return }
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
