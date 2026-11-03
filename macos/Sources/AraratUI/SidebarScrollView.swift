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
            if scrollerStyle == .overlay { hasVerticalScroller = false }
        }
        if onScroll?(event) == true {
            if scrollerStyle == .overlay { hasVerticalScroller = false }
            return
        }
        if event.scrollingDeltaY != 0 {
            hasVerticalScroller = true
            permitsScroller = true
        }
        scrollNatively(with: event)
    }

    func scrollNatively(with event: NSEvent) { super.scrollWheel(with: event) }

    override func flashScrollers() {
        if permitsScroller { super.flashScrollers() }
    }
}
