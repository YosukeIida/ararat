import AppKit
import AraratKit

/// D3: the URL field's own surface and the two 24 pt buttons inside it, with the board's radius
/// 6 and its hover, pressed, focus and copied states. Fills are starting values tuned on the
/// real app; sizes and the 4 pt step are ours (the board's 6/2 were not Arc measurements).
@MainActor
public final class URLFieldBackgroundButton: NSButton {
    static let focusRingAlpha: CGFloat = 0.55
    /// The board's field fills. The resting fill is the sidebar boards' `--fill`: white 55 % on the
    /// tinted sidebar, 10 % in dark (`mock-decisions.md` 2026-11-11; the F boards' URL field). Hover
    /// and pressed are the C-UrlField board's `--fieldH` and `--fieldP`: the field lightens under
    /// the pointer and darkens a little while pressed, in white for both appearances, so the field
    /// lightens the tinted sidebar instead of darkening it in light.
    public static func fillAlpha(pressed: Bool, hovered: Bool, appearance: NSAppearance) -> CGFloat {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if pressed { return dark ? 0.06 : 0.40 }
        if hovered { return dark ? 0.14 : 0.82 }
        return dark ? 0.10 : 0.55
    }
    /// The fill last drawn, for the checks.
    public var checkFill: NSColor? { layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } }
    /// Re-runs the fill under a forced appearance, for the checks.
    public func checkSetAppearance(_ name: NSAppearance.Name) {
        appearance = NSAppearance(named: name)
        updateBackground()
    }
    public var isHovered = false { didSet { updateBackground() } }
    public var isPressed = false { didSet { updateBackground() } }
    public var showsFocusRing = false { didSet { updateFocusRing() } }
    private let focusLayer = CALayer()
    var accent = SpaceAccent.teal { didSet { updateBackground() } }

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
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let alpha = Self.fillAlpha(pressed: isPressed, hovered: isHovered, appearance: appearance)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
            focusLayer.borderColor = accent.withAlphaComponent(Self.focusRingAlpha).cgColor
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
    var accent = SpaceAccent.teal { didSet { updateBackground() } }

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

    // S3: a click on Copy Link or the site controls must not take focus from the page. With Full
    // Keyboard Access on, a keyboard user must still reach both, so focus follows that setting;
    // the board's focus look is drawn from `showsFocusRing`. A mouse down refuses focus because
    // AppKit can make the hit view first responder before `mouseDown` runs (the order this rule
    // pins); Tab arrives as a key event, so the keyboard path is unaffected.
    /// The session's Full Keyboard Access answer. A unit test replaces it: the real one,
    /// `NSApp.isFullKeyboardAccessEnabled`, is read-only and belongs to the machine.
    public static var fullKeyboardAccess: () -> Bool = { NSApp?.isFullKeyboardAccessEnabled ?? false }

    public override var acceptsFirstResponder: Bool {
        Self.keyboardFocusAllowed(fullKeyboardAccess: Self.fullKeyboardAccess(), isEnabled: isEnabled,
                                  refusesFirstResponder: refusesFirstResponder,
                                  currentEvent: NSApp.currentEvent?.type)
    }

    /// S3's rule. Full Keyboard Access lets the two buttons take the keyboard's focus; a mouse down
    /// never does, because AppKit can make the hit view first responder before `mouseDown` runs.
    /// A disabled button, and the scroll-preview copies that refuse the responder, are not stops.
    static func keyboardFocusAllowed(fullKeyboardAccess: Bool, isEnabled: Bool,
                                     refusesFirstResponder: Bool, currentEvent: NSEvent.EventType?) -> Bool {
        fullKeyboardAccess && isEnabled && !refusesFirstResponder && currentEvent != .leftMouseDown
    }

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
            focusLayer.borderColor = accent.withAlphaComponent(URLFieldBackgroundButton.focusRingAlpha).cgColor
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

/// The field's text area. A host wider than the area keeps its full drawing width and is anchored
/// at the trailing edge with a 16 pt leading fade. A long file name or internal URL keeps its start
/// and is truncated at the tail (D6).
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
        // The field's intrinsic width omits the cell's horizontal drawing padding.
        let cellWidth = visible.cell?.cellSize.width ?? intrinsic.width
        let fades = fadesStart && cellWidth > bounds.width
        let fullWidth = fadesStart ? ceil(cellWidth) : intrinsic.width
        let width = fades ? fullWidth : min(fullWidth, bounds.width)
        let x = fades ? bounds.width - fullWidth : 0
        let frame = NSRect(x: x, y: (Self.height - height) / 2, width: width, height: height)
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
    /// The visible label's intrinsic width, so a layout test can tell a clamped frame from one
    /// that keeps the label's width (the placeholder's tail truncation needs the former).
    public var checkLabelIntrinsicWidth: CGFloat { (placeholder.isHidden ? host : placeholder).intrinsicContentSize.width }
    public var checkHasFade: Bool { layer?.mask != nil }
}
