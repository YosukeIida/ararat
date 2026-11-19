import AppKit

public final class PageDialogDim {
    private var views: [String: DimView] = [:]

    public init() {}

    public func isVisible(_ identifier: String) -> Bool {
        guard let view = views[identifier] else { return false }
        return view.superview != nil && !view.isHiddenOrHasHiddenAncestor
    }

    public func update(_ identifier: String, container: NSView?, frame: NSRect, visible: Bool) {
        guard visible, let container else {
            views.removeValue(forKey: identifier)?.removeFromSuperview()
            return
        }
        let view = views[identifier] ?? DimView(frame: frame)
        view.wantsLayer = true
        view.frame = frame
        if view.superview !== container { container.addSubview(view) }
        view.refreshFill()
        views[identifier] = view
    }
}

private final class DimView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
    }

    func refreshFill() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.25)
            : NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 24 / 255, alpha: 0.06)).cgColor
    }
}
