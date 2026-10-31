import AppKit
import AraratKit

@MainActor
final class SidebarRowView: NSView {
    private let action: () -> Void
    private let selected: Bool
    private let fill = NSView()
    private var hovered = false { didSet { updateFill() } }

    init(row: Row, selected: Bool, action: @escaping () -> Void) {
        self.action = action
        self.selected = selected
        super.init(frame: .zero)
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 11
        fill.layer?.cornerCurve = .continuous

        let icon = NSImageView(image: Self.symbol(for: row.kind))
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        let displayTitle = row.kind == .split && row.title.isEmpty ? "Split" : row.title
        let title = NSTextField(labelWithString: displayTitle)
        title.font = .systemFont(ofSize: 14)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = row.url
        for view in [fill, icon, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let indent = CGFloat(row.depth) * 16
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 41),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.centerYAnchor.constraint(equalTo: centerYAnchor),
            fill.heightAnchor.constraint(equalToConstant: 36),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 + indent),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(displayTitle)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
    override func mouseUp(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }
    override func resignFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }
    override var focusRingMaskBounds: NSRect { fill.frame }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: fill.frame, xRadius: 11, yRadius: 11).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": action()
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
    private let onPress: () -> Void
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    init(row: Row, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        image = SidebarRowView.symbol(for: row.kind)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = row.title
        setAccessibilityLabel(row.title)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        updateFill()
        heightAnchor.constraint(equalToConstant: 47).isActive = true
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func pressed() { onPress() }

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
