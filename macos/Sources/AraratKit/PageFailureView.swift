import AppKit

private final class FailurePrimaryButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

public final class PageFailureView: NSView {
    private static let sadWindow: NSImage = {
        let image = NSImage(size: NSSize(width: 44, height: 44), flipped: false) { _ in
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: NSRect(x: 5, y: 8, width: 34, height: 28), xRadius: 5, yRadius: 5)
            outline.move(to: NSPoint(x: 5, y: 28))
            outline.line(to: NSPoint(x: 39, y: 28))
            outline.move(to: NSPoint(x: 17, y: 13))
            outline.curve(to: NSPoint(x: 27, y: 13), controlPoint1: NSPoint(x: 20, y: 17), controlPoint2: NSPoint(x: 24, y: 17))
            outline.lineWidth = 2.5
            outline.lineCapStyle = .round
            outline.stroke()
            for x: CGFloat in [16, 25] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 19, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    private let image = NSImageView()
    private let heading = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let primary = FailurePrimaryButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    public var onReload: (() -> Void)?
    public var onClose: (() -> Void)?
    public var accent = SpaceAccent.teal {
        didSet {
            guard oldValue != accent else { return }
            primary.bezelColor = accent
            setPrimaryTitle(primary.title)
        }
    }
    private weak var coveredPage: NSView?
    private var isCovering = false
    private var isFocusedPane = false
    private var pageWasHiddenFromAccessibility = false
    private var pageWasAccessibilityElement = false
    private var restorePageFocus: (() -> Void)?
    private var wasFocusedWhenDetached = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .light)
        image.contentTintColor = .secondaryLabelColor
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.alignment = .center
        heading.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.textColor = .tertiaryLabelColor
        primary.bezelStyle = .rounded
        primary.bezelColor = accent
        primary.target = self
        primary.action = #selector(reload)
        primary.keyEquivalent = "\r"
        secondary.bezelStyle = .rounded
        secondary.target = self
        secondary.action = #selector(close)
        let buttons = NSStackView(views: [primary, secondary])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let content = NSStackView(views: [image, heading, message, buttons, code])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            wasFocusedWhenDetached = (window?.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public func cover(_ page: NSView?, focus: Bool, restoreFocus: @escaping () -> Void) {
        let newlyFocused = focus && !isFocusedPane
        let restoreDetachedFocus = focus && wasFocusedWhenDetached
        isFocusedPane = focus
        primary.keyEquivalent = focus ? "\r" : ""
        if !isCovering || coveredPage !== page {
            uncover(restoreFocus: false)
            isCovering = true
            isFocusedPane = focus
            primary.keyEquivalent = focus ? "\r" : ""
            coveredPage = page
            if let page {
                pageWasHiddenFromAccessibility = page.isAccessibilityHidden()
                pageWasAccessibilityElement = page.isAccessibilityElement()
                page.setAccessibilityElement(true)
                page.setAccessibilityHidden(true)
            }
            self.restorePageFocus = restoreFocus
            if focus { window?.makeFirstResponder(primary) }
        } else if newlyFocused || restoreDetachedFocus {
            window?.makeFirstResponder(primary)
        }
        if window != nil { wasFocusedWhenDetached = false }
    }

    public func uncover(restoreFocus: Bool) {
        let focused = wasFocusedWhenDetached || ((window?.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false)
        coveredPage?.setAccessibilityHidden(pageWasHiddenFromAccessibility)
        coveredPage?.setAccessibilityElement(pageWasAccessibilityElement)
        coveredPage = nil
        isCovering = false
        isFocusedPane = false
        wasFocusedWhenDetached = false
        if restoreFocus && focused { restorePageFocus?() }
        restorePageFocus = nil
    }

    public func update(crashed: Bool, error: Int, host: String, archive: Bool) {
        let host = host.isEmpty ? "this page" : host
        image.image = crashed ? Self.sadWindow : NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
        heading.stringValue = crashed ? "This page crashed" : (error == -106 ? "You’re offline" : "This site can’t be reached")
        message.stringValue = crashed
            ? "Something went wrong while showing \(host). Reloading usually brings it back."
            : "Ararat can’t reach \(host). Check your network connection and try again."
        setPrimaryTitle(crashed ? "Reload" : "Try Again")
        secondary.title = archive ? "Archive Tab" : "Close Tab"
        secondary.isHidden = !crashed
        code.stringValue = error == -106 ? "ERR_INTERNET_DISCONNECTED" : (error == -137 ? "ERR_NAME_RESOLUTION_FAILED" : "ERR_NAME_NOT_RESOLVED")
        code.isHidden = crashed
    }

    private func setPrimaryTitle(_ title: String) {
        // contentTintColor only applies to borderless buttons.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        primary.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: SpaceAccent.foreground(on: accent),
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraph,
        ])
    }

    @objc private func reload() { onReload?() }
    @objc private func close() { onClose?() }

    public var checkState: [String: Any] {
        ["heading": heading.stringValue, "primary": primary.title,
         "secondary": secondary.isHidden ? "" : secondary.title, "code": code.isHidden ? "" : code.stringValue]
    }

    func checkPress(secondary: Bool, screen: Bool) -> Bool {
        let button = secondary ? self.secondary : primary
        guard !button.isHidden else { return false }
        if !screen { button.performClick(nil); return true }
        guard let window, window.isKeyWindow else { return false }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }
}
