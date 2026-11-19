import AppKit
import AraratKit

@MainActor
final class EmptyPageHints: NSView {
    static let hintGap: CGFloat = 10
    static let labelSize: CGFloat = 13
    static let lightCardFill = NSColor.white

    static func cardFill(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .windowBackgroundColor : lightCardFill
    }

    private let hints = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        hints.orientation = .vertical
        hints.alignment = .centerX
        hints.spacing = Self.hintGap
        hints.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hints)
        NSLayoutConstraint.activate([
            hints.centerXAnchor.constraint(equalTo: centerXAnchor),
            hints.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(bindings: [KeyBinding]) {
        for row in hints.arrangedSubviews { row.removeFromSuperview() }
        for (command, title) in [("new_tab", "New Tab"), ("toggle_library", "Open Library")] {
            guard let key = bindings.first(where: { $0.command == command })?.key else { continue }
            let symbols = SidebarTooltip.caps(for: key)
            let caps = NSStackView(views: symbols.map { glyph in
                let cap = TooltipKeycap(glyph, modifier: [])
                cap.widthAnchor.constraint(equalToConstant: max(TooltipKeycap.size, cap.intrinsicContentSize.width + 6)).isActive = true
                cap.heightAnchor.constraint(equalToConstant: TooltipKeycap.size).isActive = true
                return cap
            })
            caps.spacing = TooltipKeycap.gap
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: Self.labelSize)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityLabel("\(title), \(symbols.joined())")
            let row = NSStackView(views: [caps, label])
            row.alignment = .centerY
            row.spacing = Self.hintGap
            hints.addArrangedSubview(row)
        }
    }
}
