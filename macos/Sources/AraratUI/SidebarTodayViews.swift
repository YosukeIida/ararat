import AppKit
import AraratKit

// T1: the divider block that opens Today. A 1 pt line 8 pt down in a 16 pt block, from x 18,
// ending 80 pt from the edge, with the Clear button (24 pt, 16 pt from the edge) sitting on
// the line. It exists only while Today has tabs.
@MainActor
final class SidebarTodayDivider: NSView {
    private let line = NSView()
    private let clearButton = SidebarClearButton()
    var onClear: (() -> Void)? { didSet { clearButton.onPress = onClear } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SidebarMetrics.todayDividerHeight),
            line.topAnchor.constraint(equalTo: topAnchor, constant: SidebarMetrics.todayDividerLineDrop),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.todayDividerLeading),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.todayDividerTrailing),
            line.heightAnchor.constraint(equalToConstant: 1),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.todayClearTrailing),
            clearButton.centerYAnchor.constraint(equalTo: topAnchor, constant: SidebarMetrics.todayDividerLineDrop + 0.5),
            clearButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.todayClearSize),
        ])
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    var checkFrames: [String: NSRect] {
        ["line": convert(line.bounds, from: line), "clear": convert(clearButton.bounds, from: clearButton)]
    }
}

@MainActor
final class SidebarClearButton: NSButton {
    static let labelFontSize: CGFloat = 11

    private let fill = NSView()
    private var hovered = false { didSet { updateFill() } }
    private(set) var pressed = false { didSet { updateFill() } }
    var onPress: (() -> Void)?
    private(set) var checkPressCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = "Clear"
        font = .systemFont(ofSize: Self.labelFontSize, weight: .medium)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(press)
        wantsLayer = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 6
        fill.layer?.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: SidebarMetrics.todayClearSize),
        ])
        setAccessibilityLabel("Clear Today")
        toolTip = "Clear Today"
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refreshHover()
    }

    @objc private func refreshHover() {
        let point = window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil
        let inside = point.map { bounds.contains(convert($0, from: nil)) } ?? false
        if hovered != inside { hovered = inside }
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)
        pressed = false
    }

    @objc private func press() {
        checkPressCount += 1
        onPress?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let alpha: CGFloat = pressed ? 0.22 : hovered ? 0.12 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}

// T4: the New Tab row, the first row under the divider, scrolling with Today. Hidden when the
// core's settings record says so, and the rows below close up by its height.
@MainActor
final class SidebarNewTabRow: NSView {
    var onPress: (() -> Void)?
    private let fill = NSView()
    private var hovered = false { didSet { updateFill() } }
    private(set) var pressed = false { didSet { updateFill() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 11
        fill.layer?.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill, positioned: .below, relativeTo: nil)
        let icon = NSImageView()
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        let label = NSTextField(labelWithString: "New Tab")
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SidebarMetrics.newTabRowHeight),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.centerYAnchor.constraint(equalTo: centerYAnchor),
            fill.heightAnchor.constraint(equalToConstant: 36),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
        toolTip = "New Tab"
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refreshHover()
    }

    @objc private func refreshHover() {
        let point = window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil
        let inside = point.map { bounds.contains(convert($0, from: nil)) } ?? false
        if hovered != inside { hovered = inside }
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    private var trackingPress = false
    override func mouseDown(with event: NSEvent) {
        trackingPress = true
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = trackingPress && bounds.contains(convert(event.locationInWindow, from: nil))
        trackingPress = false
        pressed = false
        if inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Space, Return and keypad Enter act it from the keyboard, and it draws the standard
    // focus ring.
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": onPress?()
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return true
    }

    override func resignFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }

    override var focusRingMaskBounds: NSRect { fill.frame }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: fill.frame, xRadius: 11, yRadius: 11).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let alpha: CGFloat = pressed ? 0.22 : hovered ? 0.12 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}
