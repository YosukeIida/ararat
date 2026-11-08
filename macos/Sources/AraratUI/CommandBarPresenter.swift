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
    public var onClose: () -> Void = {}
    public var onCommit: (Suggestion?, CommandBarMode, Bool) -> Void = { _, _, _ in }

    public init(parent: NSWindow, visible: Bool, bindings: [KeyBinding], highlight: NSColor) {
        self.parent = parent
        self.visible = visible
        view = CommandBarView(controller: controller)
        super.init()
        panel.contentView = view
        panel.delegate = self
        panel.menuCommandBindings = bindings
        controller.highlight = highlight
        controller.panelWidth = CommandBarMetrics.cappedWidth(windowWidth: parent.frame.width)
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
        panel.setFrame(CommandBarMetrics.panelFrame(windowFrame: parent.frame, width: controller.panelWidth,
                                                    rows: controller.result.rows.count), display: visible)
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
