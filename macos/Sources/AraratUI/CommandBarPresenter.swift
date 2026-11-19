import AppKit
import AraratKit

private final class CommandBarBackdrop: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
public final class CommandBarPresenter: NSObject, NSWindowDelegate {
    public let controller = CommandBarController()
    public let panel = CommandBarPanel()
    public let view: CommandBarView
    private weak var parent: NSWindow?
    private weak var pageCard: NSView?
    private let backdrop = CommandBarBackdrop()
    private let hints = NSStackView()
    private let hintGroups = [NSStackView(), NSStackView()]
    private let visible: Bool
    private var restoreFocus = true
    /// U27h: a fixed width means a Little Window's own bar; nil keeps the browser windows' cap.
    private let fixedWidth: CGFloat?
    public var onClose: () -> Void = {}
    public var onCommit: (Suggestion?, CommandBarMode, Bool) -> Void = { _, _, _ in }

    public init(parent: NSWindow, pageCard: NSView? = nil, visible: Bool, bindings: [KeyBinding], highlight: NSColor, width: CGFloat? = nil) {
        self.parent = parent
        self.pageCard = pageCard
        self.visible = visible
        fixedWidth = width
        view = CommandBarView(controller: controller)
        super.init()
        panel.contentView = view
        panel.delegate = self
        panel.appearance = parent.effectiveAppearance
        panel.menuCommandBindings = bindings
        controller.highlight = highlight
        if width == nil {
            backdrop.identifier = NSUserInterfaceItemIdentifier("command-bar-backdrop")
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = CommandBarMetrics.backdropFill.cgColor
            backdrop.autoresizingMask = [.width, .height]
            for group in hintGroups {
                group.orientation = .horizontal
                group.spacing = CommandBarMetrics.hintGap
                hints.addArrangedSubview(group)
            }
            for (index, title) in ["↑ ↓ Select", "↩ Open", "⌘↩ Open in new tab", "Esc Close"].enumerated() {
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: CommandBarMetrics.hintFontSize)
                label.textColor = .white
                label.translatesAutoresizingMaskIntoConstraints = false
                let pill = NSView()
                pill.wantsLayer = true
                pill.layer?.backgroundColor = CommandBarMetrics.hintFill.cgColor
                pill.layer?.cornerRadius = CommandBarMetrics.hintRadius
                pill.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: CommandBarMetrics.hintPaddingX),
                    label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -CommandBarMetrics.hintPaddingX),
                    label.topAnchor.constraint(equalTo: pill.topAnchor, constant: CommandBarMetrics.hintPaddingY),
                    label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -CommandBarMetrics.hintPaddingY),
                ])
                hintGroups[index / 2].addArrangedSubview(pill)
            }
            backdrop.addSubview(hints)
            if let pageCard {
                pageCard.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(reposition),
                    name: NSView.frameDidChangeNotification, object: pageCard)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(reposition),
                name: NSWindow.didResizeNotification, object: parent)
        }
        controller.onClose = { [weak self] in self?.finish() }
        controller.onRowsChange = { [weak self] in self?.position() }
    }

    public func open(mode: CommandBarMode, prefill: String?) {
        controller.onCommit = onCommit
        if fixedWidth == nil, let content = parent?.contentView {
            backdrop.frame = content.bounds
            content.addSubview(backdrop, positioned: .above, relativeTo: nil)
        }
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

    @objc private func reposition(_ notification: Notification) {
        if controller.isOpen { position() }
    }

    private func position() {
        guard let parent else { return }
        let rows = controller.result.rows.count
        let frame: NSRect
        if let fixedWidth {
            let width = min(fixedWidth, CommandBarMetrics.cappedWidth(windowWidth: parent.frame.width))
            frame = CommandBarMetrics.littleWindowPanelFrame(windowFrame: parent.frame, width: width, rows: rows)
        } else {
            let inlineWidth = hintGroups[0].fittingSize.width + CommandBarMetrics.hintGap + hintGroups[1].fittingSize.width
            let wrapped = inlineWidth > backdrop.bounds.width
            hints.orientation = wrapped ? .vertical : .horizontal
            hints.alignment = wrapped ? .centerX : .centerY
            hints.spacing = wrapped ? CommandBarMetrics.hintPaddingY : CommandBarMetrics.hintGap
            let size = hints.fittingSize
            let pageFrame = pageCard.map { parent.convertToScreen($0.convert($0.bounds, to: nil)) } ?? parent.frame
            frame = CommandBarMetrics.panelFrame(windowFrame: parent.frame, pageFrame: pageFrame,
                                                  rows: rows, privateWindow: controller.result.privateWindow, hintHeight: size.height)
            let localPanel = backdrop.convert(parent.convertFromScreen(frame), from: nil)
            let x = max(backdrop.bounds.minX, min(localPanel.midX - size.width / 2, backdrop.bounds.maxX - size.width))
            hints.frame = NSRect(x: x, y: localPanel.minY - CommandBarMetrics.hintOffset - size.height,
                                 width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: visible)
    }

    private func finish() {
        backdrop.removeFromSuperview()
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
