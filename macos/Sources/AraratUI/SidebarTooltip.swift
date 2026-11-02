import AppKit

@MainActor
final class SidebarTooltip {
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var menuTracking = false { didSet { dismiss() } }
    private let texts = NSMapTable<NSView, NSString>.weakToStrongObjects()
    private weak var target: NSView?
    private var point: NSPoint?
    private var movedAt: CFTimeInterval = 0
    private(set) var idleTimer: Timer?
    private(set) var text: String?
    private let label = TooltipLabel(labelWithString: "")

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
        let size = NSSize(width: min(root.bounds.width, label.frame.width + 20), height: 28)
        let cursor = root.convert(point, from: nil)
        label.frame = NSRect(x: min(max(0, cursor.x + 13), root.bounds.width - size.width),
                             y: min(max(0, cursor.y - 14 - size.height), root.bounds.height - size.height),
                             width: size.width, height: size.height)
        label.backgroundColor = .windowBackgroundColor
        label.drawsBackground = true
        label.alignment = .center
        if label.superview !== root { label.removeFromSuperview(); root.addSubview(label) }
    }
}

@MainActor
private final class TooltipLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
