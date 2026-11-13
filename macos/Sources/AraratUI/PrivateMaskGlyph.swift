import AppKit

/// The mock's masquerade (eye) mask, from D-PrivateWindowEmpty.dc.html: a 16-unit path drawn
/// with stroke 1.5 at 16 pt and 1.1 at 44 pt (user units in the 16-unit viewBox, so the 44 pt
/// glyph's stroke scales to 3 pt). Template, so it follows the label colour.
@MainActor
public enum PrivateMaskGlyph {
    public static func image(size: CGFloat) -> NSImage {
        let stroke: CGFloat = size <= 16 ? 1.5 : 1.1
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let scale = size / 16
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
            let path = NSBezierPath()
            path.lineWidth = stroke * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // M1.6 5.2c2-.9 4.2-.9 6.4.4 2.2-1.3 4.4-1.3 6.4-.4.3 3.6-1 6-3.3 6
            // -1.4 0-2.1-1.2-3.1-1.2S6.3 11.2 4.9 11.2c-2.3 0-3.6-2.4-3.3-6z
            path.move(to: point(1.6, 5.2))
            path.curve(to: point(8.0, 5.6), controlPoint1: point(3.6, 4.3), controlPoint2: point(5.8, 4.3))
            path.curve(to: point(14.4, 5.2), controlPoint1: point(10.2, 4.3), controlPoint2: point(12.4, 4.3))
            path.curve(to: point(11.1, 11.2), controlPoint1: point(14.7, 8.8), controlPoint2: point(13.4, 11.2))
            path.curve(to: point(8.0, 10.0), controlPoint1: point(9.7, 11.2), controlPoint2: point(9.0, 10.0))
            path.curve(to: point(4.9, 11.2), controlPoint1: point(7.0, 10.0), controlPoint2: point(6.3, 11.2))
            path.curve(to: point(1.6, 5.2), controlPoint1: point(2.6, 11.2), controlPoint2: point(1.3, 8.8))
            path.close()
            // M4 7.6c.8-.5 1.6-.5 2.4 0  M9.6 7.6c.8-.5 1.6-.5 2.4 0
            path.move(to: point(4.0, 7.6))
            path.curve(to: point(6.4, 7.6), controlPoint1: point(4.8, 7.1), controlPoint2: point(5.6, 7.1))
            path.move(to: point(9.6, 7.6))
            path.curve(to: point(12.0, 7.6), controlPoint1: point(10.4, 7.1), controlPoint2: point(11.2, 7.1))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Private"
        return image
    }
}

/// The empty private window's page (D-PrivateWindowEmpty): the 44 pt mask above its text.
@MainActor
public final class PrivateEmptyView: NSView {
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "Private Browsing")
    private let subtitle = NSTextField(wrappingLabelWithString: "Pages you open in this window are not saved to your history or workspace.")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyph.image = PrivateMaskGlyph.image(size: 44)
        glyph.contentTintColor = .secondaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.maximumNumberOfLines = 2
        let stack = NSStackView(views: [glyph, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            glyph.widthAnchor.constraint(equalToConstant: 44),
            glyph.heightAnchor.constraint(equalToConstant: 44),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("Private Browsing")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
