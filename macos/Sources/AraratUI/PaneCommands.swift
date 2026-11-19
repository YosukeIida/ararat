import AppKit
import AraratKit

// U25d: one command per item of the split row's segment menu, in the mock's order. The sidebar
// names the pane it is for; the window does the rest (the core op, the snapshot and the focus).
public enum PaneCommand: Sendable {
    // Move Left, or Move Up in a vertical split: the focused pane swaps with the one before it.
    case moveBackward
    case moveForward
    case addLeft
    case addRight
    case separate
    case convert
    case close
}

// The half of the page a dragged row is over, with the rectangle to draw the drop indicator in
// (container coordinates). A drag over the page makes a split with the tab it was over.
public struct PaneDropHalf: Equatable {
    public let side: SplitSide
    public let rect: NSRect
    public init(side: SplitSide, rect: NSRect) {
        self.side = side
        self.rect = rect
    }
}

// The axis of the drop zones the page offers: left/right halves of a horizontal split (or a lone
// tab, which makes a horizontal split), top/bottom halves of a vertical one (design S1).
public enum PaneDropAxis: Sendable {
    case horizontal
    case vertical
}

// The mark over the page half a split would land on: a starting look (8 pt inset, 8 pt radius,
// a 2 pt accent border over an 8 % fill), tuned the way every other drag look is.
@MainActor
final class PaneDropIndicator: NSView {
    static let inset: CGFloat = 8
    static let border: CGFloat = 2
    private let fill = NSView()
    var accent = SpaceAccent.teal { didSet { updateColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 8
        fill.layer?.cornerCurve = .continuous
        fill.layer?.borderWidth = Self.border
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            fill.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
        ])
        setAccessibilityHidden(true)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The page under it takes the clicks: the mark is a picture of where the drop goes.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateColors() {
        fill.layer?.backgroundColor = accent.withAlphaComponent(0.08).cgColor
        fill.layer?.borderColor = accent.withAlphaComponent(0.9).cgColor
    }
}
