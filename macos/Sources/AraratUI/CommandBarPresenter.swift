import AppKit
import AraratKit

@MainActor
public final class CommandBarPresenter: NSObject, NSWindowDelegate {
    public let controller = CommandBarController()
    public let panel = CommandBarPanel()
    public let view: CommandBarView
    private weak var parent: NSWindow?
    private let visible: Bool
    private var restoreFocus = true
    /// U27h: a fixed width means a Little Window's own bar; nil keeps the browser windows' cap.
    private let fixedWidth: CGFloat?
    public var onClose: () -> Void = {}
    public var onCommit: (Suggestion?, CommandBarMode, Bool) -> Void = { _, _, _ in }

    public init(parent: NSWindow, visible: Bool, bindings: [KeyBinding], highlight: NSColor, width: CGFloat? = nil) {
        self.parent = parent
        self.visible = visible
        fixedWidth = width
        view = CommandBarView(controller: controller)
        super.init()
        panel.contentView = view
        panel.delegate = self
        panel.menuCommandBindings = bindings
        controller.highlight = highlight
        // U27h: a Little Window opens the bar at its own 504 pt; every other window keeps the
        // 766 pt bar capped at the window's width − 80.
        controller.panelWidth = width.map { min($0, CommandBarMetrics.cappedWidth(windowWidth: parent.frame.width)) }
            ?? CommandBarMetrics.cappedWidth(windowWidth: parent.frame.width)
        controller.onClose = { [weak self] in self?.finish() }
        controller.onRowsChange = { [weak self] in self?.position() }
    }

    public func open(mode: CommandBarMode, prefill: String?) {
        controller.onCommit = onCommit
        controller.open(mode: mode, prefill: prefill, store: nil)
        guard visible, let parent else { return }
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        view.focusField()
    }

    public func applyStore(_ store: CommandBarStore) {
        guard controller.isOpen else { return }
        controller.applyStore(store)
    }

    public func close(restoreFocus: Bool = true) {
        self.restoreFocus = restoreFocus
        controller.close()
    }

    private func position() {
        guard let parent else { return }
        let rows = controller.result.rows.count
        let frame = fixedWidth == nil
            ? CommandBarMetrics.panelFrame(windowFrame: parent.frame, width: controller.panelWidth,
                                           rows: rows, privateWindow: controller.result.privateWindow)
            : CommandBarMetrics.littleWindowPanelFrame(windowFrame: parent.frame, width: controller.panelWidth,
                                                       rows: rows)
        panel.setFrame(frame, display: visible)
    }

    private func finish() {
        if panel.parent != nil { parent?.removeChildWindow(panel) }
        if visible {
            panel.orderOut(nil)
            if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
        }
        onClose()
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard visible, controller.isOpen else { return }
        restoreFocus = false
        guard controller.panelDidResignKey() else { return }
        restoreFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller.isOpen else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
    }
}
