import AppKit
import AraratKit

@MainActor
final class SidebarRowView: NSView {
    private(set) var row: Row
    var acceptsKeyboardFocus = true { didSet { refreshHover() } }
    var menuProvider: (() -> NSMenu?)?
    var onRename: ((Row) -> Void)?
    var onRenameCommit: ((Row, String, @escaping (Bool) -> Void) -> Void)?
    var onRenameEnd: (() -> Void)?
    private(set) var renameField: SidebarRenameField?
    private let renameHint = NSTextField(labelWithString: "Double-click to rename")
    private let action: (Row) -> Void
    var onClose: ((String) -> Void)?
    let closeButton = NSButton()
    var closeShortcutAction: Selector? { selected ? #selector(SidebarView.closeSelectedTab(_:)) : nil }
    var pinned = false { didSet { updateCloseButton() } }
    var onDragPress: ((Row, NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragRelease: ((NSPoint) -> Bool)?
    var dragSource = false { didSet { updateFill() } }
    var dropHovered = false { didSet { updateFill() } }
    var dragCopy = false { didSet { updateCloseButton() } }
    private var trackingPress = false
    private(set) var pressed = false { didSet { updateFill() } }
    private let titleMask = CAGradientLayer()
    private var selected: Bool
    private let fill = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var fillLeading: NSLayoutConstraint!
    private var titleCenterY: NSLayoutConstraint!
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
        titleCenterY = title.centerYAnchor.constraint(equalTo: centerYAnchor)
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
            titleCenterY,
        ])
        renameHint.font = .systemFont(ofSize: 10)
        renameHint.textColor = .secondaryLabelColor
        renameHint.isHidden = true
        addSubview(renameHint)
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
        icon.image = row.kind == .folder ? Self.folderSymbol(collapsed: row.collapsed) : Self.symbol(for: row.kind)
        renameHint.isHidden = !(pinned && selected && row.kind == .tab)
        titleCenterY.constant = renameHint.isHidden ? 0 : 6
        title.maximumNumberOfLines = renameHint.isHidden ? 2 : 1
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
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
        if event.clickCount == 2 && pinned && row.kind == .tab { onRename?(row); return }
        trackingPress = true
        pressed = true
        onDragPress?(row, event.locationInWindow)
    }
    override func mouseDragged(with event: NSEvent) {
        onDragMove?(event.locationInWindow)
        pressed = trackingPress && bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let activate = acceptsKeyboardFocus && trackingPress && bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
        trackingPress = false
        pressed = false
        let handled = onDragRelease?(event.locationInWindow) ?? false
        if activate && !handled { action(row) }
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
        var rowActions = actions
        if row.kind == .folder && acceptsKeyboardFocus {
            rowActions.append(NSAccessibilityCustomAction(name: row.collapsed ? "Expand" : "Collapse") { [weak self] in
                guard let self, self.acceptsKeyboardFocus else { return false }; self.action(self.row); return true
            })
        }
        setAccessibilityCustomActions(rowActions)
        if closeButton.accessibilityLabel() != label { closeButton.toolTip = label }
        closeButton.setAccessibilityLabel(label)
        closeButton.isHidden = row.kind != .tab || (!dragCopy && (!acceptsKeyboardFocus || !hovered))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        renameField?.frame = NSRect(x: title.frame.minX, y: bounds.midY - 11, width: max(1, bounds.width - title.frame.minX - 8), height: 22)
        renameHint.frame = NSRect(x: title.frame.minX, y: bounds.midY - 16, width: max(1, bounds.width - title.frame.minX - 8), height: 12)
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
        let alpha: CGFloat = dragSource || dragCopy || pressed || selected ? 0.22 : hovered || dropHovered ? 0.12 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { acceptsKeyboardFocus ? menuProvider?() : nil }

    func beginRename() {
        guard renameField == nil else { return }
        let field = SidebarRenameField(title: row.title, save: { [weak self] title, done in
            guard let self, let save = self.onRenameCommit else { done(false); return }
            save(self.row, title, done)
        }, ended: { [weak self] in self?.renameField = nil; self?.onRenameEnd?() })
        renameField = field
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func finishRename(commit: Bool) { renameField?.finish(commit: commit) }

    static func folderSymbol(collapsed: Bool) -> NSImage {
        if collapsed { return symbol(for: .folder) }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.labelColor.setFill()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 1, y: 3))
            back.line(to: NSPoint(x: 1, y: 13))
            back.line(to: NSPoint(x: 6, y: 13))
            back.line(to: NSPoint(x: 8, y: 11))
            back.line(to: NSPoint(x: 14, y: 11))
            back.line(to: NSPoint(x: 14, y: 9))
            back.line(to: NSPoint(x: 4, y: 9))
            back.close(); back.fill()
            let front = NSBezierPath()
            front.move(to: NSPoint(x: 1, y: 3))
            front.line(to: NSPoint(x: 4, y: 8))
            front.line(to: NSPoint(x: 16, y: 8))
            front.line(to: NSPoint(x: 13, y: 3))
            front.close(); front.fill()
            return true
        }
        image.isTemplate = true
        return image
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
    var onDragPress: ((Row, NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragRelease: ((NSPoint) -> Bool)?
    var menuProvider: (() -> NSMenu?)?
    var onRenameEnd: (() -> Void)?
    private(set) var renameField: SidebarRenameField?
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

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
        guard let onDragPress else { super.mouseDown(with: event); return }
        onDragPress(row, event.locationInWindow)
    }
    override func mouseDragged(with event: NSEvent) { onDragMove?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) {
        if onDragRelease?(event.locationInWindow) != true && bounds.contains(convert(event.locationInWindow, from: nil)) { onPress(row) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    func beginRename(save: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        guard renameField == nil else { return }
        let field = SidebarRenameField(title: row.title, save: save, ended: { [weak self] in
            self?.renameField = nil; self?.onRenameEnd?()
        })
        renameField = field
        addSubview(field)
        field.frame = bounds.insetBy(dx: 2, dy: 10)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let renameField, renameField.frame.contains(convert(point, from: superview)) { return renameField }
        return super.hitTest(point) == nil ? nil : self
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
