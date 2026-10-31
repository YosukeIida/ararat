import AppKit
import AraratKit

@MainActor
final class SidebarRowView: NSView {
    private(set) var row: Row
    var acceptsKeyboardFocus = true
    private let action: (Row) -> Void
    private var selected: Bool
    private let fill = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var fillLeading: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var hovered = false { didSet { updateFill() } }

    init(row: Row, selected: Bool, action: @escaping (Row) -> Void) {
        self.row = row
        self.action = action
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 11
        fill.layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14)
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
        title.toolTip = row.url
        icon.image = Self.symbol(for: row.kind)
        fillLeading.constant = CGFloat(row.depth) * 16
        iconLeading.constant = 10 + CGFloat(row.depth) * 16
        setAccessibilityLabel(title.stringValue)
        updateFill()
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
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if acceptsKeyboardFocus { action(row) } }
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
        let alpha: CGFloat = selected ? 0.22 : hovered ? 0.12 : 0
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
        image = SidebarRowView.symbol(for: row.kind)
        toolTip = row.title
        setAccessibilityLabel(row.title)
    }

    @objc private func pressed() { onPress(row) }

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
