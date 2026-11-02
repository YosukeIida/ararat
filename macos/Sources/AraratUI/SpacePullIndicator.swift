import AppKit

@MainActor
final class SpacePullIndicator: NSView {
    let circle = CAShapeLayer()
    let plus = CAShapeLayer()
    let ring = CAShapeLayer()
    private(set) var excess = 0.0
    private var exitDistance = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        for shape in [circle, plus, ring] { layer?.addSublayer(shape) }
        circle.path = CGPath(ellipseIn: CGRect(x: -15, y: -15, width: 30, height: 30), transform: nil)
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: -6, y: 0)); cross.addLine(to: CGPoint(x: 6, y: 0))
        cross.move(to: CGPoint(x: 0, y: -6)); cross.addLine(to: CGPoint(x: 0, y: 6))
        plus.path = cross
        plus.lineWidth = 2
        plus.lineCap = .round
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: 17, startAngle: .pi / 2, endAngle: .pi / 2 + 2 * .pi, clockwise: false)
        ring.path = arc
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 2
        update(excess: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        update(excess: excess, exit: exitDistance)
    }

    static func travel(_ excess: Double) -> Double { min(42, max(0, excess) * 0.4) }
    static func ringFraction(_ excess: Double) -> Double { min(1, max(0, (excess - 75) / 87)) }

    func update(excess: Double, exit: Double = 0) {
        self.excess = excess
        exitDistance = exit
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = excess <= 0
        layer?.isHidden = isHidden
        let position = CGPoint(x: bounds.maxX + 15 - Self.travel(excess) + exit, y: bounds.midY)
        for shape in [circle, plus, ring] { shape.position = position }
        let ready = excess >= SidebarMetrics.spaceCreateThreshold
        circle.fillColor = (ready ? NSColor.white : NSColor.controlAccentColor).cgColor
        plus.strokeColor = (ready ? NSColor.controlAccentColor : NSColor.white).cgColor
        ring.strokeEnd = Self.ringFraction(excess)
        CATransaction.commit()
    }
}
