import AppKit

@MainActor
public final class SidebarResizeHandle: NSView {
    private let widthConstraint: NSLayoutConstraint
    private var userWidth: CGFloat
    var widthExtension: CGFloat = 0 { didSet { applyWidth() } }
    var displayedWidth: CGFloat { userWidth + widthExtension }
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private var collapsedDuringDrag = false
    var onDrag: ((CGFloat) -> Bool)?
    var onWidthChanged: (() -> Void)?

    public var sidebarWidth: CGFloat {
        get { userWidth }
        set {
            userWidth = min(SidebarMetrics.maximumWidth, max(SidebarMetrics.minimumWidth, newValue))
            applyWidth()
            setAccessibilityValue(widthConstraint.constant)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    public init(widthConstraint: NSLayoutConstraint) {
        self.widthConstraint = widthConstraint
        userWidth = widthConstraint.constant
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Sidebar width")
        setAccessibilityValue(sidebarWidth)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyWidth() {
        widthConstraint.constant = displayedWidth
        onWidthChanged?()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    public func resetWidth() { sidebarWidth = SidebarMetrics.defaultWidth }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override public func mouseDown(with event: NSEvent) {
        collapsedDuringDrag = false
        dragStartX = event.locationInWindow.x
        dragStartWidth = sidebarWidth
    }

    override public func mouseDragged(with event: NSEvent) {
        guard !collapsedDuringDrag else { return }
        if onDrag?(event.locationInWindow.x) == true { collapsedDuringDrag = true; return }
        sidebarWidth = dragStartWidth + event.locationInWindow.x - dragStartX
    }

    override public func accessibilityPerformIncrement() -> Bool { sidebarWidth += 1; return true }
    override public func accessibilityPerformDecrement() -> Bool { sidebarWidth -= 1; return true }
}
