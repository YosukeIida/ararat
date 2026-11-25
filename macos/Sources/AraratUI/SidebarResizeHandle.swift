import AppKit

@MainActor
public final class SidebarResizeHandle: NSView {
    private let widthConstraint: NSLayoutConstraint
    private var userWidth: CGFloat
    /// The Library's width while it is open; nil while it is closed. The sidebar area takes this
    /// width instead of the user's, and the user's stored width is left alone.
    var libraryWidth: CGFloat? { didSet { applyWidth() } }
    /// The most the area may take in the current window. The container answers it so the page
    /// keeps its minimum width and the list takes the rest.
    var widthLimit: () -> CGFloat? = { nil }
    var displayedWidth: CGFloat {
        guard let libraryWidth else { return userWidth }
        return min(libraryWidth, widthLimit() ?? .infinity)
    }
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
        // The Library takes the cursor away with the drag; the handle itself has not moved.
        window?.invalidateCursorRects(for: self)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Re-reads the limit after the window resized, so a narrow window's list clamps and a wider
    /// one gives the Library its width back. The sidebar lays itself out again; the container's
    /// panel and page frames already read `displayedWidth`.
    func applyWidthLimit() {
        guard libraryWidth != nil else { return }
        let width = displayedWidth
        guard widthConstraint.constant != width else { return }
        widthConstraint.constant = width
        needsLayout = true
    }

    public func resetWidth() { sidebarWidth = SidebarMetrics.defaultWidth }

    override public func resetCursorRects() {
        // The Library sets its own width, so there is nothing here to drag while it is open.
        guard libraryWidth == nil else { return }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override public func mouseDown(with event: NSEvent) {
        collapsedDuringDrag = false
        dragStartX = event.locationInWindow.x
        dragStartWidth = sidebarWidth
    }

    override public func mouseDragged(with event: NSEvent) {
        // Why not resize the Library: its width is Arc's, not the user's, so a drag here would
        // only write a width nothing shows and the close would jump to it. The drag still
        // collapses the sidebar as before.
        guard libraryWidth == nil else {
            collapsedDuringDrag = onDrag?(event.locationInWindow.x) == true
            return
        }
        guard !collapsedDuringDrag else { return }
        if onDrag?(event.locationInWindow.x) == true { collapsedDuringDrag = true; return }
        sidebarWidth = dragStartWidth + event.locationInWindow.x - dragStartX
    }

    override public func accessibilityPerformIncrement() -> Bool {
        guard libraryWidth == nil else { return false }
        sidebarWidth += 1
        return true
    }
    override public func accessibilityPerformDecrement() -> Bool {
        guard libraryWidth == nil else { return false }
        sidebarWidth -= 1
        return true
    }
}
