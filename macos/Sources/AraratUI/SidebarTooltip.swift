import AppKit

@MainActor
final class SidebarTooltip {
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var menuTracking = false { didSet { dismiss() } }
    private let texts = NSMapTable<NSView, NSString>.weakToStrongObjects()
    private weak var target: NSView?
    private var point: NSPoint?
    private var movedAt: CFTimeInterval = 0
    private(set) var idleTimer: Timer?
    private(set) var text: String?
    private let label = TooltipLabel(labelWithString: "")
    var keycaps: [TooltipKeycap] { label.keycaps }

    func flagsChanged(with event: NSEvent) {
        guard text != nil else { return }
        label.keycaps.forEach { $0.setPressed(event.modifierFlags.contains($0.modifier) && !$0.modifier.isEmpty) }
    }

    init() {
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.wantsLayer = true
        label.layer?.cornerRadius = 14
        label.layer?.masksToBounds = true
        label.setAccessibilityHidden(true)
    }

    func capture(in view: NSView) {
        if let text = view.toolTip {
            texts.setObject(text as NSString, forKey: view)
            let help = view.accessibilityHelp() ?? text
            view.toolTip = nil
            view.setAccessibilityHelp(help)
        }
        for child in view.subviews { capture(in: child) }
    }

    func update(target next: NSView?, point nextPoint: NSPoint?) {
        guard !menuTracking else { return }
        let now = clock()
        if point != nextPoint || target !== next { movedAt = now }
        point = nextPoint
        target = next
        idleTimer?.invalidate()
        idleTimer = nil
        guard let next, let point = nextPoint, let value = texts.object(forKey: next) as String? else {
            dismiss()
            return
        }
        if text != nil || now >= movedAt + 1.6 {
            show(value, at: point, in: next)
        } else {
            let timer = Timer(timeInterval: max(0, movedAt + 1.6 - now), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.update(target: self.target, point: self.point)
                }
            }
            idleTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    isolated deinit { idleTimer?.invalidate() }

    func target(at hit: NSView?) -> NSView? {
        var view = hit
        while let current = view {
            if let text = current.toolTip {
                texts.setObject(text as NSString, forKey: current)
                let help = current.accessibilityHelp() ?? text
                current.toolTip = nil
                current.setAccessibilityHelp(help)
            }
            if texts.object(forKey: current) != nil { return current }
            view = current.superview
        }
        return nil
    }

    func dismiss() {
        movedAt = clock()
        idleTimer?.invalidate()
        idleTimer = nil
        guard text != nil else { return }
        text = nil
        guard label.superview != nil else { return }
        label.layer?.removeAnimation(forKey: "tooltip.hide")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                if self?.text == nil { self?.label.removeFromSuperview() }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = label.layer?.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 2 / 60
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        label.layer?.add(fade, forKey: "tooltip.hide")
        CATransaction.commit()
    }

    private func show(_ text: String, at point: NSPoint, in target: NSView) {
        self.text = text
        guard let root = target.window?.contentView else { return }
        label.layer?.removeAnimation(forKey: "tooltip.hide")
        label.stringValue = text
        label.sizeToFit()
        label.keycaps.forEach { $0.removeFromSuperview() }
        label.keycaps = []
        let action = (target as? NSControl)?.action
        let shortcutAction: Selector?
        if let row = target.superview as? SidebarRowView, target === row.closeButton {
            shortcutAction = row.closeShortcutAction
        } else { shortcutAction = action }
        if let shortcutAction, let item = Self.menuItem(for: shortcutAction, in: NSApp.mainMenu), !item.keyEquivalent.isEmpty {
            label.keycaps = Self.keycaps(for: item)
        }
        let modifiers = modifierFlags()
        var x = label.frame.width + (label.keycaps.isEmpty ? 10 : 18)
        for cap in label.keycaps {
            cap.frame = NSRect(x: x, y: 5, width: max(18, cap.intrinsicContentSize.width + 6), height: 18)
            label.addSubview(cap)
            cap.setPressed(!cap.modifier.isEmpty && modifiers.contains(cap.modifier))
            x += cap.frame.width + 3
        }
        let size = NSSize(width: min(root.bounds.width, label.keycaps.isEmpty ? x + 10 : x + 7), height: 28)
        let cursor = root.convert(point, from: nil)
        label.frame = NSRect(x: min(max(0, cursor.x + 13), root.bounds.width - size.width),
                             y: min(max(0, cursor.y - 14 - size.height), root.bounds.height - size.height),
                             width: size.width, height: size.height)
        label.backgroundColor = .windowBackgroundColor
        label.drawsBackground = true
        label.alignment = .center
        if label.superview !== root { label.removeFromSuperview(); root.addSubview(label) }
    }

    private static func menuItem(for action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action, !item.keyEquivalent.isEmpty { return item }
            if let found = menuItem(for: action, in: item.submenu) { return found }
        }
        return nil
    }

    static func keycaps(for item: NSMenuItem) -> [TooltipKeycap] {
        guard !item.keyEquivalent.isEmpty else { return [] }
        var mask = item.keyEquivalentModifierMask
        if item.keyEquivalent.rangeOfCharacter(from: .uppercaseLetters) != nil { mask.insert(.shift) }
        var caps = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { mask.contains($0.0) }.map { TooltipKeycap($0.1, modifier: $0.0) }
        caps.append(TooltipKeycap(keyGlyph(item.keyEquivalent), modifier: []))
        return caps
    }

    private static func keyGlyph(_ key: String) -> String {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return key.uppercased() }
        switch scalar.value {
        case 0x0d, 0x03: return "↩"
        case 0x7f, 0x08: return "⌫"
        case 0x09: return "⇥"
        case 0x1b: return "⎋"
        case 0x20: return "␣"
        case UInt32(NSDeleteFunctionKey): return "⌦"
        case UInt32(NSUpArrowFunctionKey): return "↑"
        case UInt32(NSDownArrowFunctionKey): return "↓"
        case UInt32(NSLeftArrowFunctionKey): return "←"
        case UInt32(NSRightArrowFunctionKey): return "→"
        case UInt32(NSPageUpFunctionKey): return "⇞"
        case UInt32(NSPageDownFunctionKey): return "⇟"
        case UInt32(NSHomeFunctionKey): return "↖"
        case UInt32(NSEndFunctionKey): return "↘"
        default: return key.uppercased()
        }
    }
}

@MainActor
private final class TooltipLabel: NSTextField {
    var keycaps: [TooltipKeycap] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        backgroundColor?.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: textColor!]
        let size = stringValue.size(withAttributes: attributes)
        stringValue.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

@MainActor
final class TooltipKeycap: NSTextField {
    let modifier: NSEvent.ModifierFlags
    private(set) var pressed = false

    init(_ text: String, modifier: NSEvent.ModifierFlags) {
        self.modifier = modifier
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 11, weight: .medium)
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 4
        setAccessibilityHidden(true)
        setPressed(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setPressed(_ value: Bool) {
        pressed = value
        frame.origin.y = value ? 4 : 5
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(value ? 0.18 : 0.08).cgColor
    }
}
