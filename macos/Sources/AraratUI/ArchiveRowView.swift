import AppKit
import AraratKit

@MainActor
final class ArchiveRowView: NSView {
    private(set) var entry: ArchiveEntry
    var pointerLocation: (() -> NSPoint?)?
    private(set) var hovered = false
    private var focused = false
    var moveFocus: ((ArchiveRowView, Int) -> Void)?
    private let icon = NSImageView(image: SidebarRowView.symbol(for: .tab))
    private let title = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private let restore: (String) -> Void
    private let delete: (String) -> Void
    private let deleteButton = ArchiveActionButton()
    private let restoreButton = ArchiveActionButton()

    init(entry: ArchiveEntry, restore: @escaping (String) -> Void, delete: @escaping (String) -> Void) {
        self.entry = entry
        self.restore = restore
        self.delete = delete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = SidebarMetrics.archiveRowRadius
        layer?.cornerCurve = .continuous
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshHover), name: NSView.frameDidChangeNotification, object: self)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleNone
        icon.setAccessibilityHidden(true)
        title.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize)
        address.font = .systemFont(ofSize: SidebarMetrics.archiveURLSize)
        address.textColor = .secondaryLabelColor
        for text in [title, address] {
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for (button, symbol, label, action) in [
            (deleteButton, "trash", "Delete archived tab \(entry.title)", #selector(deleteEntry)),
            (restoreButton, "arrow.uturn.backward", "Restore \(entry.title)", #selector(restoreEntry)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.archiveIconSize, weight: .regular))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
            button.focusChanged = { [weak self] in self?.refreshActions() }
            button.navigate = { [weak self] event in self?.navigate(with: event) ?? false }
        }
        deleteButton.toolTip = "Delete Permanently"
        restoreButton.toolTip = "Restore Tab"
        restoreButton.identifier = NSUserInterfaceItemIdentifier(entry.id)
        for view in [icon, title, address, deleteButton, restoreButton] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(entry.title), \(Self.displayURL(entry.url))")
        toolTip = entry.url
        nextKeyView = deleteButton
        deleteButton.nextKeyView = restoreButton
        update(entry: entry)
        refreshActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func displayURL(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host else { return value }
        return host + url.path
    }

    override var isFlipped: Bool { true }
    func update(entry: ArchiveEntry) {
        guard self.entry != entry || title.stringValue.isEmpty else { return }
        self.entry = entry
        needsLayout = true
        title.stringValue = entry.title
        address.stringValue = Self.displayURL(entry.url)
        deleteButton.setAccessibilityLabel("Delete archived tab \(entry.title)")
        restoreButton.setAccessibilityLabel("Restore \(entry.title)")
        setAccessibilityLabel("\(entry.title), \(Self.displayURL(entry.url))")
        toolTip = entry.url
    }
    override func layout() {
        super.layout()
        let inset = SidebarMetrics.archiveRowInset
        let size = SidebarMetrics.archiveActionSize
        let gap = SidebarMetrics.archiveRowGap
        icon.frame = NSRect(x: inset, y: (bounds.height - SidebarMetrics.archiveIconSize) / 2, width: SidebarMetrics.archiveIconSize, height: SidebarMetrics.archiveIconSize)
        restoreButton.frame = NSRect(x: bounds.width - inset - size, y: (bounds.height - size) / 2, width: size, height: size)
        deleteButton.frame = restoreButton.frame.offsetBy(dx: -size - gap, dy: 0)
        let x = icon.frame.maxX + inset
        let width = max(0, deleteButton.frame.minX - inset - x)
        let titleHeight = title.intrinsicContentSize.height
        let addressHeight = address.intrinsicContentSize.height
        let y = (bounds.height - titleHeight - gap - addressHeight) / 2
        title.frame = NSRect(x: x, y: y, width: width, height: titleHeight)
        address.frame = NSRect(x: x, y: title.frame.maxY + gap, width: width, height: addressHeight)
        refreshHover()
    }
    private func navigate(with event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: moveFocus?(self, 1)
        case 126: moveFocus?(self, -1)
        case 123, 124:
            let targets: [NSView] = [self, deleteButton, restoreButton]
            let index = targets.firstIndex { $0 === window?.firstResponder } ?? 0
            window?.makeFirstResponder(targets[min(2, max(0, index + (event.keyCode == 124 ? 1 : -1)))])
        default: return false
        }
        return true
    }
    func chainNext(to view: NSView) { restoreButton.nextKeyView = view }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }
    override func becomeFirstResponder() -> Bool { focused = true; refreshActions(); noteFocusRingMaskChanged(); return true }
    override func resignFirstResponder() -> Bool { focused = false; refreshActions(); noteFocusRingMaskChanged(); return true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: SidebarMetrics.archiveRowRadius, yRadius: SidebarMetrics.archiveRowRadius).fill() }
    override func keyDown(with event: NSEvent) {
        if navigate(with: event) { return }
        if [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") { restoreEntry() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { restoreEntry(); return true }
    override func mouseUp(with event: NSEvent) { restoreEntry() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is ArchiveActionButton && hit.alphaValue > 0 ? hit : self
    }

    @objc private func restoreEntry() { restore(entry.id) }
    @objc private func deleteEntry() { delete(entry.id) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refreshHover()
    }
    @objc func refreshHover() {
        let point = pointerLocation.map { $0() } ?? (window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil)
        hovered = !isHiddenOrHasHiddenAncestor && (point.map { bounds.intersection(visibleRect).contains(convert($0, from: nil)) } ?? false)
        refreshActions()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshHover() }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshActions() }
    private func refreshActions() {
        let show = hovered || focused || deleteButton.focused || restoreButton.focused
        // Why not hide the buttons: Tab must reach them before pointer hover.
        for button in [deleteButton, restoreButton] { button.alphaValue = show ? 1 : 0 }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(show ? SidebarMetrics.archiveHoverAlpha : 0).cgColor
        }
    }
}

private final class ArchiveActionButton: NSButton {
    var focusChanged: (() -> Void)?
    var navigate: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if navigate?(event) == true { return }
        if [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    private(set) var focused = false
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override func becomeFirstResponder() -> Bool { focused = true; focusChanged?(); return true }
    override func resignFirstResponder() -> Bool { focused = false; focusChanged?(); return true }
}
