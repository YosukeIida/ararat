import AppKit
import AraratKit

@MainActor
final class SidebarRowView: NSView {
    private(set) var row: Row
    var acceptsKeyboardFocus = true { didSet { refreshHover() } }
    private let action: (Row) -> Void
    var onClose: ((String) -> Void)?
    let closeButton = NSButton()
    var pinned = false { didSet { updateCloseButton() } }
    private var trackingPress = false
    private(set) var pressed = false { didSet { updateFill() } }
    private let titleMask = CAGradientLayer()
    private var selected: Bool
    private let fill = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var fillLeading: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private(set) var hovered = false { didSet { updateFill(); updateCloseButton() } }
    var pointerLocation: (() -> NSPoint?)?

    init(row: Row, selected: Bool, action: @escaping (Row) -> Void) {
        self.row = row
        self.action = action
        self.selected = selected
        super.init(frame: .zero)
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshHover), name: NSView.frameDidChangeNotification, object: self)
        wantsLayer = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 11
        fill.layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        for view in [fill, icon, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        fillLeading = fill.leadingAnchor.constraint(equalTo: leadingAnchor)
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 41),
            fillLeading,
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.centerYAnchor.constraint(equalTo: centerYAnchor),
            fill.heightAnchor.constraint(equalToConstant: 36),
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        title.wantsLayer = true
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(row: row, selected: selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(row: Row, selected: Bool) {
        self.row = row
        self.selected = selected
        title.stringValue = row.kind == .split && row.title.isEmpty ? "Split" : row.title
        toolTip = row.url ?? row.title
        title.alphaValue = row.unloaded ? SidebarMetrics.unloadedOpacity : 1
        icon.alphaValue = row.unloaded ? SidebarMetrics.unloadedOpacity : 1
        icon.image = Self.symbol(for: row.kind)
        fillLeading.constant = CGFloat(row.depth) * 16
        iconLeading.constant = 10 + CGFloat(row.depth) * 16
        setAccessibilityLabel(title.stringValue)
        updateFill()
        updateCloseButton()
        noteFocusRingMaskChanged()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        refreshHover()
    }

    @objc func refreshHover() {
        let point: NSPoint?
        if let pointerLocation { point = pointerLocation() }
        else { point = window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil }
        let inside = point.map { bounds.intersection(visibleRect).contains(convert($0, from: nil)) } ?? false
        let updated = acceptsKeyboardFocus && !isHiddenOrHasHiddenAncestor && inside
        if hovered != updated { hovered = updated }
        let nextPressed = trackingPress && updated
        if pressed != nextPressed { pressed = nextPressed }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    override func mouseDown(with event: NSEvent) {
        guard acceptsKeyboardFocus else { return }
        trackingPress = true
        pressed = true
    }
    override func mouseDragged(with event: NSEvent) { refreshHover() }
    override func mouseUp(with event: NSEvent) {
        refreshHover()
        let activate = acceptsKeyboardFocus && pressed
        trackingPress = false
        pressed = false
        if activate { action(row) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 && acceptsKeyboardFocus && (row.kind == .tab || (row.kind == .split && !pinned)) { onClose?(row.id) }
    }

    @objc private func closePressed() { if acceptsKeyboardFocus { onClose?(row.id) } }

    private func updateCloseButton() {
        let unload = pinned && selected
        closeButton.image = NSImage(systemSymbolName: unload ? "minus" : "xmark", accessibilityDescription: nil)
        let label = unload ? "Close and Keep Pinned" : "Archive this tab"
        let actions: [NSAccessibilityCustomAction] = row.kind == .tab && acceptsKeyboardFocus ? [
            NSAccessibilityCustomAction(name: label) { [weak self] in
                guard let self, self.acceptsKeyboardFocus else { return false }
                self.onClose?(self.row.id)
                return true
            },
        ] : []
        setAccessibilityCustomActions(actions)
        if closeButton.accessibilityLabel() != label { closeButton.toolTip = label }
        closeButton.setAccessibilityLabel(label)
        closeButton.isHidden = !acceptsKeyboardFocus || row.kind != .tab || !hovered
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !closeButton.isHidden && closeButton.frame.minX < title.frame.maxX {
            titleMask.frame = title.bounds
            titleMask.startPoint = CGPoint(x: 0, y: 0.5)
            titleMask.endPoint = CGPoint(x: 1, y: 0.5)
            let end = max(0, min(1, (closeButton.frame.minX - title.frame.minX) / max(1, title.bounds.width)))
            titleMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            titleMask.locations = [0, NSNumber(value: Double(max(0, end - 12 / max(1, title.bounds.width)))), NSNumber(value: Double(end)), 1]
            title.layer?.mask = titleMask
        } else { title.layer?.mask = nil }
        CATransaction.commit()
    }
    override func accessibilityPerformPress() -> Bool {
        guard acceptsKeyboardFocus else { return false }
        action(row)
        return true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsKeyboardFocus ? super.hitTest(point) : nil
    }

    override var acceptsFirstResponder: Bool { acceptsKeyboardFocus }
    override var canBecomeKeyView: Bool { acceptsKeyboardFocus }
    override func becomeFirstResponder() -> Bool {
        guard acceptsKeyboardFocus else { return false }
        noteFocusRingMaskChanged()
        return true
    }
    override func resignFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }
    override var focusRingMaskBounds: NSRect { fill.frame }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: fill.frame, xRadius: 11, yRadius: 11).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": action(row)
        default: super.keyDown(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let alpha: CGFloat = pressed ? 0.22 : selected ? 0.22 : hovered ? 0.12 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }

    static func symbol(for kind: RowKind) -> NSImage {
        let name = switch kind {
        case .tab: "globe"
        case .folder: "folder.fill"
        case .split: "rectangle.split.2x1"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) ?? NSImage()
    }
}

@MainActor
final class FavoriteTile: NSButton {
    private(set) var row: Row
    private let onPress: (Row) -> Void
    private let icon = NSImageView()
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    init(row: Row, onPress: @escaping (Row) -> Void) {
        self.row = row
        self.onPress = onPress
        super.init(frame: .zero)
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .labelColor
        icon.setAccessibilityHidden(true)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateFill()
        heightAnchor.constraint(equalToConstant: 47).isActive = true
        target = self
        action = #selector(pressed)
        update(row: row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(row: Row) {
        self.row = row
        icon.image = SidebarRowView.symbol(for: row.kind)
        icon.alphaValue = row.unloaded ? SidebarMetrics.unloadedOpacity : 1
        toolTip = row.title
        setAccessibilityLabel(row.title)
    }

    @objc private func pressed() { onPress(row) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}
