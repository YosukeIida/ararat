import AppKit

/// D3: the URL field's own surface and the two 24 pt buttons inside it, with the board's radius
/// 6 and its hover, pressed, focus and copied states. Fills are starting values tuned on the
/// real app; sizes and the 4 pt step are ours (the board's 6/2 were not Arc measurements).
@MainActor
public final class URLFieldBackgroundButton: NSButton {
    /// The board's hover and pressed fills on the tinted field. The alpha is the tint's, so both
    /// appearances gain contrast instead of the light-only white overlay the board draws.
    public var isHovered = false { didSet { updateBackground() } }
    public var isPressed = false { didSet { updateBackground() } }
    public var showsFocusRing = false { didSet { updateFocusRing() } }
    private let focusLayer = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        focusLayer.borderWidth = 3
        focusLayer.cornerRadius = 14
        focusLayer.cornerCurve = .continuous
        focusLayer.isHidden = true
        layer?.addSublayer(focusLayer)
        updateBackground()
    }

    public convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { showsFocusRing = true }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { showsFocusRing = false }
        return accepted
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusLayer.frame = bounds.insetBy(dx: -3, dy: -3)
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let alpha: CGFloat = isPressed ? 0.18 : isHovered ? 0.12 : 0.08
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            focusLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        }
    }

    private func updateFocusRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusLayer.isHidden = !showsFocusRing
        CATransaction.commit()
    }
}

/// One of the field's two 24 pt buttons: Copy Link and the site controls.@MainActor
public class URLFieldButton: NSButton {
    public enum Role { case copyLink, siteControls }

    public let role: Role
    public var isHovered = false { didSet { updateBackground() } }
    public var isPressed = false { didSet { updateBackground() } }
    public var showsFocusRing = false { didSet { updateFocusRing() } }
    /// The copied tick keeps Copy Link's board state; the sidebar clears it after the toast's 2 s.
    public var showsCopied = false { didSet { updateImage() } }
    private let focusLayer = CALayer()

    public init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        focusLayer.borderWidth = 3
        focusLayer.cornerRadius = 9
        focusLayer.cornerCurve = .continuous
        focusLayer.isHidden = true
        layer?.addSublayer(focusLayer)
        updateImage()
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // An unbordered image-only button carries negative alignment insets for its focus ring, so a
    // required 24 pt height would render a 33 pt frame. The board's 24 x 24 is the frame.
    public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { showsFocusRing = true }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { showsFocusRing = false }
        return accepted
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusLayer.frame = bounds.insetBy(dx: -3, dy: -3)
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private var currentSymbol = ""

    private func updateImage() {
        if role == .copyLink, showsCopied {
            currentSymbol = "checkmark"
            image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            contentTintColor = .systemGreen
        } else {
            currentSymbol = role == .copyLink ? "doc.on.doc" : "slider.horizontal.3"
            image = NSImage(systemSymbolName: currentSymbol, accessibilityDescription: nil)
            contentTintColor = .labelColor
        }
    }

    private func updateBackground() {
        let alpha: CGFloat = isPressed ? 0.14 : isHovered ? 0.07 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = alpha == 0 ? nil : NSColor.labelColor.withAlphaComponent(alpha).cgColor
            focusLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        }
    }

    private func updateFocusRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusLayer.isHidden = !showsFocusRing
        CATransaction.commit()
    }

    /// Check seam: the fill the current state asks for, without reading a rendered layer.
    public var checkBackgroundAlpha: CGFloat { isPressed ? 0.14 : isHovered ? 0.07 : 0 }
    public func checkImageIsTick() -> Bool { showsCopied && currentSymbol == "checkmark" }
}

/// An image view with no alignment insets, so a required 16 pt frame is the frame the board
/// measures (a symbol image's default insets make it taller).
@MainActor
public final class URLFieldGlyphView: NSImageView {
    public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
