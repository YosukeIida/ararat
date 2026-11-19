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

    public init(parent: NSWindow, backwards: Bool, accent: NSColor, favicon: @escaping (String) -> NSImage?) {
        self.parent = parent
        self.favicon = favicon
        self.accent = accent
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
        panel.orderOut(nil)
        onClose()
    }

    private func draw() {
        guard let parent else { cancel(); return }
        guard parent.isVisible else { return }
        let width = CGFloat(rows.count) * 144 + CGFloat(max(0, rows.count - 1)) * 8 + 24
        let frame = NSRect(x: parent.frame.midX - width / 2, y: parent.frame.midY - 68, width: width, height: 136)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        for (index, row) in rows.enumerated() {
            let tile = NSView(frame: NSRect(x: 12 + CGFloat(index) * 152, y: 12, width: 144, height: 112))
            tile.identifier = NSUserInterfaceItemIdentifier("tab-switcher-tile")
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 10
            tile.layer?.backgroundColor = (index == selectedIndex ? accent : NSColor.clear).cgColor
            let icon = NSImageView(frame: NSRect(x: 56, y: 54, width: 32, height: 32))
            if case .tab(let id, _) = row.target { icon.image = favicon(id) }
            if icon.image == nil { icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) }
            let title = NSTextField(labelWithString: row.title)
            title.textColor = index == selectedIndex ? SpaceAccent.foreground(on: accent) : .labelColor
            title.alignment = .center
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: 8, y: 17, width: 128, height: 24)
            tile.addSubview(icon)
            tile.addSubview(title)
            background.addSubview(tile)
        }
        panel.contentView = background
        panel.setFrame(frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
}
