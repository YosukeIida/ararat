import AppKit
import AraratKit

@MainActor
public final class TabSwitcher {
    public private(set) var rows: [Suggestion] = []
    public private(set) var selectedIndex = 0
    public private(set) var isOpen = true
    public var onSelect: (Suggestion) -> Void = { _ in }
    public var onClose: () -> Void = {}
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    public var visibleWindow: NSWindow? { panel.isVisible ? panel : nil }
    private weak var parent: NSWindow?
    private var monitor: Any?
    private var deactivate: NSObjectProtocol?
    private var resignKey: NSObjectProtocol?
    private var offset: Int
    private var awaitingRows = true
    private var commitPending = false
    private let favicon: (String) -> NSImage?
    private let accent: NSColor
    private let hints: [String]

    public init(parent: NSWindow, backwards: Bool, bindings: [KeyBinding], accent: NSColor, favicon: @escaping (String) -> NSImage?) {
        self.parent = parent
        self.favicon = favicon
        self.accent = accent
        let steps = [("cycle_tabs_next", "Next"), ("cycle_tabs_previous", "Previous")]
        hints = steps.compactMap { step -> String? in
            let (command, action) = step
            guard let key = bindings.first(where: { $0.command == command })?.key else { return nil }
            return "\(CommandBarRowView.keycap(key)) \(action)"
        } + ["Release ⌃ Switch", "Esc Cancel"]
        offset = backwards ? -1 : 0
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if event.type == .flagsChanged && !event.modifierFlags.contains(.control) {
                self.commit()
                return event
            }
            if event.type == .keyDown && event.keyCode == 53 { self.cancel(); return nil }
            return event
        }
        resignKey = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        deactivate = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    public func load(_ rows: [Suggestion]) {
        guard isOpen else { return }
        awaitingRows = false
        self.rows = Array(rows.prefix(5))
        guard !self.rows.isEmpty else { cancel(); return }
        selectedIndex = ((offset % self.rows.count) + self.rows.count) % self.rows.count
        if commitPending { commit(); return }
        draw()
    }

    public func advance(backwards: Bool) {
        guard isOpen else { return }
        offset += backwards ? -1 : 1
        guard !rows.isEmpty else { return }
        selectedIndex = ((offset % rows.count) + rows.count) % rows.count
        draw()
    }

    public func commit() {
        guard isOpen else { return }
        if awaitingRows { commitPending = true; return }
        let selected = rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
        cancel()
        if let selected { onSelect(selected) }
    }

    public func cancel() {
        guard isOpen else { return }
        isOpen = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let deactivate { NotificationCenter.default.removeObserver(deactivate); self.deactivate = nil }
        if let resignKey { NotificationCenter.default.removeObserver(resignKey); self.resignKey = nil }
        if panel.parent != nil { parent?.removeChildWindow(panel) }
        if panel.isVisible { panel.orderOut(nil) }
        onClose()
    }

    private func draw() {
        guard let parent else { cancel(); return }
        guard parent.isVisible, let overlay = makeOverlay() else { return }
        panel.contentView = overlay.content
        panel.setFrame(overlay.frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func makeOverlay() -> (content: NSView, frame: NSRect)? {
        guard let parent, !rows.isEmpty else { return nil }
        let window = parent.frame
        let hintGap = CommandBarMetrics.hintGap
        let pills = hints.map { title in
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: CommandBarMetrics.hintFontSize)
            label.textColor = .white
            label.sizeToFit()
            label.frame.origin = NSPoint(x: CommandBarMetrics.hintPaddingX, y: CommandBarMetrics.hintPaddingY)
            let pill = NSView(frame: label.frame.insetBy(dx: -CommandBarMetrics.hintPaddingX, dy: -CommandBarMetrics.hintPaddingY))
            pill.wantsLayer = true
            pill.layer?.backgroundColor = CommandBarMetrics.hintFill.cgColor
            pill.layer?.cornerRadius = CommandBarMetrics.hintRadius
            pill.addSubview(label)
            return pill
        }
        func hintWidth(_ row: [NSView]) -> CGFloat {
            row.reduce(0) { $0 + $1.frame.width } + CGFloat(row.count - 1) * hintGap
        }
        let split = (pills.count + 1) / 2
        let hintRows = hintWidth(pills) > window.width ? [Array(pills.prefix(split)), Array(pills.dropFirst(split))] : [pills]
        let hintHeight = pills[0].frame.height
        let hintRowGap = CommandBarMetrics.hintPaddingY
        let panelY = CGFloat(hintRows.count) * (hintHeight + hintRowGap) - hintRowGap + 12
        let tilePadding: CGFloat = 12
        let tileGap: CGFloat = 8
        let tileSpacing = 2 * tilePadding + CGFloat(rows.count - 1) * tileGap
        let tileWidth = min(144, max(0, (window.width - tileSpacing) / CGFloat(rows.count)))
        let panelWidth = CGFloat(rows.count) * tileWidth + tileSpacing
        let width = max(panelWidth, hintRows.map(hintWidth).max() ?? 0)
        let panelHeight: CGFloat = 136
        let frame = NSRect(x: window.midX - width / 2, y: window.midY - panelHeight / 2 - panelY,
                           width: width, height: panelHeight + panelY)
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let background = NSVisualEffectView(frame: NSRect(x: (width - panelWidth) / 2, y: panelY,
                                                         width: panelWidth, height: panelHeight))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        for (index, row) in rows.enumerated() {
            let tile = NSView(frame: NSRect(x: tilePadding + CGFloat(index) * (tileWidth + tileGap),
                                          y: tilePadding, width: tileWidth, height: 112))
            tile.identifier = NSUserInterfaceItemIdentifier("tab-switcher-tile")
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 10
            tile.layer?.backgroundColor = (index == selectedIndex ? accent : NSColor.clear).cgColor
            let iconSize = min(32, tileWidth)
            let icon = NSImageView(frame: NSRect(x: (tileWidth - iconSize) / 2, y: 54, width: iconSize, height: iconSize))
            if case .tab(let id, _) = row.target { icon.image = favicon(id) }
            if icon.image == nil { icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) }
            let title = NSTextField(labelWithString: row.title)
            title.textColor = index == selectedIndex ? SpaceAccent.foreground(on: accent) : .labelColor
            title.alignment = .center
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: 8, y: 17, width: max(0, tileWidth - 16), height: 24)
            tile.addSubview(icon)
            tile.addSubview(title)
            background.addSubview(tile)
        }
        content.addSubview(background)
        for (index, row) in hintRows.enumerated() {
            var x = (width - hintWidth(row)) / 2
            let y = CGFloat(hintRows.count - 1 - index) * (hintHeight + hintRowGap)
            for pill in row {
                pill.frame.origin = NSPoint(x: x, y: y)
                content.addSubview(pill)
                x += pill.frame.width + hintGap
            }
        }
        return (content, frame)
    }
}
