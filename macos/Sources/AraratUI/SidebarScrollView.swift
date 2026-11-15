import AppKit

@MainActor
class SidebarScrollView: NSScrollView {
    var onScroll: ((NSEvent) -> Bool)?
    var onBoundsChanged: (() -> Void)?
    private let topHairline = CALayer()
    private let bottomHairline = CALayer()
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var revealTimer: Timer?
    var isRevealing: Bool { revealTimer != nil }
    private var revealStep: (() -> Void)?
    private var permitsScroller = false
    /// The trailing strip that reveals the knob on hover (P4: Arc's overlay look).
    private let knobHoverWidth: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for line in [topHairline, bottomHairline] {
            line.name = line === topHairline ? "list.top" : "list.bottom"
            line.opacity = 0
            layer?.addSublayer(line)
        }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                              name: NSView.boundsDidChangeNotification, object: contentView)
        // P4 (2026-11-15): the row list always uses the overlay knob, whatever the system's
        // "Automatically based on mouse or trackpad" says, so a mouse never brings back the
        // legacy track-and-arrows scroller.
        scrollerStyle = .overlay
        NotificationCenter.default.addObserver(self, selector: #selector(preferredScrollerStyleChanged),
                                              name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        updateHairlines()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHairlines()
    }

    @objc private func boundsChanged() { updateHairlines(); onBoundsChanged?() }

    func updateHairlines() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.05)).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topHairline.frame = CGRect(x: 0, y: isFlipped ? 0 : bounds.height - 1, width: bounds.width, height: 1)
        bottomHairline.frame = CGRect(x: 0, y: isFlipped ? bounds.height - 1 : 0, width: bounds.width, height: 1)
        for line in [topHairline, bottomHairline] { line.backgroundColor = color }
        CATransaction.commit()
        let visible = contentView.bounds
        set(topHairline, visible: visible.minY > 0.5)
        set(bottomHairline, visible: visible.maxY < (documentView?.frame.height ?? 0) - 0.5)
    }

    private func set(_ line: CALayer, visible: Bool) {
        let opacity: Float = visible ? 1 : 0
        guard line.opacity != opacity else { return }
        let from = line.presentation()?.opacity ?? line.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.opacity = opacity
        if !reduceMotion() {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = opacity
            animation.duration = 0.25
            line.add(animation, forKey: "edge.fade")
        }
        CATransaction.commit()
    }

    func move(to y: CGFloat) {
        let maximum = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, y))))
        reflectScrolledClipView(contentView)
        updateHairlines()
    }

    func reveal(_ row: NSRect, animated: Bool = true) {
        stopReveal()
        let visible = contentView.bounds
        let target: CGFloat
        if row.minY < visible.minY { target = row.minY }
        else if row.maxY > visible.maxY { target = row.maxY - visible.height }
        else { return }
        if !animated || reduceMotion() { move(to: target); return }
        let start = clock()
        let origin = visible.minY
        revealStep = { [weak self] in
            guard let self else { return }
            let progress = min(1, max(0, (self.clock() - start) / 0.22))
            self.move(to: origin + (target - origin) * (1 - pow(1 - progress, 3)))
            if progress >= 1 { self.stopReveal() }
        }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.stepReveal() }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stepReveal() { revealStep?() }

    func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        revealStep = nil
    }

    override func scrollWheel(with event: NSEvent) {
        stopReveal()
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            permitsScroller = false
            hasVerticalScroller = false
        }
        if onScroll?(event) == true {
            hasVerticalScroller = false
            return
        }
        switch Self.knobStep(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY) {
        case .hide:
            // At once, with no fade-out wait: a horizontal swipe or the owner's trackball hides
            // the knob even when a vertical scroll showed it a moment ago (P4, 2026-11-15).
            hasVerticalScroller = false
            permitsScroller = false
        case .show:
            hasVerticalScroller = true
            permitsScroller = true
        case .keep:
            break
        }
        scrollNatively(with: event)
    }

    /// The knob's rule (P4): vertical input shows the overlay knob, horizontal input hides it at
    /// once whatever the event's phase, and neither is a phase-less wheel's deltas of zero. The
    /// system's overlay scroller fades the knob out on its own after the last scroll.
    enum KnobStep: Equatable { case show, hide, keep }

    static func knobStep(dx: Double, dy: Double) -> KnobStep {
        if abs(dx) > abs(dy) { return .hide }
        if dy != 0 { return .show }
        return .keep
    }

    @objc private func preferredScrollerStyleChanged() {
        // The system preference can land at any time; the row list keeps the overlay knob.
        if scrollerStyle != .overlay { scrollerStyle = .overlay }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: NSRect(x: bounds.width - knobHoverWidth, y: 0,
                                                    width: knobHoverWidth, height: bounds.height),
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    /// The knob a horizontal scroll hid comes back when the pointer enters the scroller's strip,
    /// as the overlay scroller does on its own when the list still has one.
    override func mouseEntered(with event: NSEvent) {
        guard !hasVerticalScroller else { return }
        hasVerticalScroller = true
    }

    /// The space below the last row (P4): a press there moves the window as a title bar does.
    /// The scroll view keeps the wheel, so vertical scrolling from that empty area still works.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === contentView || hit === documentView ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        WindowDrag.press(in: self, with: event)
    }

    func scrollNatively(with event: NSEvent) { super.scrollWheel(with: event) }

    override func flashScrollers() {
        if permitsScroller { super.flashScrollers() }
    }
}
