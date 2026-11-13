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

/// One of the field's two 24 pt buttons: Copy Link and the site controls.
@MainActor
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

    // S3: a click on Copy Link or the site controls must not take focus from the page. The
    // board's focus look is still drawn from `showsFocusRing`.
    public override var acceptsFirstResponder: Bool { false }

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

/// The field's text area. The label keeps its intrinsic width; a host wider than the area is
/// anchored at the trailing edge (its start off the leading edge, under a 16 pt gradient) so the
/// registrable domain stays visible. A long file name or internal URL keeps its start and is
/// clipped at the tail (D6).
@MainActor
public final class URLFieldTextClipView: NSView {
    /// The text area's height; the field's constraint uses it, so the labels centre on a value
    /// that does not depend on a layout pass having seen the final frame.
    public static let height: CGFloat = 24
    public let host: NSTextField
    public let placeholder: NSTextField
    /// Set for the `.host` kind only.
    public var fadesStart = false { didSet { needsLayout = true } }
    private let fadeLayer = CAGradientLayer()
    private let fadeLength: CGFloat = 16

    public init(host: NSTextField, placeholder: NSTextField) {
        self.host = host
        self.placeholder = placeholder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(host)
        addSubview(placeholder)
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fadeLayer.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()
        let showsPlaceholder = !placeholder.isHidden
        let visible = showsPlaceholder ? placeholder : host
        let hidden = showsPlaceholder ? host : placeholder
        guard !visible.isHidden else {
            host.frame = .zero
            placeholder.frame = .zero
            layer?.mask = nil
            return
        }
        let intrinsic = visible.intrinsicContentSize
        let height = min(Self.height, intrinsic.height)
        let fades = fadesStart && intrinsic.width > bounds.width + 0.5
        let x = fades ? bounds.width - intrinsic.width : 0
        let frame = NSRect(x: x, y: (Self.height - height) / 2, width: intrinsic.width, height: height)
        visible.frame = frame
        // The hidden label keeps the visible label's frame, so an incremental update and a fresh
        // view describe the same tree (the hidden label is not drawn either way).
        hidden.frame = frame
        guard fades, bounds.width > 0 else { layer?.mask = nil; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeLayer.frame = bounds
        fadeLayer.locations = [0, NSNumber(value: Double(min(fadeLength, bounds.width) / bounds.width))]
        layer?.mask = fadeLayer
        CATransaction.commit()
    }

    public var checkLabelFrame: NSRect { (placeholder.isHidden ? host : placeholder).frame }
    public var checkHasFade: Bool { layer?.mask != nil }
}
