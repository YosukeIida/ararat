import AppKit

public final class PermissionDim {
    private var views: [String: NSView] = [:]

    public init() {}

    public func update(_ identifier: String, container: NSView, frame: NSRect, visible: Bool) {
        guard visible else {
            views.removeValue(forKey: identifier)?.removeFromSuperview()
            return
        }
        let view = views[identifier] ?? NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        view.frame = frame
        if view.superview !== container { container.addSubview(view) }
        views[identifier] = view
    }
}
